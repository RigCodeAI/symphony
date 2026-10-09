defmodule SymphonyElixir.WorkstreamRunner do
  @moduledoc """
  Prepares and executes stages from a validated local workstream.

  `run/3` remains a synchronous convenience runner. It stops at a human wait and
  reports the question for a coordinator to persist and deliver. `prepare/3` and
  `execute_stage/4` expose the same validation, workspace safety, and stage execution
  for a durable coordinator. This module does not schedule, persist, publish, or merge.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{PathSafety, Validation, ValidationPolicy, Workstream, WorkstreamCommand}

  @source_root Path.expand("../../..", __DIR__)

  @doc """
  Resolves the execution settings that must be persisted with a run.

  The default Codex command captures the current `PATH`, so a resumed run uses the same
  executable search path after a restart.
  """
  @spec execution_context(keyword()) :: %{workspace_root: Path.t(), codex_command: String.t()}
  def execution_context(opts) do
    %{
      workspace_root: Keyword.fetch!(opts, :workspace_root),
      codex_command: Keyword.get_lazy(opts, :codex_command, &default_codex_command/0)
    }
  end

  @doc "Pins validation policy and storage roots for a prepared run."
  @spec pin_execution_context(keyword(), Path.t(), Workstream.loaded_workstream()) ::
          {:ok, map()} | {:error, term()}
  def pin_execution_context(opts, workspace, definition) do
    context = execution_context(opts)

    case candidate_validation_stages(definition) do
      [] ->
        {:ok, context}

      _stages ->
        with {:ok, validation} <- prepared_validation_context(opts, workspace, definition) do
          {:ok, Map.merge(context, validation)}
        end
    end
  end

  @doc """
  Loads and validates a workstream, then verifies and returns its canonical workspace.
  """
  @spec prepare(Path.t(), map(), keyword()) ::
          {:ok, Workstream.loaded_workstream(), Path.t()} | {:error, term()}
  def prepare(path, inputs, opts) do
    with :ok <- subscription_environment(),
         {:ok, definition} <- Workstream.load(path, inputs),
         {:ok, workspace} <- workspace(opts, definition),
         :ok <- dedicated_clone(workspace),
         {:ok, definition} <- pin_definition_validation(opts, workspace, definition) do
      {:ok, definition, workspace}
    end
  end

  @doc """
  Runs a validated local workstream synchronously until it completes, blocks, or reaches
  a human wait. A wait returns `status: :waiting_for_answer` with its prompt and resolved inputs.
  """
  @spec run(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, inputs, opts) do
    with {:ok, definition, workspace} <- prepare(path, inputs, opts),
         {:ok, execution} <- pin_execution_context(opts, workspace, definition) do
      state = %{
        id: "local",
        task_id: "local",
        status: :running,
        workspace: workspace,
        execution: execution,
        attempts: [],
        repairs: %{},
        validation_repair_rounds: 0,
        outputs: inputs,
        definitions: Map.new(definition.definitions, fn {path, resource} -> {path, resource.sha256} end)
      }

      execute(definition.entry, definition, state, Keyword.merge(opts, Map.to_list(execution)))
    end
  end

  @doc """
  Executes one agent or check stage without following its transition or scheduling another stage.
  Human waits are coordinated separately and return `:human_wait_requires_coordinator`.
  """
  @spec execute_stage(Workstream.loaded_stage() | String.t(), Workstream.loaded_workstream(), map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute_stage(stage_id, definition, state, opts) when is_binary(stage_id) do
    case Map.fetch(definition.stages, stage_id) do
      {:ok, stage} -> execute_stage(stage, definition, state, opts)
      :error -> {:error, {:unknown_workstream_stage, stage_id}}
    end
  end

  def execute_stage(%{type: :agent} = stage, definition, state, opts) do
    with {:ok, workspace} <- stage_workspace(state, definition, opts) do
      run_agent(stage, definition, %{state | workspace: workspace}, opts)
    end
  end

  def execute_stage(%{type: :check} = stage, definition, state, opts) do
    with {:ok, workspace} <- stage_workspace(state, definition, opts) do
      if stage.gate[:evaluator] == :candidate_validation do
        execute_candidate_validation(stage, state, workspace, opts)
      else
        WorkstreamCommand.run(
          stage.gate.command,
          workspace,
          stage.gate.timeout_ms,
          Map.take(state.outputs, stage.inputs)
        )
      end
    end
  end

  def execute_stage(%{type: :human_wait}, _definition, _state, _opts),
    do: {:error, :human_wait_requires_coordinator}

  def execute_stage(_stage, _definition, _state, _opts),
    do: {:error, :invalid_workstream_stage}

  @doc """
  Revalidates a pinned workspace before a stage executes and returns its canonical path.

  The supplied workspace must already be canonical. This detects a workspace path that was
  replaced by a symlink after the run was prepared.
  """
  @spec validate_workspace(Path.t(), Path.t(), Workstream.loaded_workstream()) ::
          {:ok, Path.t()} | {:error, term()}
  def validate_workspace(workspace, workspace_root, definition) do
    with {:ok, canonical_workspace} <-
           workspace([workspace: workspace, workspace_root: workspace_root], definition),
         :ok <- pinned_workspace(workspace, canonical_workspace),
         :ok <- dedicated_clone(canonical_workspace) do
      {:ok, canonical_workspace}
    end
  end

  defp workspace(opts, definition) when is_list(opts) do
    if Keyword.keyword?(opts) do
      workspace_with_options(opts, definition)
    else
      {:error, :invalid_workspace_options}
    end
  end

  defp workspace(_opts, _definition), do: {:error, :invalid_workspace_options}

  defp workspace_with_options(opts, definition) do
    with {:ok, root} <- workspace_option(opts, :workspace_root),
         {:ok, requested} <- workspace_option(opts, :workspace),
         {:ok, root} <- PathSafety.canonicalize(root),
         {:ok, workspace} <- PathSafety.canonicalize(requested),
         {:ok, source} <- PathSafety.canonicalize(@source_root) do
      protected = [source | Map.keys(definition.definitions)]

      cond do
        workspace == root ->
          {:error, :workspace_equals_root}

        not within?(workspace, root) ->
          {:error, :workspace_outside_root}

        Enum.any?(protected, &(within?(workspace, &1) or within?(&1, workspace) or &1 == workspace)) ->
          {:error, :workspace_overlaps_source_or_definitions}

        not File.dir?(workspace) ->
          {:error, :workspace_missing}

        true ->
          {:ok, workspace}
      end
    end
  end

  defp workspace_option(opts, key) do
    if is_list(opts) and Keyword.keyword?(opts) do
      case Keyword.fetch(opts, key) do
        {:ok, path} when is_binary(path) -> {:ok, path}
        {:ok, path} -> {:error, {:invalid_workspace_option, key, path}}
        :error -> {:error, {:missing_workspace_option, key}}
      end
    else
      {:error, :invalid_workspace_options}
    end
  end

  defp candidate_validation_stages(definition) do
    Enum.filter(Map.values(definition.stages), fn stage ->
      stage.type == :check and stage.gate[:evaluator] == :candidate_validation
    end)
  end

  defp pin_definition_validation(opts, workspace, definition) do
    case candidate_validation_stages(definition) do
      [] ->
        {:ok, definition}

      _stages ->
        with {:ok, validation} <- pin_validation_context(opts, workspace, definition) do
          {:ok, Map.put(definition, :pinned_validation_context, validation)}
        end
    end
  end

  defp prepared_validation_context(_opts, _workspace, %{pinned_validation_context: validation}),
    do: {:ok, validation}

  defp prepared_validation_context(opts, workspace, definition),
    do: pin_validation_context(opts, workspace, definition)

  defp pin_validation_context(opts, workspace, definition) do
    with {:ok, policy_path} <- absolute_path_option(opts, :validation_policy),
         {:ok, policy} <- ValidationPolicy.load(policy_path, workspace),
         {:ok, archive} <- external_path_option(opts, :validation_archive, workspace),
         {:ok, scratch} <- external_path_option(opts, :validation_scratch, workspace),
         :ok <- distinct_validation_roots(archive, scratch),
         :ok <- validation_paths_outside_definitions([archive, scratch], [policy.path | Map.keys(definition.definitions)]),
         {:ok, base_sha} <- validation_base_option(opts, workspace) do
      {:ok,
       %{
         validation_policy: policy,
         validation_archive: archive,
         validation_scratch: scratch,
         validation_base: base_sha
       }}
    end
  end

  defp absolute_path_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, path} when is_binary(path) ->
        if Path.type(path) == :absolute,
          do: {:ok, path},
          else: {:error, {:invalid_validation_path, key, path}}

      {:ok, path} ->
        {:error, {:invalid_validation_path, key, path}}

      :error ->
        {:error, {:missing_validation_option, key}}
    end
  end

  defp external_path_option(opts, key, workspace) do
    case Keyword.fetch(opts, key) do
      {:ok, path} when is_binary(path) ->
        if Path.type(path) == :absolute do
          with {:ok, canonical} <- PathSafety.canonicalize(path),
               :ok <- path_outside_workspace(canonical, workspace, key) do
            {:ok, canonical}
          end
        else
          {:error, {:invalid_validation_path, key, path}}
        end

      {:ok, path} ->
        {:error, {:invalid_validation_path, key, path}}

      :error ->
        {:error, {:missing_validation_option, key}}
    end
  end

  defp validation_base_option(opts, workspace) do
    case Keyword.fetch(opts, :validation_base) do
      {:ok, sha} when is_binary(sha) ->
        if Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, sha) do
          git_args = [
            "--no-replace-objects",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "core.hooksPath=/dev/null",
            "rev-parse",
            "--verify",
            sha <> "^{commit}"
          ]

          case System.cmd("git", git_args, cd: workspace, stderr_to_stdout: true) do
            {resolved, 0} ->
              if String.trim(resolved) == sha,
                do: {:ok, sha},
                else: {:error, :validation_base_must_be_an_existing_commit}

            _ ->
              {:error, :validation_base_must_be_an_existing_commit}
          end
        else
          {:error, {:invalid_validation_base, sha}}
        end

      {:ok, sha} ->
        {:error, {:invalid_validation_base, sha}}

      :error ->
        {:error, {:missing_validation_option, :validation_base}}
    end
  end

  defp path_outside_workspace(path, workspace, key) do
    if path == workspace or within?(path, workspace) or within?(workspace, path) do
      {:error, {:validation_path_overlaps_workspace, key}}
    else
      :ok
    end
  end

  defp distinct_validation_roots(first, second) do
    if paths_overlap?(first, second), do: {:error, :validation_storage_roots_overlap}, else: :ok
  end

  defp validation_paths_outside_definitions(paths, definitions) do
    case PathSafety.canonicalize(@source_root) do
      {:ok, source_root} ->
        protected = [source_root | definitions]

        if Enum.any?(paths, fn path -> Enum.any?(protected, &paths_overlap?(path, &1)) end),
          do: {:error, :validation_storage_overlaps_trusted_definitions},
          else: :ok

      {:error, _} = error ->
        error
    end
  end

  defp paths_overlap?(first, second) do
    first == second or within?(first, second) or within?(second, first)
  end

  defp execute_candidate_validation(stage, state, workspace, opts) do
    policy = Keyword.get(opts, :validation_policy)
    base_sha = Keyword.get(opts, :validation_base)
    archive = Keyword.get(opts, :validation_archive)
    scratch = Keyword.get(opts, :validation_scratch)
    attempt_id = Map.get(state, :current_attempt_id) || stage.id

    if is_map(policy) and is_binary(base_sha) and is_binary(archive) and is_binary(scratch) do
      context = %{
        task_id: Map.get(state, :task_id) || "local",
        run_id: Map.get(state, :id) || "local",
        attempt_id: attempt_id,
        base_sha: base_sha
      }

      Validation.execute(workspace, policy, context, stage.gate.required,
        validation_archive: archive,
        validation_scratch: scratch
      )
    else
      {:error, :candidate_validation_context_not_pinned}
    end
  end

  defp pinned_workspace(workspace, canonical_workspace) when workspace == canonical_workspace, do: :ok
  defp pinned_workspace(_workspace, _canonical_workspace), do: {:error, :workspace_path_changed}

  defp stage_workspace(state, definition, opts) do
    with {:ok, workspace_root} <- workspace_option(opts, :workspace_root) do
      validate_workspace(state.workspace, workspace_root, definition)
    end
  end

  defp within?(path, "/"), do: String.starts_with?(path, "/")
  defp within?(path, root), do: String.starts_with?(path, root <> "/")

  defp subscription_environment do
    names = ~w(OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN)

    if Enum.any?(names, &(System.get_env(&1) not in [nil, ""])) do
      {:error, :local_workstream_requires_subscription_environment}
    else
      :ok
    end
  end

  defp dedicated_clone(workspace) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.join(workspace, ".git")),
         {top, 0} <- System.cmd("git", ["rev-parse", "--show-toplevel"], cd: workspace, stderr_to_stdout: true),
         {:ok, canonical_top} <- PathSafety.canonicalize(String.trim(top)),
         true <- canonical_top == workspace do
      :ok
    else
      _ -> {:error, :workspace_requires_dedicated_clone}
    end
  end

  defp execute(:complete, definition, state, _opts), do: finish(:complete, definition, state)
  defp execute(:blocked, definition, state, _opts), do: finish(:blocked, definition, state)

  defp execute(id, definition, state, opts) do
    stage = Map.fetch!(definition.stages, id)

    if stage.type == :human_wait do
      wait(stage, definition, state)
    else
      execute_stage_attempt(stage, definition, state, opts)
    end
  end

  defp execute_stage_attempt(stage, definition, state, opts) do
    started = System.monotonic_time(:millisecond)
    attempt_id = Map.get(state, :current_attempt_id) || "local/#{stage.id}/#{length(state.attempts) + 1}"
    execution_state = state |> Map.put_new(:id, "local") |> Map.put_new(:task_id, "local") |> Map.put(:current_attempt_id, attempt_id)
    result = execute_stage(stage, definition, execution_state, opts)

    {result, gate, gate_detail} =
      if candidate_validation?(stage) do
        case verify_candidate_result(stage, execution_state, result, opts) do
          {:ok, %{verdict: verdict} = detail, feedback} when verdict in [:passed, :failed] ->
            {put_candidate_result(result, detail, feedback), verdict, json_value(detail)}

          {:error, reason} ->
            failed_validation_result(result, reason)
        end
      else
        {result, nil, nil}
      end

    attempt = %{
      stage: stage.id,
      type: stage.type,
      duration_ms: System.monotonic_time(:millisecond) - started,
      result: result_evidence(result),
      gate: gate,
      gate_detail: gate_detail
    }

    state = %{state | attempts: state.attempts ++ [attempt]}

    case stage.type do
      :agent ->
        case result do
          {:ok, evidence} -> execute(stage.next, definition, put_outputs(state, stage, evidence), opts)
          {:error, _} -> finish(:blocked, definition, state)
        end

      :check ->
        cond do
          candidate_validation?(stage) and gate == :passed ->
            {:ok, evidence} = result
            execute(stage.gate.success, definition, put_outputs(state, stage, evidence), opts)

          candidate_validation?(stage) ->
            candidate_validation_repair_or_block(stage, definition, state, opts)

          match?({:ok, %{exit_status: 0}}, result) ->
            {:ok, evidence} = result
            execute(stage.gate.success, definition, put_outputs(state, stage, evidence), opts)

          true ->
            repair_or_block(stage.gate.failure, stage.id, definition, state, opts)
        end
    end
  end

  defp verify_candidate_result(stage, state, result, opts) do
    context = %{
      task_id: Map.get(state, :task_id) || "local",
      run_id: Map.get(state, :id) || "local",
      attempt_id: Map.get(state, :current_attempt_id) || stage.id,
      base_sha: Keyword.get(opts, :validation_base)
    }

    validation_opts = [
      workspace: state.workspace,
      validation_archive: Keyword.get(opts, :validation_archive),
      validation_scratch: Keyword.get(opts, :validation_scratch)
    ]

    case Validation.verify_result(
           result,
           Keyword.get(opts, :validation_policy),
           context,
           stage.gate.required,
           validation_opts
         ) do
      {:ok, %{verdict: verdict} = gate} when verdict in [:passed, :failed] ->
        with {:ok, feedback} <- verified_candidate_feedback(result, Keyword.get(opts, :validation_archive)) do
          {:ok, gate, feedback}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:validation_verification_failed, error}}
  end

  defp verified_candidate_feedback({:ok, %{receipt: receipt}}, archive) do
    case Validation.feedback(receipt, archive) do
      {:ok, feedback} when is_list(feedback) -> {:ok, json_value(feedback)}
      {:error, _reason} = error -> error
    end
  end

  defp verified_candidate_feedback(_result, _archive), do: {:error, :missing_validation_receipt}

  defp failed_validation_result(result, reason) do
    failure = %{verdict: :failed, rationale: ["Validation evidence could not be verified."], evidence_id: nil}
    detail = %{"verdict" => "failed", "verified" => false, "reason" => inspect(reason)}
    {put_candidate_result(result, failure, nil), :failed, detail}
  end

  defp put_candidate_result(
         {:ok, %{receipt: %{"id" => id, "manifest_sha256" => manifest_sha256}}},
         gate,
         feedback
       )
       when is_binary(id) and is_binary(manifest_sha256) and is_list(feedback) do
    receipt = %{"id" => id, "manifest_sha256" => manifest_sha256}
    {:ok, %{receipt: receipt, gate: gate, feedback: feedback}}
  end

  defp put_candidate_result(_result, _gate, _feedback), do: {:error, :unverified_validation_result}

  defp candidate_validation_repair_or_block(stage, definition, state, opts) do
    rounds = Map.get(state, :validation_repair_rounds, 0) + 1
    state = Map.put(state, :validation_repair_rounds, rounds)

    case stage.gate.failure do
      %{repair: repair, max_attempts: max_attempts} ->
        repairs = Map.get(state.repairs, stage.id, 0)

        if rounds < 3 and repairs < max_attempts do
          execute(repair, definition, %{state | repairs: Map.put(state.repairs, stage.id, repairs + 1)}, opts)
        else
          execute(:blocked, definition, state, opts)
        end

      _ ->
        execute(:blocked, definition, state, opts)
    end
  end

  defp wait(stage, definition, state) do
    wait = %{stage: stage.id, prompt: stage.prompt, inputs: Map.take(state.outputs, stage.inputs)}

    state
    |> Map.merge(%{status: :waiting_for_answer, wait: wait})
    |> Map.update!(:outputs, &Map.drop(&1, definition.inputs))
    |> then(&{:ok, &1})
  end

  defp put_outputs(state, stage, evidence) do
    %{state | outputs: Enum.reduce(stage.outputs, state.outputs, &Map.put(&2, &1, evidence))}
  end

  defp finish(status, definition, state),
    do: %{state | status: status, outputs: Map.drop(state.outputs, definition.inputs)} |> then(&{:ok, &1})

  defp result_evidence({:ok, evidence}), do: %{status: :ok, evidence: evidence}
  defp result_evidence({:error, reason}), do: %{status: :error, reason: inspect(reason)}

  defp candidate_validation?(%{type: :check, gate: %{evaluator: :candidate_validation}}), do: true
  defp candidate_validation?(_stage), do: false

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp repair_or_block(:blocked, _id, definition, state, opts), do: execute(:blocked, definition, state, opts)

  defp repair_or_block(%{repair: repair, max_attempts: max}, id, definition, state, opts) do
    count = Map.get(state.repairs, id, 0)

    if count < max do
      execute(repair, definition, %{state | repairs: Map.put(state.repairs, id, count + 1)}, opts)
    else
      execute(:blocked, definition, state, opts)
    end
  end

  defp run_agent(stage, definition, state, opts) do
    agent = Map.fetch!(definition.agents, stage.agent)
    issue = %{id: "local-#{definition.name}", identifier: definition.name, title: stage.id}
    inputs = Map.take(state.outputs, stage.inputs)
    resources = agent.instructions ++ agent.skills

    prompt =
      Enum.map_join(resources, "\n\n", & &1.text) <>
        "\n\nStage instructions:\n#{stage.prompt}\n\nDeclared inputs:\n#{Jason.encode!(inputs)}\n" <>
        "Work only in #{state.workspace}. Do not push, publish a PR, merge, or modify definitions." <>
        repair_feedback(state)

    app_opts = [
      workspace_root: Keyword.fetch!(opts, :workspace_root),
      command: Keyword.get_lazy(opts, :codex_command, &default_codex_command/0),
      model: agent.model,
      reasoning_effort: agent.reasoning_effort,
      dynamic_tools: false,
      read_timeout_ms: 30_000,
      turn_timeout_ms: 120_000,
      runtime_settings: %{
        approval_policy: agent.approval_policy,
        thread_sandbox: agent.sandbox,
        turn_sandbox_policy: %{
          "type" => "workspaceWrite",
          "writableRoots" => [state.workspace],
          "networkAccess" => false
        }
      },
      on_message: fn _event -> :ok end
    ]

    runner = Keyword.get(opts, :agent_executor, &AppServer.run/4)

    case runner.(state.workspace, prompt, issue, app_opts) do
      {:ok, evidence} ->
        {:ok, Map.put(Map.take(evidence, [:thread_id, :turn_id, :session_id, :model, :reasoning_effort]), :workspace, state.workspace)}

      {:error, _reason} ->
        {:error, :agent_execution_failed}
    end
  end

  defp repair_feedback(%{attempts: attempts}) do
    case List.last(attempts) do
      %{type: :check, result: result} = attempt ->
        detail = Map.get(attempt, :gate_detail)
        "\nGate failure triggering repair:\n#{Jason.encode!(%{result: result, gate_detail: detail})}"

      _ ->
        ""
    end
  end

  defp default_codex_command do
    path = "'" <> String.replace(System.get_env("PATH", ""), "'", "'\\''") <> "'"
    "env PATH=#{path} codex --disable apps --disable plugins --disable multi_agent -c 'forced_login_method=\"chatgpt\"' app-server"
  end
end
