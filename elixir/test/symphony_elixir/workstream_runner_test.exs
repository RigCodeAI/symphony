defmodule SymphonyElixir.WorkstreamRunnerTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.{WorkstreamCommand, WorkstreamRunner}

  setup do
    root = Path.join(System.tmp_dir!(), "workstream-runner-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/rig")
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("git", ["init", "--quiet", workspace])
    File.write!(Path.join(root, "SKILL.md"), "Shared procedure")
    File.write!(Path.join(root, "instructions.md"), "Only edit this clone")

    File.write!(Path.join(root, "agent.yaml"), """
    version: 1
    name: local
    model: gpt-6-luna
    reasoning_effort: medium
    daybreak: false
    approval_policy: never
    sandbox: workspace-write
    instructions: [instructions.md]
    skills: [SKILL.md]
    """)

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace}
  end

  defp definition(context, command, failure \\ "blocked") do
    path = Path.join(context.root, "workstream.yaml")

    File.write!(path, """
    version: 1
    name: smoke
    inputs: [task]
    agents:
      worker: agent.yaml
    entry: implement
    stages:
      - id: implement
        type: agent
        inputs: [task]
        outputs: [candidate]
        agent: worker
        prompt: Add the requested regression.
        next: validate
      - id: validate
        type: check
        inputs: [candidate]
        outputs: [check]
        gate:
          command: #{Jason.encode!(command)}
          timeout_ms: 1000
          success: complete
          failure: #{failure}
    """)

    path
  end

  defp options(context, agent) do
    [workspace: context.workspace, workspace_root: Path.join(context.root, "workspaces"), agent_executor: agent]
  end

  test "real executable gate advances after an observable agent change", context do
    agent = fn workspace, prompt, issue, opts ->
      assert prompt =~ "Shared procedure"
      assert prompt =~ "Only edit this clone"
      assert prompt =~ "regression"
      assert issue.identifier == "smoke"
      assert opts[:model] == "gpt-6-luna"
      assert opts[:dynamic_tools] == false
      File.write!(Path.join(workspace, "candidate.txt"), "regression")
      {:ok, %{session_id: "thread-turn", raw: "not retained"}}
    end

    path = definition(context, ["sh", "-c", "test -f candidate.txt && printf 'real check passed'"])
    assert {:ok, report} = WorkstreamRunner.run(path, %{"task" => "regression"}, options(context, agent))
    assert report.status == :complete
    assert length(report.attempts) == 2
    assert report.outputs["candidate"] == %{session_id: "thread-turn", workspace: context.workspace}
    assert report.outputs["check"].output == "real check passed"
    assert map_size(report.definitions) == 4
  end

  test "failing gate blocks and retains readable output", context do
    path = definition(context, ["sh", "-c", "echo assertion failed; exit 7"])
    agent = fn _, _, _, _ -> {:ok, %{}} end
    assert {:ok, report} = WorkstreamRunner.run(path, %{"task" => "x"}, options(context, agent))
    assert report.status == :blocked
    assert List.last(report.attempts).result == %{status: :ok, evidence: %{exit_status: 7, output: "assertion failed\n", truncated: false, timed_out: false}}
    refute Map.has_key?(report.outputs, "check")
  end

  test "repair cycles stop at the declared budget", context do
    path = definition(context, ["false"], "{repair: implement, max_attempts: 2}")
    agent = fn _, _, _, _ -> {:ok, %{}} end
    assert {:ok, report} = WorkstreamRunner.run(path, %{"task" => "x"}, options(context, agent))
    assert report.status == :blocked
    assert report.repairs == %{"validate" => 2}
    assert length(report.attempts) == 6
  end

  test "agent failure stops before executing the check", context do
    path = definition(context, ["touch", "unexpected"])
    agent = fn _, _, _, _ -> {:error, {:raw, "secret"}} end
    assert {:ok, report} = WorkstreamRunner.run(path, %{"task" => "x"}, options(context, agent))
    assert report.status == :blocked
    assert length(report.attempts) == 1
    refute File.exists?(Path.join(context.workspace, "unexpected"))
    refute inspect(report) =~ "secret"
  end

  test "unsafe or missing clone paths reject before dispatch", context do
    path = definition(context, ["true"])
    agent = fn _, _, _, _ -> flunk("must not dispatch") end
    opts = options(context, agent)
    assert {:error, :workspace_equals_root} = WorkstreamRunner.run(path, %{"task" => "x"}, Keyword.put(opts, :workspace_root, context.workspace))
    assert {:error, :workspace_outside_root} = WorkstreamRunner.run(path, %{"task" => "x"}, Keyword.put(opts, :workspace, context.root))
    assert {:error, :workspace_missing} = WorkstreamRunner.run(path, %{"task" => "x"}, Keyword.put(opts, :workspace, context.workspace <> "-absent"))
    File.rm_rf!(Path.join(context.workspace, ".git"))
    assert {:error, :workspace_requires_dedicated_clone} = WorkstreamRunner.run(path, %{"task" => "x"}, opts)
  end

  test "symlink escape and configuration overlap reject before dispatch", context do
    path = definition(context, ["true"])
    agent = fn _, _, _, _ -> flunk("must not dispatch") end
    opts = options(context, agent)
    File.ln_s!(context.root, context.workspace <> "-link")
    assert {:error, :workspace_outside_root} = WorkstreamRunner.run(path, %{"task" => "x"}, Keyword.put(opts, :workspace, context.workspace <> "-link"))
    assert {:error, :workspace_overlaps_source_or_definitions} = WorkstreamRunner.run(path, %{"task" => "x"}, workspace: context.root, workspace_root: Path.dirname(context.root))
  end

  test "GNU timeout terminates a running check and output is bounded", context do
    assert {:ok, %{timed_out: true, exit_status: 124}} = WorkstreamCommand.run(["sleep", "2"], context.workspace, 20)
    assert {:ok, result} = WorkstreamCommand.run(["sh", "-c", "yes x | head -c 70000"], context.workspace, 1000)
    assert result.truncated
    assert byte_size(result.output) == 65_536
    assert {:error, :gate_executable_or_gnu_timeout_missing} = WorkstreamCommand.run(["nonexistent-workstream-gate"], context.workspace, 1000)
  end

  test "check process does not inherit credentials and common token strings are redacted", context do
    assert {:ok, result} = WorkstreamCommand.run(["sh", "-c", "printf '%s' \"${OPENAI_API_KEY-unset} ghp_abcdefghijklmnop\""], context.workspace, 1000)
    assert result.output == "unset [REDACTED]"
  end

  test "declared input metadata reaches the executable as JSON", context do
    assert {:ok, result} = WorkstreamCommand.run(["sh", "-c", "printf '%s' \"$WORKSTREAM_INPUTS_JSON\""], context.workspace, 1000, %{"candidate" => %{"session_id" => "thread-turn"}})
    assert Jason.decode!(result.output) == %{"candidate" => %{"session_id" => "thread-turn"}}
  end

  test "children left by an exited gate are stopped before returning", context do
    assert {:ok, %{exit_status: 0}} = WorkstreamCommand.run(["sh", "-c", "(sleep 0.2; touch orphan) >/dev/null 2>&1 &"], context.workspace, 1000)
    Process.sleep(300)
    refute File.exists?(Path.join(context.workspace, "orphan"))
  end

  test "invalid bytes and a truncated Unicode sequence still produce JSON evidence", context do
    assert {:ok, result} = WorkstreamCommand.run(["sh", "-c", "printf '\\377\\342\\202'"], context.workspace, 1000)
    assert Jason.decode!(Jason.encode!(result))["output"] == "��"
  end

  test "an executable path is resolved from the dedicated workspace", context do
    executable = Path.join(context.workspace, "check.sh")
    File.write!(executable, "#!/bin/sh\nprintf 'workspace check'")
    File.chmod!(executable, 0o700)
    assert {:ok, %{exit_status: 0, output: "workspace check"}} = WorkstreamCommand.run(["./check.sh"], context.workspace, 1000)
  end

  test "Unicode replacement and redaction expansion retain the final output cap", context do
    commands = ["head -c 65536 /dev/zero | tr '\\000' '\\377'", "yes sk-a | head -c 40000"]

    for command <- commands do
      assert {:ok, result} = WorkstreamCommand.run(["sh", "-c", command], context.workspace, 1000)
      assert result.truncated
      assert byte_size(result.output) <= 65_536
      assert String.valid?(result.output)
      assert Jason.encode!(result)
    end
  end
end
