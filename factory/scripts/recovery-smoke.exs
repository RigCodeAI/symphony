# Controlled worker demo: no model, tracker, cloud, credentials, publication or merge.
for app <- [:yaml_elixir, :jason, :exqlite], do: {:ok, _} = Application.ensure_all_started(app)

defmodule RecoverySmoke do
  alias SymphonyElixir.{AgentRuntimeSupervisor, Orchestrator, WorkstreamRunner, WorkstreamStore}

  def run(root) do
    if File.exists?(root), do: raise("Use a new, disposable absolute directory")
    File.mkdir_p!(root)
    source = Path.expand("..", __DIR__)
    definitions = Path.join(root, "definitions")
    File.cp_r!(source, definitions)
    path = Path.join(definitions, "workstreams/local-recovery.yaml")
    db = Path.join(root, "state/runs.sqlite")
    opts = [name: SmokeRuntime, orchestrator_name: SmokeCoordinator, task_supervisor_name: SmokeTasks,
      workstream_store_path: db, auto_advance: false, stage_executor: &execute/4]
    {:ok, runtime} = AgentRuntimeSupervisor.start_link(opts)
    Process.unlink(runtime)
    run_opts = workspace(root, "pass")
    {:ok, id} = Orchestrator.queue_workstream(SmokeCoordinator, "pass/queue", "pass", path, %{"task" => "pass"}, run_opts)
    :ok = Orchestrator.step_workstreams(SmokeCoordinator)
    boundary = await(id, :ready, "validate")
    restart()
    ^boundary = await(id, :ready, "validate")
    :ok = Orchestrator.step_workstreams(SmokeCoordinator)
    await(id, :ready, "decision")
    :ok = Orchestrator.step_workstreams(SmokeCoordinator)
    waiting = await(id, :waiting_for_answer, "decision")
    File.write!(Path.join(definitions, "skills/local-rig/SKILL.md"), "Changed only for new runs")
    restart()
    ^waiting = await(id, :waiting_for_answer, "decision")
    {:ok, ^id} = Orchestrator.queue_workstream(SmokeCoordinator, "pass/queue", "pass", path, %{"task" => "pass"}, run_opts)
    [] = Task.Supervisor.children(SmokeTasks)
    File.write!(Path.join(root, "waiting.json"), Jason.encode!(waiting, pretty: true))

    # Demonstrate transactional migration failure against this actual durable run.
    store = :sys.get_state(SmokeCoordinator).workstreams.store
    monitor = Process.monitor(store)
    Supervisor.stop(runtime)
    receive do {:DOWN, ^monitor, :process, ^store, _} -> :ok after 2000 -> raise "store did not close" end
    {:error, {:migration_failed, 2, reason}} = WorkstreamStore.start_link(path: db, owner: self(), migrations: [
      {1, "SELECT 1"}, {2, "ALTER TABLE runs ADD COLUMN rollback_probe TEXT; INVALID SQL"}])
    File.write!(Path.join(root, "migration-error.txt"), inspect(reason))
    {:ok, runtime} = AgentRuntimeSupervisor.start_link(opts)
    Process.unlink(runtime)
    ^waiting = await(id, :waiting_for_answer, "decision")
    :ok = Orchestrator.answer_workstream(SmokeCoordinator, "pass/answer", id, waiting.pending_wait.id, %{"answer" => "continue"})
    :ok = Orchestrator.answer_workstream(SmokeCoordinator, "pass/answer", id, waiting.pending_wait.id, %{"answer" => "continue"})
    complete = await(id, :complete, :complete)
    "checked\n" = File.read!(Path.join(run_opts[:workspace], "checks.log"))

    {:ok, fail_id} = Orchestrator.queue_workstream(SmokeCoordinator, "fail/queue", "fail", path, %{"task" => "fail"}, workspace(root, "fail"))
    :ok = Orchestrator.step_workstreams(SmokeCoordinator)
    await(fail_id, :ready, "validate")
    :ok = Orchestrator.step_workstreams(SmokeCoordinator)
    failed = await(fail_id, :blocked, :blocked)
    false = failed.definitions == complete.definitions
    Supervisor.stop(runtime)
    report = %{status: "passed", controlled_workers: true, pass: complete, fail: failed,
      checks: ["stage-boundary restart", "pinned human-wait restart", "duplicate queue/answer",
        "one real executable side effect", "failed migration rollback", "changed files affect new runs", "failing gate blocks"]}
    File.write!(Path.join(root, "report.json"), Jason.encode!(report, pretty: true))
    IO.puts(Jason.encode!(%{status: report.status, database: db, report: Path.join(root, "report.json"), pass_run: id, fail_run: fail_id}, pretty: true))
  end

  def execute(%{type: :agent}, definition, run, _opts) do
    File.write!(Path.join(run.workspace, "candidate.txt"), run.outputs["task"])
    {:ok, %{"requested_model" => definition.agents["worker"].model, :workspace => run.workspace,
      :thread_id => "controlled-#{run.id}", :session_id => "controlled-smoke", :model => "controlled-worker-no-inference"}}
  end
  def execute(stage, definition, run, opts), do: WorkstreamRunner.execute_stage(stage, definition, run, opts)

  defp workspace(root, name) do
    path = Path.join([root, "workspaces", name])
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "--quiet", path])
    [workspace: path, workspace_root: Path.join(root, "workspaces")]
  end

  defp restart do
    old = Process.whereis(SmokeCoordinator)
    monitor = Process.monitor(old)
    Process.exit(old, :kill)
    receive do {:DOWN, ^monitor, :process, ^old, :killed} -> :ok after 2000 -> raise "coordinator did not stop" end
    until(fn -> pid = Process.whereis(SmokeCoordinator); pid && pid != old end)
  end

  defp await(id, status, stage), do: until(fn ->
    case Orchestrator.workstream_state(SmokeCoordinator, id) do
      {:ok, %{status: ^status, stage_id: ^stage} = report} -> report
      _ -> nil
    end
  end)
  defp until(fun, retries \\ 300)
  defp until(_fun, 0), do: raise("smoke state did not converge")
  defp until(fun, retries) do
    case fun.() do
      value when value not in [nil, false] -> value
      _ -> Process.sleep(10); until(fun, retries - 1)
    end
  catch
    :exit, _ -> Process.sleep(10); until(fun, retries - 1)
  end
end

case System.argv() do
  [root] ->
    if Path.type(root) != :absolute, do: raise("An absolute output directory is required")
    RecoverySmoke.run(root)
  _ -> raise("Usage: mix run --no-start ../factory/scripts/recovery-smoke.exs /tmp/new-recovery-smoke")
end
