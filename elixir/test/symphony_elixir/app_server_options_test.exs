defmodule SymphonyElixir.AppServerOptionsTest do
  use SymphonyElixir.TestSupport

  @trace_env "SYMPHONY_APP_SERVER_OPTIONS_TRACE"

  test "per-session options control command, safety root, policies, model, effort and tools" do
    test_root = temp_root("overrides")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "LOCAL-1")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")

    File.mkdir_p!(workspace)
    write_fake_app_server!(codex_binary, "test-model", tool_call: true)
    set_trace_file!(trace_file)
    set_sensitive_env!("LINEAR_API_KEY", "test-linear-secret")
    set_sensitive_env!("OPENAI_API_KEY", "test-openai-secret")

    # The local workstream options are complete, so this invocation does not
    # need command, policy, workspace-root, or timeout values from WORKFLOW.md.
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(test_root, "different-configured-root"),
      codex_command: "this-command-must-not-run"
    )

    opts =
      session_options(workspace_root, workspace, codex_binary) ++
        [model: "test-model", reasoning_effort: "high"]

    issue = issue("LOCAL-1")

    assert {:ok, session} = AppServer.start_session(workspace, opts)

    try do
      assert session.requested_model == "test-model"
      assert session.effective_model == "test-model"
      assert session.dynamic_tools_enabled == false

      assert {:ok, result} = AppServer.run_turn(session, "Run a local check", issue)
      assert result.model == "test-model"
      assert result.reasoning_effort == "high"
    after
      AppServer.stop_session(session)
    end

    messages = trace_messages(trace_file)
    argv_line = trace_file |> File.read!() |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "ARGV:"))

    assert argv_line =~ "app-server"
    assert argv_line =~ "<--model> <command-model>"
    assert File.read!(trace_file) =~ "ENV:LINEAR_API_KEY=unset"
    assert File.read!(trace_file) =~ "ENV:OPENAI_API_KEY=unset"

    thread_start = Enum.find(messages, &(&1["method"] == "thread/start"))
    assert thread_start["params"]["model"] == "test-model"
    assert thread_start["params"]["cwd"] == workspace
    assert thread_start["params"]["dynamicTools"] == []
    assert thread_start["params"]["approvalPolicy"] == "never"
    assert thread_start["params"]["sandbox"] == "workspace-write"

    turn_start = Enum.find(messages, &(&1["method"] == "turn/start"))
    assert turn_start["params"]["effort"] == "high"

    assert turn_start["params"]["sandboxPolicy"] == %{
             "type" => "workspaceWrite",
             "writableRoots" => [workspace],
             "networkAccess" => false
           }

    tool_response = Enum.find(messages, &(&1["id"] == "disabled-tool"))
    assert tool_response["result"]["success"] == false
  end

  test "explicit workspace root still rejects outside paths before launching the command" do
    test_root = temp_root("workspace-root")
    workspace_root = Path.join(test_root, "allowed")
    outside_workspace = Path.join(test_root, "outside")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")

    File.mkdir_p!(workspace_root)
    File.mkdir_p!(outside_workspace)
    write_fake_app_server!(codex_binary, "test-model")
    set_trace_file!(trace_file)

    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
             AppServer.start_session(
               outside_workspace,
               session_options(workspace_root, outside_workspace, codex_binary)
             )

    refute File.exists?(trace_file)
  end

  test "session startup rejects a model different from the one returned by the app-server" do
    test_root = temp_root("model-mismatch")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "LOCAL-2")
    codex_binary = Path.join(test_root, "fake-codex")
    trace_file = Path.join(test_root, "codex.trace")

    File.mkdir_p!(workspace)
    write_fake_app_server!(codex_binary, "other-model")
    set_trace_file!(trace_file)

    assert {:error, {:codex_model_mismatch, "requested-model", "other-model"}} =
             AppServer.start_session(
               workspace,
               session_options(workspace_root, workspace, codex_binary) ++
                 [model: "requested-model"]
             )
  end

  defp session_options(workspace_root, workspace, codex_binary) do
    [
      workspace_root: workspace_root,
      command: "#{codex_binary} app-server --model command-model",
      runtime_settings: %{
        approval_policy: "never",
        thread_sandbox: "workspace-write",
        turn_sandbox_policy: %{
          "type" => "workspaceWrite",
          "writableRoots" => [workspace],
          "networkAccess" => false
        }
      },
      dynamic_tools: false,
      read_timeout_ms: 500,
      turn_timeout_ms: 2_000
    ]
  end

  defp write_fake_app_server!(path, returned_model, opts \\ []) do
    tool_call = Keyword.get(opts, :tool_call, false)

    tool_call_script =
      if tool_call do
        """
        printf '%s\\n' '{"method":"item/tool/call","id":"disabled-tool","params":{"tool":"linear_graphql","arguments":{}}}'
        """
      else
        ""
      end

    File.write!(path, """
    #!/bin/sh
    trace_file="$#{@trace_env}"
    printf 'ARGV:' >> "$trace_file"
    for arg in "$@"; do printf ' <%s>' "$arg" >> "$trace_file"; done
    printf '\\n' >> "$trace_file"
    printf 'ENV:LINEAR_API_KEY=%s\\n' "${LINEAR_API_KEY-unset}" >> "$trace_file"
    printf 'ENV:OPENAI_API_KEY=%s\\n' "${OPENAI_API_KEY-unset}" >> "$trace_file"
    while IFS= read -r line; do
      printf 'JSON:%s\\n' "$line" >> "$trace_file"
      case "$line" in
        *'"id":1'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"method":"initialized"'*) ;;
        *'"id":2'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-local"},"model":"#{returned_model}"}}' ;;
        *'"id":3'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-local"}}}'
          #{tool_call_script}
          ;;
        *'"id":"disabled-tool"'*) printf '%s\\n' '{"method":"turn/completed"}'; exit 0 ;;
      esac
    done
    """)

    File.chmod!(path, 0o755)
  end

  defp set_trace_file!(trace_file) do
    previous = System.get_env(@trace_env)
    System.put_env(@trace_env, trace_file)

    on_exit(fn -> restore_env(@trace_env, previous) end)
  end

  defp set_sensitive_env!(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)
    on_exit(fn -> restore_env(name, previous) end)
  end

  defp trace_messages(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "JSON:"))
    |> Enum.map(fn line -> line |> String.trim_leading("JSON:") |> Jason.decode!() end)
  end

  defp issue(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Local workstream check",
      description: "Run an isolated local validation.",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: []
    }
  end

  defp temp_root(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-app-server-options-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
