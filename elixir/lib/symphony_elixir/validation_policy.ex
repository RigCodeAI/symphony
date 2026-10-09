defmodule SymphonyElixir.ValidationPolicy do
  @moduledoc """
  Loads a trusted validation policy and selects its checks for a candidate diff.

  Policy files must be outside the candidate workspace. The returned policy includes the
  canonical source path, source text, and digest so the caller can pin the exact definition.
  """

  @max_timeout_ms 300_000
  @policy_fields ~w(version revision environment checks)
  @environment_fields ~w(image runner_version)
  @check_fields ~w(id adapter command timeout_ms paths result_format)

  @type assertion :: %{check: String.t(), assertion: String.t(), equals: boolean() | integer() | String.t()}
  @type check :: %{
          id: String.t(),
          adapter: String.t(),
          command: [String.t()],
          timeout_ms: pos_integer(),
          paths: [String.t()],
          result_format: String.t()
        }
  @type policy :: %{
          version: 1,
          revision: String.t(),
          digest: String.t(),
          path: Path.t(),
          text: String.t(),
          environment: %{image: String.t(), runner_version: String.t()},
          checks: [check()]
        }

  @doc "Loads and pins a version 1 validation policy outside the candidate workspace."
  @spec load(Path.t(), Path.t()) :: {:ok, policy()} | {:error, term()}
  def load(path, workspace) when is_binary(path) and is_binary(workspace) do
    with {:ok, canonical_path} <- canonical_policy_path(path, workspace),
         {:ok, source} <- read_policy(canonical_path),
         {:ok, document} <- parse_policy(source, canonical_path),
         :ok <- exact_fields(document, @policy_fields, :policy),
         :ok <- version(Map.get(document, "version")),
         {:ok, revision} <- required_string(Map.get(document, "revision"), :revision),
         {:ok, environment} <- normalize_environment(Map.get(document, "environment")),
         {:ok, checks} <- normalize_checks(Map.get(document, "checks")) do
      {:ok,
       %{
         version: 1,
         revision: revision,
         digest: sha256(source),
         path: canonical_path,
         text: source,
         environment: environment,
         checks: checks
       }}
    end
  end

  def load(path, workspace),
    do: {:error, {:invalid_policy_paths, path, workspace}}

  @doc "Selects checks that cover the changed paths using exact names and directory prefixes."
  @spec resolve(policy(), [String.t()]) :: {:ok, [check()]} | {:error, term()}
  def resolve(policy, changed_paths), do: resolve(policy, changed_paths, "ordinary")

  @spec resolve(policy(), [String.t()], String.t()) :: {:ok, [check()]} | {:error, term()}
  def resolve(%{version: 1, checks: checks}, changed_paths, kind)
      when is_list(checks) and is_list(changed_paths) do
    with {:ok, kind} <- validation_kind(kind),
         :ok <- valid_changed_paths(changed_paths) do
      resolve_checks(checks, changed_paths, kind)
    end
  end

  def resolve(_policy, _changed_paths, _kind), do: {:error, :invalid_policy}

  @doc "Validates and normalizes an inline list of required assertions."
  @spec validate_required(term()) :: {:ok, [assertion()]} | {:error, term()}
  def validate_required(required) when is_list(required) and required != [] do
    required
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {item, index}, {:ok, acc, seen} ->
      case normalize_assertion(item) do
        {:ok, assertion} ->
          key = {assertion.check, assertion.assertion}

          if MapSet.member?(seen, key) do
            {:halt, {:error, {:duplicate_required_assertion, assertion.check, assertion.assertion}}}
          else
            {:cont, {:ok, [assertion | acc], MapSet.put(seen, key)}}
          end

        {:error, reason} ->
          {:halt, {:error, {:invalid_required_assertion, index, reason}}}
      end
    end)
    |> case do
      {:ok, assertions, _seen} -> {:ok, Enum.reverse(assertions)}
      {:error, _} = error -> error
    end
  end

  def validate_required([]), do: {:error, :empty_required_assertions}
  def validate_required(_required), do: {:error, :invalid_required_assertions}

  @doc "Evaluates a final receipt against required assertions without authenticating the receipt."
  @spec gate(term(), term()) :: %{
          verdict: :passed | :failed,
          rationale: [String.t()],
          evidence_id: term()
        }
  def gate(evidence, required) do
    evidence_id = if is_map(evidence), do: Map.get(evidence, "id"), else: nil

    with {:ok, assertions} <- validate_required(required),
         {:ok, checks} <- final_checks(evidence),
         :ok <- all_checks_passed(checks),
         :ok <- required_assertions_passed(checks, assertions) do
      %{
        verdict: :passed,
        rationale: ["All selected checks completed successfully and every required assertion matched."],
        evidence_id: evidence_id
      }
    else
      {:error, reason} ->
        %{verdict: :failed, rationale: [gate_rationale(reason)], evidence_id: evidence_id}
    end
  end

  defp canonical_policy_path(path, workspace) do
    expanded_path = Path.expand(path)

    with {:ok, canonical_path} <- canonicalize(path, :policy),
         true <- canonical_path == expanded_path,
         {:ok, canonical_workspace} <- canonicalize(workspace, :workspace) do
      if paths_overlap?(canonical_path, canonical_workspace) do
        {:error, :policy_path_overlaps_workspace}
      else
        {:ok, canonical_path}
      end
    else
      false -> {:error, :policy_path_is_symlink}
      {:error, _} = error -> error
    end
  end

  defp canonicalize(path, context) do
    case SymphonyElixir.PathSafety.canonicalize(path) do
      {:ok, canonical_path} -> {:ok, canonical_path}
      {:error, reason} -> {:error, {:policy_path_error, context, Path.expand(path), reason}}
    end
  end

  defp paths_overlap?(first, second) do
    path_within?(first, second) or path_within?(second, first)
  end

  defp path_within?(path, "/"), do: String.starts_with?(path, "/")
  defp path_within?(path, parent), do: path == parent or String.starts_with?(path, parent <> "/")

  defp read_policy(path) do
    case File.read(path) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, {:policy_file_error, path, reason}}
    end
  end

  defp parse_policy(source, path) do
    case YamlElixir.read_from_string(source) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:ok, _document} -> {:error, {:invalid_policy, :expected_map}}
      {:error, reason} -> {:error, {:policy_yaml_error, path, reason}}
    end
  end

  defp exact_fields(document, required, context) when is_map(document) do
    actual = Map.keys(document)
    missing = required -- actual
    unknown = actual -- required

    if missing == [] and unknown == [] do
      :ok
    else
      {:error, {:invalid_policy_fields, context, missing, unknown}}
    end
  end

  defp version(1), do: :ok
  defp version(value), do: {:error, {:unsupported_policy_version, value}}

  defp required_string(value, _context) when is_binary(value) do
    if String.trim(value) == "", do: {:error, {:invalid_policy_string, value}}, else: {:ok, value}
  end

  defp required_string(value, context), do: {:error, {:invalid_policy_string, context, value}}

  defp normalize_environment(environment) when is_map(environment) do
    with :ok <- exact_fields(environment, @environment_fields, :environment),
         {:ok, image} <- immutable_image(Map.get(environment, "image")),
         :ok <- runner_version(Map.get(environment, "runner_version")) do
      {:ok, %{image: image, runner_version: "docker-v1"}}
    end
  end

  defp normalize_environment(_environment), do: {:error, {:invalid_policy_environment, :expected_map}}

  defp immutable_image(image) when is_binary(image) do
    if Regex.match?(~r/^[^\s@]+@sha256:[0-9a-fA-F]{64}$/, image) do
      {:ok, image}
    else
      {:error, {:invalid_policy_image, image}}
    end
  end

  defp immutable_image(value), do: {:error, {:invalid_policy_image, value}}

  defp runner_version("docker-v1"), do: :ok
  defp runner_version(value), do: {:error, {:unsupported_policy_runner_version, value}}

  defp normalize_checks(checks) when is_list(checks) and checks != [] do
    checks
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn raw_check, {:ok, acc, ids} ->
      case normalize_check(raw_check) do
        {:ok, check} ->
          if MapSet.member?(ids, check.id) do
            {:halt, {:error, {:duplicate_policy_check_id, check.id}}}
          else
            {:cont, {:ok, [check | acc], MapSet.put(ids, check.id)}}
          end

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized, _ids} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = error -> error
    end
  end

  defp normalize_checks(_checks), do: {:error, {:invalid_policy_checks, :expected_nonempty_list}}

  defp normalize_check(check) when is_map(check) do
    with :ok <- exact_fields(check, @check_fields, {:check, Map.get(check, "id")}),
         {:ok, id} <- required_string(Map.get(check, "id"), :check_id),
         {:ok, adapter} <- adapter(Map.get(check, "adapter"), id),
         {:ok, command} <- command(Map.get(check, "command"), id),
         {:ok, timeout_ms} <- timeout_ms(Map.get(check, "timeout_ms"), id),
         {:ok, paths} <- paths(Map.get(check, "paths"), id),
         {:ok, result_format} <- result_format(Map.get(check, "result_format"), id) do
      {:ok,
       %{
         id: id,
         adapter: adapter,
         command: command,
         timeout_ms: timeout_ms,
         paths: paths,
         result_format: result_format
       }}
    end
  end

  defp normalize_check(value), do: {:error, {:invalid_policy_check, value}}

  defp adapter("command", _id), do: {:ok, "command"}
  defp adapter("coverage", _id), do: {:ok, "coverage"}
  defp adapter(value, id), do: {:error, {:invalid_policy_adapter, id, value}}

  defp command(values, id) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, values}
    else
      {:error, {:invalid_policy_command, id}}
    end
  end

  defp command(_values, id), do: {:error, {:invalid_policy_command, id}}

  defp timeout_ms(value, _id) when is_integer(value) and value > 0 and value <= @max_timeout_ms,
    do: {:ok, value}

  defp timeout_ms(value, id), do: {:error, {:invalid_policy_timeout_ms, id, value}}

  defp paths(values, id) when is_list(values) and values != [] do
    if Enum.all?(values, &valid_scope_pattern?/1) do
      {:ok, values}
    else
      {:error, {:invalid_policy_paths, id}}
    end
  end

  defp paths(_values, id), do: {:error, {:invalid_policy_paths, id}}

  defp valid_scope_pattern?("*"), do: true

  defp valid_scope_pattern?(pattern) when is_binary(pattern) and pattern != "" do
    directory_prefix? = String.ends_with?(pattern, "/")
    base = if directory_prefix?, do: binary_part(pattern, 0, byte_size(pattern) - 1), else: pattern

    valid_relative_path?(base) and
      not String.contains?(pattern, ["*", "?", "[", "]", "{", "}"])
  end

  defp valid_scope_pattern?(_pattern), do: false

  defp valid_relative_path?(path) when is_binary(path) and path != "" do
    not String.starts_with?(path, "/") and not String.contains?(path, "\\") and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp valid_relative_path?(_path), do: false

  defp result_format("exit_status", _id), do: {:ok, "exit_status"}
  defp result_format("assertions_v1", _id), do: {:ok, "assertions_v1"}
  defp result_format("unittest", _id), do: {:ok, "unittest"}
  defp result_format(value, id), do: {:error, {:invalid_policy_result_format, id, value}}

  defp validation_kind("ordinary"), do: {:ok, :ordinary}
  defp validation_kind("coverage"), do: {:ok, :coverage}
  defp validation_kind(value), do: {:error, {:invalid_validation_kind, value}}

  defp valid_changed_paths(paths) do
    if Enum.all?(paths, &(is_binary(&1) and valid_relative_path?(&1))) do
      :ok
    else
      {:error, :uncovered_diff_scope}
    end
  end

  defp resolve_checks(checks, changed_paths, :ordinary) do
    selected = select_checks(checks, changed_paths)

    cond do
      selected == [] -> {:error, :uncovered_diff_scope}
      Enum.any?(selected, &(&1.adapter == "coverage")) -> {:error, :coverage_adapter_unavailable}
      not all_paths_covered?(changed_paths, selected) -> {:error, :uncovered_diff_scope}
      true -> {:ok, selected}
    end
  end

  defp resolve_checks(checks, changed_paths, :coverage) do
    coverage_checks = Enum.filter(checks, &match?(%{adapter: "coverage"}, &1))
    selected = select_checks(coverage_checks, changed_paths)

    cond do
      coverage_checks == [] -> {:error, :coverage_adapter_unavailable}
      selected == [] -> {:error, :uncovered_diff_scope}
      not all_paths_covered?(changed_paths, selected) -> {:error, :uncovered_diff_scope}
      true -> {:error, :coverage_adapter_unavailable}
    end
  end

  defp select_checks(checks, []), do: checks

  defp select_checks(checks, changed_paths) do
    Enum.filter(checks, fn check ->
      Enum.any?(changed_paths, &check_matches_path?(check, &1))
    end)
  end

  defp all_paths_covered?([], [_ | _]), do: true

  defp all_paths_covered?(changed_paths, checks) do
    Enum.all?(changed_paths, fn changed_path ->
      Enum.any?(checks, &check_matches_path?(&1, changed_path))
    end)
  end

  defp check_matches_path?(check, changed_path) do
    Enum.any?(check.paths, fn
      "*" ->
        true

      prefix when is_binary(prefix) ->
        if String.ends_with?(prefix, "/"),
          do: String.starts_with?(changed_path, prefix),
          else: changed_path == prefix
    end)
  end

  defp normalize_assertion(%{check: check, assertion: assertion, equals: equals} = value)
       when map_size(value) == 3 do
    valid_assertion(check, assertion, equals)
  end

  defp normalize_assertion(%{"check" => check, "assertion" => assertion, "equals" => equals} = value)
       when map_size(value) == 3 do
    valid_assertion(check, assertion, equals)
  end

  defp normalize_assertion(_value), do: {:error, :expected_check_assertion_equals}

  defp valid_assertion(check, assertion, equals)
       when is_binary(check) and is_binary(assertion) and
              (is_boolean(equals) or is_integer(equals) or is_binary(equals)) do
    if String.trim(check) != "" and String.trim(assertion) != "" do
      {:ok, %{check: check, assertion: assertion, equals: equals}}
    else
      {:error, :empty_check_or_assertion}
    end
  end

  defp valid_assertion(_check, _assertion, _equals), do: {:error, :invalid_value_types}

  defp final_checks(evidence) when is_map(evidence) do
    cond do
      Map.get(evidence, "mode") != "final" -> {:error, "Evidence is missing or is not final."}
      Map.get(evidence, "complete") !== true -> {:error, "Evidence is incomplete."}
      not is_list(Map.get(evidence, "checks")) -> {:error, "Evidence has no valid check list."}
      Map.get(evidence, "checks") == [] -> {:error, "Evidence contains no selected checks."}
      true -> normalize_evidence_checks(Map.get(evidence, "checks"))
    end
  end

  defp final_checks(_evidence), do: {:error, "Evidence is missing or malformed."}

  defp normalize_evidence_checks(checks) do
    checks
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn check, {:ok, acc, ids} ->
      id = if is_map(check), do: Map.get(check, "id"), else: nil

      cond do
        not is_binary(id) or String.trim(id) == "" ->
          {:halt, {:error, "Evidence contains a malformed check."}}

        MapSet.member?(ids, id) ->
          {:halt, {:error, "Evidence contains duplicate check identities."}}

        Map.get(check, "status") != "completed" or not is_integer(Map.get(check, "exit_status")) ->
          {:halt, {:error, "A selected check is missing a completed result."}}

        not is_map(Map.get(check, "assertions")) ->
          {:halt, {:error, "A selected check has malformed assertions."}}

        true ->
          {:cont, {:ok, [check | acc], MapSet.put(ids, id)}}
      end
    end)
    |> case do
      {:ok, normalized, _ids} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = error -> error
    end
  end

  defp all_checks_passed(checks) do
    if Enum.all?(checks, &(Map.get(&1, "exit_status") === 0)) do
      :ok
    else
      {:error, "A selected check failed."}
    end
  end

  defp required_assertions_passed(checks, required) do
    checks_by_id = Map.new(checks, &{Map.get(&1, "id"), &1})

    Enum.reduce_while(required, :ok, fn assertion, :ok ->
      case Map.fetch(checks_by_id, assertion.check) do
        :error ->
          {:halt, {:error, "Required check #{inspect(assertion.check)} is missing from evidence."}}

        {:ok, check} ->
          actual = Map.get(check, "assertions")

          case Map.fetch(actual, assertion.assertion) do
            :error ->
              {:halt, {:error, "Required assertion #{inspect(assertion.assertion)} is missing from check #{inspect(assertion.check)}."}}

            {:ok, value} ->
              if value === assertion.equals do
                {:cont, :ok}
              else
                {:halt, {:error, "Required assertion #{inspect(assertion.assertion)} did not match in check #{inspect(assertion.check)}."}}
              end
          end
      end
    end)
  end

  defp gate_rationale(reason) when is_binary(reason), do: reason
  defp gate_rationale(_reason), do: "Required assertions are missing or malformed."

  defp sha256(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
end
