defmodule SymphonyElixir.Validation do
  @moduledoc """
  Candidate-bound validation and locally durable, authenticated evidence.

  The coordinator supplies a pinned policy and an expected operation identity.
  A receipt is a pointer into service-owned storage, never agent-authored results.
  Docker executes candidate code without mounts or producer credentials. GCS
  archival and GitHub check/publication adapters belong to later increments.
  """
  alias SymphonyElixir.{PathSafety, ValidationCommand, ValidationPolicy}
  @source_root Path.expand("../../..", __DIR__)
  @version "candidate-validation-v1"
  @external_resource Path.join(__DIR__, "validation_policy.ex")
  @external_resource Path.join(__DIR__, "validation_command.ex")
  @service_digest [__ENV__.file, Path.join(__DIR__, "validation_policy.ex"), Path.join(__DIR__, "validation_command.ex")]
                  |> Enum.map(&File.read!/1)
                  |> IO.iodata_to_binary()
                  |> then(&:crypto.hash(:sha256, &1))
                  |> Base.encode16(case: :lower)

  @spec execute(Path.t(), map(), map(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def execute(workspace, policy, context, required, opts) do
    mode = Keyword.get(opts, :mode, :final)

    with {:ok, roots} <- storage_roots(workspace, opts),
         {:ok, identity, paths} <- candidate(workspace, context, mode),
         {:ok, checks} <- ValidationPolicy.resolve(policy, identity["changed_paths"], Keyword.get(opts, :kind, "ordinary")),
         {:ok, checks} <- focused_checks(checks, mode, Keyword.get(opts, :checks)),
         {:ok, key} <- producer_key(roots.archive),
         request = request_identity(identity, context, policy, checks, mode),
         id = digest(Jason.encode!(request)),
         {:ok, receipt} <- execute_or_recover(id, request, workspace, paths, checks, policy, key, roots, mode) do
      {:ok, feedback} = feedback(receipt, roots.archive)
      result = %{receipt: receipt, feedback: feedback}

      case verify_result({:ok, result}, policy, context, required, Keyword.put(opts, :workspace, workspace)) do
        {:ok, gate} -> {:ok, Map.put(result, :gate, gate)}
        {:error, reason} when mode == :development -> {:ok, Map.put(result, :gate, failed_gate(id, reason))}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    error -> {:error, {:validation_error, Exception.message(error)}}
  end

  @doc "Recomputes the gate from authenticated stored evidence, checking current source and pinned identity."
  @spec verify_result(term(), map(), map(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def verify_result({:ok, %{receipt: receipt}}, policy, context, required, opts) do
    with workspace when is_binary(workspace) <- Keyword.get(opts, :workspace),
         {:ok, roots} <- storage_roots(workspace, opts),
         {:ok, identity, _paths} <- candidate(workspace, context, :final),
         {:ok, checks} <- ValidationPolicy.resolve(policy, identity["changed_paths"], Keyword.get(opts, :kind, "ordinary")),
         expected = request_identity(identity, context, policy, checks, :final),
         {:ok, manifest} <- read_receipt(receipt, roots.archive),
         true <- Map.take(manifest, Map.keys(expected)) == expected,
         true <- manifest["complete"] == true,
         :ok <- verify_artifacts(manifest, roots.archive) do
      {:ok, ValidationPolicy.gate(manifest, required)}
    else
      false -> {:error, :stale_or_incomplete_validation_evidence}
      {:error, _} = error -> error
      _ -> {:error, :malformed_validation_result}
    end
  rescue
    _ -> {:error, :malformed_validation_result}
  end

  def verify_result(_result, _policy, _context, _required, _opts), do: {:error, :malformed_validation_result}

  @doc "Reads and authenticates a receipt for inspection. Eligibility additionally requires verify_result/5."
  @spec read_receipt(map(), Path.t()) :: {:ok, map()} | {:error, term()}
  def read_receipt(%{"id" => id, "manifest_sha256" => expected_digest}, archive) do
    with true <- valid_digest?(id) and valid_digest?(expected_digest),
         {:ok, bytes} <- File.read(Path.join([archive, id, "manifest.json"])),
         true <- digest(bytes) == expected_digest,
         {:ok, key} <- File.read(Path.join(archive, "producer.key")),
         {:ok, signature} <- File.read(Path.join([archive, id, "manifest.mac"])),
         true <- signature == mac(key, bytes),
         {:ok, manifest} <- Jason.decode(bytes),
         true <- manifest["id"] == id and manifest["producer"] == digest(key) do
      {:ok, manifest}
    else
      _ -> {:error, :missing_or_unauthenticated_receipt}
    end
  end

  def read_receipt(_receipt, _archive), do: {:error, :malformed_receipt}

  @doc "Returns authenticated, bounded development/repair feedback without granting archive access."
  @spec feedback(map(), Path.t()) :: {:ok, [map()]} | {:error, term()}
  def feedback(receipt, archive) do
    with {:ok, manifest} <- read_receipt(receipt, archive),
         :ok <- verify_artifacts(manifest, archive) do
      results =
        Enum.map(manifest["checks"], fn check ->
          {:ok, output} = File.read(Path.join([archive, manifest["id"], check["artifact"]["file"]]))

          check
          |> Map.take(~w(id status reason exit_status assertions))
          |> Map.put("output", output)
        end)

      {:ok, results}
    end
  rescue
    _ -> {:error, :malformed_validation_feedback}
  end

  @doc "Pins service-owned storage roots outside the candidate clone."
  @spec storage_roots(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def storage_roots(workspace, opts) do
    with {:ok, workspace} <- PathSafety.canonicalize(workspace),
         archive when is_binary(archive) <- Keyword.get(opts, :validation_archive),
         scratch when is_binary(scratch) <- Keyword.get(opts, :validation_scratch),
         {:ok, archive} <- PathSafety.canonicalize(archive),
         {:ok, scratch} <- PathSafety.canonicalize(scratch),
         true <-
           not overlap?(workspace, archive) and not overlap?(workspace, scratch) and not overlap?(archive, scratch) and not overlap?(@source_root, archive) and not overlap?(@source_root, scratch),
         :ok <- File.mkdir_p(archive),
         :ok <- File.chmod(archive, 0o700),
         :ok <- File.mkdir_p(scratch) do
      {:ok, %{archive: archive, scratch: scratch}}
    else
      false -> {:error, :validation_storage_overlaps_candidate}
      {:error, _} = error -> error
      _ -> {:error, :validation_storage_required}
    end
  end

  @doc "Hashes tracked file bytes, symlink targets, and executable bits without following candidate links."
  @spec source_digest(Path.t(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def source_digest(root, paths) do
    Enum.reduce_while(Enum.sort(paths), {:ok, []}, fn path, {:ok, entries} ->
      case file_identity(root, path) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, digest(Jason.encode!(entries))}
      error -> error
    end
  end

  @spec service_version() :: String.t()
  def service_version, do: @version

  defp candidate(workspace, context, mode) do
    with {:ok, head} <- git(workspace, ["rev-parse", "--verify", "HEAD^{commit}"]),
         {:ok, base} <- git(workspace, ["rev-parse", "--verify", Map.fetch!(context, :base_sha) <> "^{commit}"]),
         {:ok, tree} <- git(workspace, ["rev-parse", "HEAD^{tree}"]),
         {:ok, status} <- git(workspace, ["status", "--porcelain=v1", "--untracked-files=normal"]),
         true <- mode == :development or status == "",
         {:ok, paths} <- git(workspace, ["ls-tree", "-rz", "--name-only", "HEAD"]),
         {:ok, diff} <- git(workspace, ["diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", base, head]),
         {:ok, tracked_digest} <- source_digest(workspace, split_paths(paths)) do
      changed = if mode == :development, do: development_scope(workspace, base), else: split_paths(diff)
      {:ok, %{"candidate_sha" => head, "base_sha" => base, "source_tree" => tree, "source_digest" => tracked_digest, "changed_paths" => changed}, split_paths(paths)}
    else
      false -> {:error, :dirty_candidate_commit_required}
      error -> error
    end
  end

  defp development_scope(workspace, base) do
    {:ok, diff} = git(workspace, ["diff", "--no-ext-diff", "--no-renames", "--name-only", "-z", base])
    split_paths(diff)
  end

  defp request_identity(identity, context, policy, checks, mode) do
    Map.merge(identity, %{
      "version" => @version,
      "service_digest" => @service_digest,
      "mode" => to_string(mode),
      "policy_digest" => policy.digest,
      "policy_revision" => policy.revision,
      "environment" => Jason.decode!(Jason.encode!(policy.environment)),
      "context" => Jason.decode!(Jason.encode!(context)),
      "check_ids" => Enum.map(checks, & &1.id)
    })
  end

  defp focused_checks(checks, :final, nil), do: {:ok, checks}
  defp focused_checks(_checks, :final, _ids), do: {:error, :final_validation_cannot_skip_checks}
  defp focused_checks(checks, :development, nil), do: {:ok, checks}

  defp focused_checks(checks, :development, ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, fn id -> Enum.any?(checks, &(&1.id == id)) end), do: {:ok, Enum.filter(checks, &(&1.id in ids))}, else: {:error, :unknown_focused_check}
  end

  defp focused_checks(_checks, _mode, _ids), do: {:error, :invalid_validation_mode}

  defp execute_or_recover(id, request, workspace, paths, checks, policy, key, roots, mode) do
    manifest_path = Path.join([roots.archive, id, "manifest.json"])

    case File.read(manifest_path) do
      {:ok, bytes} ->
        receipt = %{"id" => id, "manifest_sha256" => digest(bytes)}
        with {:ok, _} <- read_receipt(receipt, roots.archive), do: {:ok, receipt}

      {:error, :enoent} ->
        execute_new(id, request, workspace, paths, checks, policy, key, roots, mode)

      {:error, reason} ->
        {:error, {:receipt_store_error, reason}}
    end
  end

  defp execute_new(id, request, workspace, paths, checks, policy, key, roots, mode) do
    job = Path.join(roots.scratch, "job-" <> random_id())
    source = Path.join(job, "source")
    started = DateTime.utc_now() |> DateTime.to_iso8601()

    with :ok <- File.mkdir_p(source) do
      try do
        with :ok <- snapshot(workspace, source, request["candidate_sha"], paths, mode),
             {:ok, before_digest} <- source_digest(source, paths),
             true <- before_digest == request["source_digest"] do
          results = Enum.map(checks, &evaluate(&1, policy.environment, source, paths, before_digest))

          manifest =
            Map.merge(request, %{"id" => id, "producer" => digest(key), "started_at" => started, "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(), "complete" => true, "checks" => results})

          persist(manifest, key, roots.archive)
        else
          false -> {:error, :source_changed_during_snapshot}
          error -> error
        end
      after
        File.rm_rf(job)
      end
    end
  end

  defp snapshot(workspace, source, head, paths, :final) do
    tar = Path.join(Path.dirname(source), "source.tar")

    with {:ok, _} <- git(workspace, ["archive", "--format=tar", "--output=" <> tar, head]),
         :ok <- :erl_tar.extract(String.to_charlist(tar), [{:cwd, String.to_charlist(source)}]) do
      writable_source(source, paths)
    end
  end

  defp snapshot(workspace, source, _head, paths, :development) do
    Enum.each(paths, fn path ->
      destination = Path.join(source, path)
      File.mkdir_p!(Path.dirname(destination))
      {:ok, _} = File.cp_r(Path.join(workspace, path), destination, dereference_symlinks: false)
    end)

    writable_source(source, paths)
  end

  defp writable_source(source, paths) do
    # No host mount is used. These permissions allow only the nobody user inside
    # the disposable container to generate build outputs in its copied source.
    Enum.each(paths, fn path ->
      file = Path.join(source, path)

      case File.lstat(file) do
        {:ok, %{type: :regular, mode: mode}} -> File.chmod!(file, if(Bitwise.band(mode, 0o111) > 0, do: 0o777, else: 0o666))
        _ -> :ok
      end

      writable_parents(Path.dirname(file), source)
    end)

    File.chmod(source, 0o777)
  end

  defp writable_parents(path, root) when path == root, do: :ok

  defp writable_parents(path, root) do
    File.chmod!(path, 0o777)
    writable_parents(Path.dirname(path), root)
  end

  defp evaluate(check, environment, source, paths, expected_digest) do
    started = System.monotonic_time(:millisecond)
    result = ValidationCommand.run(check, environment, source, paths)
    base = %{"id" => check.id, "command" => check.command, "adapter" => "command-v1", "timeout_ms" => check.timeout_ms, "duration_ms" => System.monotonic_time(:millisecond) - started}

    case result do
      {:ok, result} ->
        output = redact(result.output)
        {assertions, malformed} = assertions(check.result_format, output)
        unchanged = result.source_after == expected_digest

        valid =
          not malformed and not result.truncated and unchanged and not result.oom_killed and not result.timed_out and Map.get(assertions, "skipped_test_count", 0) == 0 and
            Map.get(assertions, "test_count", 1) > 0

        status = if valid, do: "completed", else: "incomplete"

        reason =
          cond do
            result.timed_out -> "deadline_exceeded"
            result.oom_killed -> "out_of_memory"
            not unchanged -> "source_modified_by_check"
            malformed -> "malformed_assertions"
            Map.get(assertions, "skipped_test_count", 0) > 0 -> "skipped_required_tests"
            Map.get(assertions, "test_count", 1) == 0 -> "no_tests_executed"
            result.truncated -> "output_truncated"
            true -> result.cause
          end

        Map.merge(base, %{
          "status" => status,
          "reason" => reason,
          "exit_status" => result.exit_status,
          "source_after" => result.source_after,
          "build_digest" => result.build_digest,
          "limits" => result.limits,
          "output" => output,
          "assertions" => Map.merge(assertions, %{"exit_status" => result.exit_status, "completed" => valid})
        })

      {:error, reason} ->
        Map.merge(base, %{"status" => "incomplete", "reason" => inspect(reason), "exit_status" => nil, "assertions" => %{}, "output" => ""})
    end
  end

  defp assertions("exit_status", _output), do: {%{}, false}

  defp assertions("unittest", output) do
    case Regex.run(~r/\bRan (\d+) tests? in [0-9.]+s\s+OK(?: \(skipped=(\d+)\))?\s*\z/, output) do
      [_, count] ->
        {%{"test_count" => String.to_integer(count), "skipped_test_count" => 0}, false}

      [_, count, skipped] ->
        {%{"test_count" => String.to_integer(count), "skipped_test_count" => String.to_integer(skipped)}, false}

      _ ->
        if Regex.match?(~r/\bRan 0 tests in [0-9.]+s/, output),
          do: {%{"test_count" => 0, "skipped_test_count" => 0}, false},
          else: {%{}, true}
    end
  end

  defp assertions("assertions_v1", output) do
    case Jason.decode(output) do
      {:ok, %{"assertions" => assertions} = document} when is_map(assertions) ->
        valid = Map.keys(document) == ["assertions"] and Enum.all?(assertions, fn {key, value} -> is_binary(key) and scalar?(value) end)
        {assertions, not valid}

      _ ->
        {%{}, true}
    end
  end

  defp scalar?(value), do: is_boolean(value) or is_integer(value) or is_binary(value)

  defp persist(manifest, key, archive) do
    directory = Path.join(archive, manifest["id"])
    temporary = directory <> ".pending-" <> random_id()
    File.mkdir_p!(temporary)
    File.chmod!(temporary, 0o700)

    try do
      {checks, artifacts} =
        Enum.map_reduce(manifest["checks"], [], fn check, acc ->
          filename = "check-" <> digest(check["id"]) <> ".log"
          bytes = check["output"]
          File.write!(Path.join(temporary, filename), bytes, [:binary, :exclusive])
          artifact = %{"file" => filename, "sha256" => digest(bytes), "bytes" => byte_size(bytes)}
          {Map.put(Map.delete(check, "output"), "artifact", artifact), acc ++ [artifact]}
        end)

      manifest = Map.merge(manifest, %{"checks" => checks, "artifacts" => artifacts})
      bytes = Jason.encode!(manifest, pretty: true)
      File.write!(Path.join(temporary, "manifest.mac"), mac(key, bytes), [:exclusive])
      File.write!(Path.join(temporary, "manifest.json"), bytes, [:exclusive])
      # Sync every evidence file before the atomic directory rename and worker acknowledgment.
      Enum.each(File.ls!(temporary), fn file -> sync_file(Path.join(temporary, file)) end)
      :ok = File.rename(temporary, directory)
      sync_directory(archive)
      {:ok, %{"id" => manifest["id"], "manifest_sha256" => digest(bytes)}}
    after
      File.rm_rf(temporary)
    end
  end

  defp verify_artifacts(manifest, archive) do
    directory = Path.join(archive, manifest["id"])
    artifacts = manifest["artifacts"]

    if is_list(artifacts) and length(artifacts) == length(manifest["check_ids"]) and
         Enum.map(manifest["checks"], & &1["id"]) == manifest["check_ids"] and
         Enum.all?(artifacts, fn artifact ->
           file = artifact["file"]

           is_binary(file) and Path.basename(file) == file and
             case File.read(Path.join(directory, file)) do
               {:ok, bytes} -> digest(bytes) == artifact["sha256"] and byte_size(bytes) == artifact["bytes"]
               _ -> false
             end
         end), do: :ok, else: {:error, :missing_or_corrupt_validation_artifacts}
  end

  defp producer_key(archive) do
    path = Path.join(archive, "producer.key")

    case File.read(path) do
      {:ok, key} when byte_size(key) == 32 ->
        {:ok, key}

      {:error, :enoent} ->
        key = :crypto.strong_rand_bytes(32)

        case File.write(path, key, [:binary, :exclusive]) do
          :ok ->
            File.chmod!(path, 0o600)
            sync_file(path)
            {:ok, key}

          {:error, :eexist} ->
            producer_key(archive)

          error ->
            error
        end

      _ ->
        {:error, :invalid_evidence_producer_key}
    end
  end

  defp sync_file(path) do
    {:ok, file} = :file.open(String.to_charlist(path), [:raw, :read, :write])

    try do
      :ok = :file.sync(file)
    after
      :file.close(file)
    end
  end

  defp sync_directory(path) do
    # Linux fsync of the parent directory persists the rename.
    {:ok, file} = :file.open(String.to_charlist(path), [:raw, :read, :directory])

    try do
      :ok = :file.sync(file)
    after
      :file.close(file)
    end
  end

  defp file_identity(root, path) do
    with true <- safe_relative?(path),
         :ok <- safe_parents(root, Path.dirname(path)),
         {:ok, stat} <- File.lstat(Path.join(root, path)) do
      case stat.type do
        :regular ->
          {:ok, bytes} = File.read(Path.join(root, path))
          {:ok, [path, "file", Bitwise.band(stat.mode, 0o111) > 0, digest(bytes)]}

        :symlink ->
          {:ok, target} = File.read_link(Path.join(root, path))
          {:ok, [path, "link", target]}

        _ ->
          {:error, {:invalid_candidate_file, path}}
      end
    else
      _ -> {:error, {:missing_or_substituted_source, path}}
    end
  end

  defp safe_parents(_root, "."), do: :ok

  defp safe_parents(root, relative) do
    with :ok <- safe_parents(root, Path.dirname(relative)), {:ok, %{type: :directory}} <- File.lstat(Path.join(root, relative)), do: :ok, else: (_ -> {:error, :candidate_parent_symlink})
  end

  defp safe_relative?(path), do: Path.type(path) == :relative and not Enum.any?(Path.split(path), &(&1 in ["..", ".git"]))
  defp overlap?(a, b) when a == "/" or b == "/", do: true
  defp overlap?(a, b), do: a == b or String.starts_with?(a, b <> "/") or String.starts_with?(b, a <> "/")
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp mac(key, bytes), do: :crypto.mac(:hmac, :sha256, key, bytes) |> Base.encode16(case: :lower)
  defp random_id, do: Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
  defp split_paths(bytes), do: String.split(bytes, <<0>>, trim: true)
  defp failed_gate(id, reason), do: %{verdict: :failed, evidence_id: id, rationale: [inspect(reason)]}

  defp git(workspace, args) do
    case System.cmd("git", ["--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null" | args], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim_trailing(output, "\n")}
      {_output, status} -> {:error, {:candidate_git_error, hd(args), status}}
    end
  end

  defp redact(output) do
    output = String.replace(output, ~r/(?:sk-|gh[pousr]_|github_pat_)[A-Za-z0-9_-]+/, "[REDACTED]")

    Enum.reduce(System.get_env(), output, fn {key, value}, acc ->
      if String.match?(key, ~r/TOKEN|SECRET|PASSWORD|API_KEY|ACCESS_KEY/) and byte_size(value) >= 8, do: String.replace(acc, value, "[REDACTED]"), else: acc
    end)
  end
end
