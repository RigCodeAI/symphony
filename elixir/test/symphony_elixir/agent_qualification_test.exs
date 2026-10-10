defmodule SymphonyElixir.AgentQualificationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{AgentQualification, Workstream}

  test "named subscription qualification pins settings, strips credentials and records unknown telemetry" do
    {workspace, root, command, trace, agent_path} = fixture(false)
    previous = System.get_env("PRIVATE_INTEGRATION_TOKEN")
    System.put_env("PRIVATE_INTEGRATION_TOKEN", "must-not-reach-child")
    on_exit(fn -> if previous, do: System.put_env("PRIVATE_INTEGRATION_TOKEN", previous), else: System.delete_env("PRIVATE_INTEGRATION_TOKEN") end)

    assert {:ok, agent, _} = Workstream.load_agent(agent_path)
    opts = options(root, command, agent) ++ [secret_environment_names: ["PRIVATE_INTEGRATION_TOKEN"]]
    assert {:ok, session} = AppServer.start_session(workspace, opts)

    try do
      assert {:error, :agent_settings_override} = AppServer.run_turn(session, "test", issue(), reasoning_effort: "medium")
    after
      AppServer.stop_session(session)
    end

    assert File.read!(trace) =~ "ENV:unset"

    assert {:ok, receipt} =
             AgentQualification.run(agent_path, workspace: workspace, workspace_root: root, codex_command: command, authentication_reference: "test-subscription", source_revision: "test-source")

    assert receipt.status == :qualified
    assert receipt.agent_revision == agent.revision
    assert receipt.requested.cyber_access_program == "standard"
    assert receipt.observation.configured == %{model: "test-model", reasoning_effort: "high", daybreak: false}
    assert receipt.observation.effective == %{model: nil, reasoning_effort: nil, cyber_access_program: nil}
    messages = trace_messages(trace)
    thread = Enum.find(messages, &(&1["method"] == "thread/start"))
    turn = Enum.find(messages, &(&1["method"] == "turn/start"))
    assert thread["params"]["allowProviderModelFallback"] == false
    assert thread["params"]["config"]["model_reasoning_effort"] == "high"
    assert turn["params"]["model"] == "test-model"
    assert turn["params"]["effort"] == "high"
    assert turn["params"]["cyberAccessProgram"] == "standard"
  end

  test "Daybreak is rejected by dispatch, but a bounded probe cannot mistake a saved toggle for proof" do
    {workspace, root, command, trace, agent_path} = fixture(true)
    assert {:ok, agent, _} = Workstream.load_agent(agent_path)
    assert {:error, :daybreak_execution_unverified} = AppServer.start_session(workspace, options(root, command, agent))
    refute File.exists?(trace)
    assert {:ok, receipt} = AgentQualification.run(agent_path, workspace: workspace, workspace_root: root, codex_command: command, authentication_reference: "test-subscription")
    assert receipt.status == :blocked
    assert receipt.blocker == "effective_daybreak_program_unobservable"
    assert receipt.observation.turn.status == :completed
    refute receipt.dispatch_ready
    turn = Enum.find(trace_messages(trace), &(&1["method"] == "turn/start"))
    assert turn["params"]["cyberAccessProgram"] == "daybreakBlue"
  end

  test "authentication binding, definition requirement and exclusion names fail before launch" do
    {workspace, root, command, trace, agent_path} = fixture(false)
    assert {:ok, agent, _} = Workstream.load_agent(agent_path)
    opts = options(root, command, agent)

    assert {:error, :agent_authentication_reference_mismatch} =
             AppServer.start_session(workspace, Keyword.put(opts, :authentication_reference, "different"))

    assert {:error, :invalid_secret_environment_names} =
             AppServer.start_session(workspace, opts ++ [secret_environment_names: ["TOKEN; touch /tmp/unsafe"]])

    assert {:error, :qualification_agent_required} = AppServer.qualify(workspace, "test", issue(), Keyword.delete(opts, :agent))
    refute File.exists?(trace)
    assert AppServer.qualification_error({:response_error, %{"message" => "secret-value"}}) == "response_error"
  end

  test "unsupported access is rejected before a turn and its catalog is retained" do
    {workspace, root, command, trace, agent_path} = fixture(true)
    File.write!(command, File.read!(command) |> String.replace("[\"standard\",\"daybreakBlue\"]", "[\"standard\"]"))
    assert {:ok, receipt} = AgentQualification.run(agent_path,
      workspace: workspace, workspace_root: root, codex_command: command,
      authentication_reference: "test-subscription")
    assert receipt.status == :blocked
    assert receipt.blocker == "access_program_not_advertised"
    assert receipt.observation.runtime.models != []
    refute Enum.any?(trace_messages(trace), &(&1["method"] in ["thread/start", "turn/start"]))
  end

  test "reroutes and failed turns cannot pass qualification" do
    for notification <- [
      ~s({"method":"model/rerouted","params":{"fromModel":"test-model","toModel":"other-model","reason":"test"}}),
      ~s({"method":"turn/completed","params":{"turn":{"id":"test-turn","status":"failed","error":{"message":"secret-value"}}}})
    ] do
      {workspace, root, command, _trace, agent_path} = fixture(false)
      File.write!(command, File.read!(command) |> String.replace("'" <> ~s({"method":"turn/completed","params":{"turn":{"id":"test-turn","status":"completed"}}}) <> "'", "'" <> notification <> "'"))
      assert {:ok, receipt} = AgentQualification.run(agent_path,
        workspace: workspace, workspace_root: root, codex_command: command,
        authentication_reference: "test-subscription")
      assert receipt.status == :blocked
      refute Jason.encode!(receipt) =~ "secret-value"
    end
  end

  test "qualification's absolute turn deadline survives ongoing notifications" do
    {workspace, root, command, _trace, agent_path} = fixture(false)
    File.write!(command, File.read!(command) |> String.replace("printf '%s\\n' '{\"method\":\"item/completed\"", "for i in 1 2 3 4 5; do sleep 0.03; printf '%s\\n' '{\"method\":\"thread/status/changed\",\"params\":{}}'; done\n          printf '%s\\n' '{\"method\":\"item/completed\""))
    assert {:ok, agent, _} = Workstream.load_agent(agent_path)
    assert {:ok, session} = AppServer.start_session(workspace, Keyword.put(options(root, command, agent), :turn_timeout_ms, 50))
    try do
      assert {:error, :turn_timeout} = AppServer.run_turn(session, "test", issue(), absolute_turn_timeout: true)
    after
      AppServer.stop_session(session)
    end
  end

  defp options(root, command, agent) do
    [
      workspace_root: root,
      command: command,
      agent: agent,
      model: agent.model,
      reasoning_effort: agent.reasoning_effort,
      authentication_reference: "test-subscription",
      dynamic_tools: false,
      read_timeout_ms: 500,
      turn_timeout_ms: 2_000,
      runtime_settings: %{approval_policy: "never", thread_sandbox: "workspace-write", turn_sandbox_policy: %{"type" => "workspaceWrite", "writableRoots" => [root], "networkAccess" => false}}
    ]
  end

  defp fixture(daybreak) do
    root = Path.join(System.tmp_dir!(), "qualification-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    trace = Path.join(root, "trace")
    command = Path.join(root, "codex")
    File.write!(Path.join(root, "instruction.md"), "Return the requested marker.")
    File.write!(Path.join(root, "SKILL.md"), "Compute arithmetic.")
    agent_path = Path.join(root, "agent.yaml")

    File.write!(agent_path, """
    version: 1
    name: TestAgent
    model: test-model
    reasoning_effort: high
    daybreak: #{daybreak}
    approval_policy: never
    sandbox: workspace-write
    authentication: {mode: subscription, reference: test-subscription}
    instructions: [instruction.md]
    skills: [SKILL.md]
    """)

    File.write!(command, """
    #!/bin/sh
    printf 'ENV:%s\\n' "${PRIVATE_INTEGRATION_TOKEN-unset}" >> '#{trace}'
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> '#{trace}'
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{"userAgent":"fake"}}' ;;
        *'"method":"account/read"'*) printf '%s\\n' '{"id":101,"result":{"account":{"type":"chatgpt","planType":"test"}}}' ;;
        *'"method":"model/list"'*) printf '%s\\n' '{"id":102,"result":{"data":[{"id":"test-model","supportedReasoningEfforts":[{"reasoningEffort":"high"}],"availableAccessPrograms":{"cyber":["standard","daybreakBlue"]}}],"nextCursor":null}}' ;;
        *'"method":"account/rateLimits/read"'*) printf '%s\\n' '{"id":103,"result":{"ordinaryUsageAllowed":true}}' ;;
        *'"method":"config/read"'*) printf '%s\\n' '{"id":104,"result":{"config":{},"layers":[]}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"test-thread","daybreakEnabled":#{daybreak}},"model":"test-model","reasoningEffort":"high"}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"test-turn"}}}'
          printf '%s\\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"QUALIFIED TestAgent: 42"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"test-turn","status":"completed"}}}'
          ;;
      esac
    done
    """)

    File.chmod!(command, 0o700)
    {workspace, root, command, trace, agent_path}
  end

  defp trace_messages(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "JSON:"))
    |> Enum.map(fn line -> line |> String.trim_leading("JSON:") |> Jason.decode!() end)
  end

  defp issue, do: %{id: "test", identifier: "test", title: "Qualification"}
end
