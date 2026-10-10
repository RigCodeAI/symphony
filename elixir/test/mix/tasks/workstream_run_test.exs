defmodule Mix.Tasks.Workstream.RunTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Mix.Tasks.Workstream.Run

  setup do
    root = Path.join(System.tmp_dir!(), "workstream-cli-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/rig")
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("git", ["init", "--quiet", workspace])
    File.write!(Path.join(root, "inputs.json"), Jason.encode!(%{"task" => "local test"}))
    File.write!(Path.join(root, "SKILL.md"), "Shared local instructions")

    File.write!(Path.join(root, "agent.yaml"), """
    version: 1
    name: local
    model: test-model
    reasoning_effort: medium
    daybreak: false
    approval_policy: never
    sandbox: workspace-write
    instructions: [SKILL.md]
    skills: [SKILL.md]
    """)

    write_definition(root, "true")
    fake = Path.join(root, "fake-codex")

    File.write!(fake, """
    #!/bin/sh
    while IFS= read -r line; do
      case "$line" in
        *'"method":"initialize"'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"account/read"'*) printf '%s\\n' '{"id":101,"result":{"account":{"type":"chatgpt"}}}' ;;
        *'"method":"model/list"'*) printf '%s\\n' '{"id":102,"result":{"data":[{"id":"test-model","supportedReasoningEfforts":[{"reasoningEffort":"medium"}],"availableAccessPrograms":{"cyber":["standard"]}}],"nextCursor":null}}' ;;
        *'"method":"account/rateLimits/read"'*) printf '%s\\n' '{"id":103,"result":{"ordinaryUsageAllowed":true}}' ;;
        *'"method":"config/read"'*) printf '%s\\n' '{"id":104,"result":{"config":{},"layers":[]}}' ;;
        *'"method":"thread/start"'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"local-thread","daybreakEnabled":false},"model":"test-model","reasoningEffort":"medium"}}' ;;
        *'"method":"turn/start"'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"local-turn"}}}'
          printf '%s\\n' '{"method":"turn/completed","params":{"turn":{"id":"local-turn","status":"completed"}}}'
          ;;
      esac
    done
    """)

    File.chmod!(fake, 0o755)
    level = Logger.level()

    on_exit(fn ->
      File.rm_rf!(root)
      Logger.configure(level: level)
    end)

    %{root: root, workspace: workspace, fake: fake}
  end

  defp write_definition(root, executable) do
    File.write!(Path.join(root, "stream.yaml"), """
    version: 1
    name: local-cli
    inputs: [task]
    agents: {worker: agent.yaml}
    entry: implement
    stages:
      - id: implement
        type: agent
        inputs: [task]
        outputs: [candidate]
        agent: worker
        prompt: Do the local task.
        next: check
      - id: check
        type: check
        inputs: [candidate]
        outputs: [result]
        gate:
          command: [#{Jason.encode!(executable)}]
          timeout_ms: 1000
          success: complete
          failure: blocked
    """)
  end

  defp arguments(context), do: [Path.join(context.root, "stream.yaml"), "--inputs", Path.join(context.root, "inputs.json")]
  defp execution_arguments(context), do: arguments(context) ++ ["--workspace", context.workspace, "--workspace-root", Path.dirname(context.workspace), "--codex-command", context.fake]

  test "validation prints a valid report without executing", context do
    output = capture_io(fn -> Run.run(arguments(context) ++ ["--validate-only"]) end)
    assert Jason.decode!(output)["status"] == "valid"
  end

  test "execution serializes evidence and complete status", context do
    output = capture_io(fn -> Run.run(execution_arguments(context)) end)
    report = Jason.decode!(output)
    assert report["status"] == "complete"
    assert report["outputs"]["result"]["exit_status"] == 0
  end

  test "failed check prints evidence before returning an error", context do
    write_definition(context.root, "false")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/Workstream blocked/, fn -> Run.run(execution_arguments(context)) end
      end)

    report = Jason.decode!(output)
    assert report["status"] == "blocked"
    assert List.last(report["attempts"])["result"]["evidence"]["exit_status"] == 1
  end

  test "bad arguments and input files return usage errors", context do
    for args <- [[], ["--unknown"], ["missing", "--inputs", "missing"], ["missing"]] do
      assert_raise Mix.Error, ~r/Usage:/, fn -> Run.run(args) end
    end

    File.write!(Path.join(context.root, "inputs.json"), "invalid-json")
    assert_raise Mix.Error, ~r/Usage:/, fn -> Run.run(arguments(context)) end
    File.write!(Path.join(context.root, "inputs.json"), "[]")
    assert_raise Mix.Error, ~r/Usage:/, fn -> Run.run(arguments(context)) end
  end

  test "missing execution paths and invalid definitions reject", context do
    assert_raise Mix.Error, ~r/Execution requires/, fn -> Run.run(arguments(context)) end
    File.write!(Path.join(context.root, "stream.yaml"), "version: 99")
    assert_raise Mix.Error, ~r/Workstream rejected:/, fn -> Run.run(arguments(context) ++ ["--validate-only"]) end
    assert_raise Mix.Error, ~r/Workstream rejected:/, fn -> Run.run(execution_arguments(context)) end
  end
end
