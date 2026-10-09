defmodule SymphonyElixir.WorkstreamRunner do
  @moduledoc """
  Runs a validated local workstream synchronously. It does not schedule, persist,
  publish, merge, or consume tracker events.
  """

  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{PathSafety, Workstream, WorkstreamCommand}

  @source_root Path.expand("../../..", __DIR__)

  @spec run(Path.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, inputs, opts) do
    with :ok <- subscription_environment(),
         {:ok, definition} <- Workstream.load(path, inputs),
         {:ok, workspace} <- workspace(opts, definition),
         :ok <- dedicated_clone(workspace) do
      state = %{status: :running, workspace: workspace, attempts: [], repairs: %{}, outputs: inputs, definitions: Map.new(definition.definitions, fn {path, resource} -> {path, resource.sha256} end)}

      execute(definition.entry, definition, state, opts)
    end
  end

  defp workspace(opts, definition) do
    root = Keyword.fetch!(opts, :workspace_root)
    requested = Keyword.fetch!(opts, :workspace)

    with {:ok, root} <- PathSafety.canonicalize(root),
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
    started = System.monotonic_time(:millisecond)

    result =
      case stage.type do
        :agent -> run_agent(stage, definition, state, opts)
        :check -> WorkstreamCommand.run(stage.gate.command, state.workspace, stage.gate.timeout_ms, Map.take(state.outputs, stage.inputs))
      end

    attempt = %{stage: id, type: stage.type, duration_ms: System.monotonic_time(:millisecond) - started, result: result_evidence(result)}
    state = %{state | attempts: state.attempts ++ [attempt]}

    case {stage.type, result} do
      {:agent, {:ok, evidence}} ->
        execute(stage.next, definition, put_outputs(state, stage, evidence), opts)

      {:check, {:ok, %{exit_status: 0} = evidence}} ->
        execute(stage.gate.success, definition, put_outputs(state, stage, evidence), opts)

      {:check, _} ->
        repair_or_block(stage.gate.failure, id, definition, state, opts)

      {:agent, {:error, _}} ->
        finish(:blocked, definition, state)
    end
  end

  defp put_outputs(state, stage, evidence) do
    %{state | outputs: Enum.reduce(stage.outputs, state.outputs, &Map.put(&2, &1, evidence))}
  end

  defp finish(status, definition, state), do: {:ok, %{state | status: status, outputs: Map.drop(state.outputs, definition.inputs)}}

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
        turn_sandbox_policy: %{"type" => "workspaceWrite", "writableRoots" => [state.workspace], "networkAccess" => false}
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
