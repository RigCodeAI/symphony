defmodule SymphonyElixir.WorkstreamRunner do
  @moduledoc """
  Prepares and executes stages from a validated local workstream.

  `run/3` remains a synchronous convenience runner. It stops at a human wait and
  reports the question for a coordinator to persist and deliver. `prepare/3` and
  `execute_stage/4` expose the same validation, workspace safety, and stage execution
  for a durable coordinator. This module does not schedule, persist, publish, or merge.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{PathSafety, Workstream, WorkstreamCommand}

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

  @doc """
  Loads and validates a workstream, then verifies and returns its canonical workspace.
  """
  @spec prepare(Path.t(), map(), keyword()) ::
          {:ok, Workstream.loaded_workstream(), Path.t()} | {:error, term()}
  def prepare(path, inputs, opts) do
    with :ok <- subscription_environment(),
         {:ok, definition} <- Workstream.load(path, inputs),
         {:ok, workspace} <- workspace(opts, definition),
         :ok <- dedicated_clone(workspace) do
      {:ok, definition, workspace}
    end
  end

  @doc """
  Runs a validated local workstream synchronously until it completes, blocks, or reaches
  a human wait. A wait returns `status: :waiting_for_answer` with its prompt and resolved inputs.
  """
  @spec run(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, inputs, opts) do
    with {:ok, definition, workspace} <- prepare(path, inputs, opts) do
      state = %{
        status: :running,
        workspace: workspace,
        attempts: [],
        repairs: %{},
        outputs: inputs,
        definitions: Map.new(definition.definitions, fn {path, resource} -> {path, resource.sha256} end)
      }

      execute(definition.entry, definition, state, opts)
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
      WorkstreamCommand.run(
        stage.gate.command,
        workspace,
        stage.gate.timeout_ms,
        Map.take(state.outputs, stage.inputs)
      )
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

  defp pinned_workspace(workspace, canonical_workspace) when workspace == canonical_workspace, do: :ok
  defp pinned_workspace(_workspace, _canonical_workspace), do: {:error, :workspace_path_changed}

  defp stage_workspace(state, definition, opts) do
    with {:ok, workspace_root} <- workspace_option(opts, :workspace_root) do
      validate_workspace(state.workspace, workspace_root, definition)
    end
  end

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
    result = execute_stage(stage, definition, state, opts)

    attempt = %{
      stage: stage.id,
      type: stage.type,
      duration_ms: System.monotonic_time(:millisecond) - started,
      result: result_evidence(result)
    }

    state = %{state | attempts: state.attempts ++ [attempt]}

    case {stage.type, result} do
      {:agent, {:ok, evidence}} ->
        execute(stage.next, definition, put_outputs(state, stage, evidence), opts)

      {:check, {:ok, %{exit_status: 0} = evidence}} ->
        execute(stage.gate.success, definition, put_outputs(state, stage, evidence), opts)

      {:check, _} ->
        repair_or_block(stage.gate.failure, stage.id, definition, state, opts)

      {:agent, {:error, _}} ->
        finish(:blocked, definition, state)
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
      %{type: :check, result: result} -> "\nGate failure triggering repair:\n#{Jason.encode!(result)}"
      _ -> ""
    end
  end

  defp default_codex_command do
    path = "'" <> String.replace(System.get_env("PATH", ""), "'", "'\\''") <> "'"
    "env PATH=#{path} codex --disable apps --disable plugins --disable multi_agent -c 'forced_login_method=\"chatgpt\"' app-server"
  end
end
