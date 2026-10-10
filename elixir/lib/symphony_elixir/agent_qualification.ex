defmodule SymphonyElixir.AgentQualification do
  @moduledoc """
  Runs one bounded, explicitly selected named-agent qualification on the current worker.
  Receipts report configuration separately from inference telemetry. They are investigation
  evidence, not trusted candidate-validation receipts or permission to enable dispatch.
  """

  alias SymphonyElixir.{AgentReadiness, Codex.AppServer, Workstream, WorkstreamRunner}

  @spec run(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(path, opts) do
    with {:ok, agent, definitions} <- Workstream.load_agent(path) do
      requested = AgentReadiness.requested(agent)
      marker = "QUALIFIED #{agent.name}: 42"
      resources = agent.instructions ++ agent.skills

      prompt =
        Enum.map_join(resources, "\n\n", & &1.text) <>
          "\n\nQualification only: compute 19 + 23 and reply exactly #{marker}. " <>
          "Do not run tools, change files, contact services, create agents, or publish anything."

      workspace = Keyword.fetch!(opts, :workspace)
      issue = %{id: "qualification", identifier: agent.name, title: "Bounded runtime qualification"}

      app_opts = [
        agent: agent,
        model: agent.model,
        reasoning_effort: agent.reasoning_effort,
        authentication_reference: opts[:authentication_reference],
        workspace_root: Keyword.fetch!(opts, :workspace_root),
        command: Keyword.get_lazy(opts, :codex_command, fn -> WorkstreamRunner.execution_context(opts).codex_command end),
        dynamic_tools: false,
        read_timeout_ms: 30_000,
        turn_timeout_ms: 90_000,
        runtime_settings: %{
          approval_policy: agent.approval_policy,
          thread_sandbox: agent.sandbox,
          turn_sandbox_policy: %{"type" => "workspaceWrite", "writableRoots" => [workspace], "networkAccess" => false}
        }
      ]

      started_at = DateTime.utc_now() |> DateTime.to_iso8601()
      result = AppServer.qualify(workspace, prompt, issue, app_opts)
      {status, blocker, observation} = qualification_outcome(result, agent, marker)

      {:ok,
       %{
         version: 1,
         agent: agent.name,
         agent_revision: agent.revision,
         definitions: Map.new(definitions, fn {file, ref} -> {file, ref.sha256} end),
         requested: requested,
         observation: observation,
         status: status,
         blocker: blocker,
         started_at: started_at,
         finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
         source_revision: opts[:source_revision],
         worker: opts[:worker],
         deployment_revision: opts[:deployment_revision],
         authentication_reference: opts[:authentication_reference],
         dispatch_ready: status == :qualified and AgentReadiness.dispatch(agent) == :ok
       }}
    end
  end

  defp qualification_outcome({:error, reason}, _agent, _marker),
    do: {:blocked, AppServer.qualification_error(reason), nil}

  defp qualification_outcome({:ok, observation}, agent, marker) do
    output_ok =
      Enum.any?(observation.observations, fn
        %{assistant_output: text} -> String.trim(text) == marker
        _ -> false
      end)

    cond do
      observation.turn.status != :completed -> {:blocked, observation.turn[:reason], observation}
      not output_ok -> {:blocked, "qualification_response_mismatch", observation}
      agent.daybreak -> {:blocked, "effective_daybreak_program_unobservable", observation}
      true -> {:qualified, nil, observation}
    end
  end
end
