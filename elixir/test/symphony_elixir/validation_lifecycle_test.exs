defmodule SymphonyElixir.ValidationLifecycleTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{AgentRuntimeSupervisor, Orchestrator, Validation, Workstream, WorkstreamRun, WorkstreamRunner}

  @image "python@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea"

  defp lifecycle_definition do
    %{
      name: "validation-lifecycle",
      inputs: ["task"],
      input_values: %{"task" => "fixture"},
      entry: "implement",
      agents: %{"worker" => %{model: "controlled", reasoning_effort: "medium", daybreak: false}},
      definitions: %{"fixture" => %{sha256: "pinned"}},
      stages: %{
        "implement" => %{id: "implement", type: :agent, outputs: ["candidate"], next: "validate"},
        "validate" => %{
          id: "validate",
          type: :check,
          outputs: ["validation"],
          gate: %{
            evaluator: :candidate_validation,
            required: [%{check: "check", assertion: "exit_status", equals: 0}],
            success: :complete,
            failure: %{repair: "implement", max_attempts: 3}
          }
        }
      }
    }
  end

  defp new_run do
    execution = %{
      workspace_root: System.tmp_dir!(),
      codex_command: "codex",
      validation_policy: nil,
      validation_archive: Path.join(System.tmp_dir!(), "unused-validation-archive"),
      validation_scratch: Path.join(System.tmp_dir!(), "unused-validation-scratch"),
      validation_base: nil
    }

    WorkstreamRun.new("task", lifecycle_definition(), System.tmp_dir!(), [], execution)
  end

  test "unverified candidate results fail closed and stop after three failed validation attempts" do
    forged = {:ok, %{gate: %{verdict: :passed}, exit_status: 0}}

    run =
      Enum.reduce(1..3, new_run(), fn round, run ->
        run = run |> WorkstreamRun.start_stage() |> WorkstreamRun.finish_stage({:ok, %{session_id: "agent-#{round}"}})
        run = WorkstreamRun.start_stage(run) |> WorkstreamRun.finish_stage(forged)

        assert List.last(run.attempts).gate == :failed
        assert List.last(run.attempts).gate_detail["verified"] == false
        assert run.validation_repair_rounds == round

        if round < 3 do
          assert run.status == :ready
          assert run.stage_id == "implement"
        else
          assert run.status == :blocked
        end

        run
      end)

    assert run.repairs == %{"validate" => 2}
    assert length(run.attempts) == 6
  end

  @tag :validation_docker
  test "a real signed receipt determines the durable gate and survives coordinator restart" do
    root = Path.join(System.tmp_dir!(), "validation-lifecycle-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "workspaces/candidate")
    File.mkdir_p!(workspace)
    git!(workspace, ["init", "--quiet"])
    git!(workspace, ["config", "user.email", "fixture@example.invalid"])
    git!(workspace, ["config", "user.name", "Fixture"])

    File.write!(
      Path.join(workspace, "check.py"),
      "print('{\"assertions\":{\"qualified\":true,\"detected\":false}}')\n"
    )

    git!(workspace, ["add", "."])
    git!(workspace, ["commit", "--quiet", "-m", "candidate"])
    base_sha = git!(workspace, ["rev-parse", "HEAD"])

    File.write!(Path.join(root, "instructions.md"), "Controlled fixture")

    File.write!(Path.join(root, "agent.yaml"), """
    version: 1
    name: unused
    model: gpt-6-luna
    reasoning_effort: medium
    daybreak: false
    approval_policy: never
    sandbox: workspace-write
    instructions: [instructions.md]
    skills: []
    """)

    definition_path = Path.join(root, "flow.yaml")
    File.write!(definition_path, workstream_source("qualified"))

    policy_path = Path.join(root, "policy.yaml")
    File.write!(policy_path, policy_source("assertions_v1", 5_000))

    context = %{
      root: root,
      workspace: workspace,
      definition_path: definition_path,
      policy_path: policy_path,
      database: Path.join(root, "state/runs.sqlite"),
      options: [
        workspace: workspace,
        workspace_root: Path.join(root, "workspaces"),
        validation_policy: policy_path,
        validation_archive: Path.join(root, "archive"),
        validation_scratch: Path.join(root, "scratch"),
        validation_base: base_sha
      ]
    }

    on_exit(fn -> File.rm_rf!(root) end)

    suffix = System.unique_integer([:positive])
    supervisor = Module.concat(__MODULE__, "Runtime#{suffix}")
    coordinator = Module.concat(__MODULE__, "Coordinator#{suffix}")
    tasks = Module.concat(__MODULE__, "Tasks#{suffix}")

    stage_executor = fn stage, definition, run, opts ->
      if stage.type == :agent do
        {:ok, %{session_id: "controlled-agent"}}
      else
        {:ok, result} = WorkstreamRunner.execute_stage(stage, definition, run, opts)
        # The coordinator must recompute the gate from the authenticated receipt.
        {:ok,
         result
         |> Map.put(:gate, %{verdict: :failed, rationale: ["untrusted worker metadata"], evidence_id: "forged"})
         |> Map.put(:opaque, self())}
      end
    end

    start_supervised!({AgentRuntimeSupervisor, name: supervisor, orchestrator_name: coordinator, task_supervisor_name: tasks, workstream_store_path: context.database, stage_executor: stage_executor})

    assert {:ok, run_id} =
             Orchestrator.queue_workstream(
               coordinator,
               "queue",
               "validation-task",
               context.definition_path,
               %{"task" => "fixture"},
               context.options
             )

    before_restart = await_state(coordinator, run_id, :waiting_for_answer)
    validation_report = Enum.find(before_restart.attempts, &(&1.stage == "validate"))
    assert validation_report.gate == :passed
    detail = validation_report.gate_detail
    assert detail["verdict"] == "passed"
    assert detail["evidence_id"] == validation_report.result.evidence["receipt"]["id"]
    assert detail["rationale"] != ["untrusted worker metadata"]
    assert validation_report.result.evidence["gate"]["verdict"] == "passed"
    refute Map.has_key?(validation_report.result.evidence, "opaque")
    assert before_restart.outputs["validation"]["gate"]["verdict"] == "passed"
    refute Map.has_key?(before_restart.outputs["validation"], "opaque")

    state_before_restart = :sys.get_state(coordinator)
    pinned_run = state_before_restart.workstreams.runs[run_id]
    pinned_digest = pinned_run.execution.validation_policy.digest
    validation_attempt = Enum.find(pinned_run.attempts, &(&1.type == :check))
    receipt = validation_report.result.evidence["receipt"]

    validation_context = %{
      task_id: pinned_run.task_id,
      run_id: pinned_run.id,
      attempt_id: validation_attempt.id,
      base_sha: pinned_run.execution.validation_base
    }

    validation_opts = [
      workspace: workspace,
      validation_archive: pinned_run.execution.validation_archive,
      validation_scratch: pinned_run.execution.validation_scratch
    ]

    assert {:ok, accepted_definition} = Workstream.load(context.definition_path, %{"task" => "fixture"})
    alternate_definition_path = Path.join(root, "alternate-flow.yaml")
    File.write!(alternate_definition_path, workstream_source("detected"))
    assert {:ok, rejected_definition} = Workstream.load(alternate_definition_path, %{"task" => "fixture"})

    assert {:ok, %{verdict: :passed}} =
             Validation.verify_result(
               {:ok, %{receipt: receipt}},
               pinned_run.execution.validation_policy,
               validation_context,
               accepted_definition.stages["validate"].gate.required,
               validation_opts
             )

    assert {:ok, %{verdict: :failed}} =
             Validation.verify_result(
               {:ok, %{receipt: receipt}},
               pinned_run.execution.validation_policy,
               validation_context,
               rejected_definition.stages["validate"].gate.required,
               validation_opts
             )

    File.write!(context.policy_path, "changed on disk after queue\n")

    restart_coordinator(coordinator)
    after_restart = await_state(coordinator, run_id, :waiting_for_answer)
    state_after_restart = :sys.get_state(coordinator)
    assert state_after_restart.workstreams.runs[run_id].execution.validation_policy.digest == pinned_digest
    assert after_restart == before_restart

    wait_id = after_restart.pending_wait.id
    assert :ok = Orchestrator.answer_workstream(coordinator, "answer", run_id, wait_id, %{"answer" => "yes"})
    assert {:ok, %{status: :complete}} = Orchestrator.workstream_state(coordinator, run_id)
  end

  defp await_state(coordinator, run_id, status, attempts \\ 300)
  defp await_state(_coordinator, _run_id, _status, 0), do: flunk("workstream did not reach the expected state")

  defp await_state(coordinator, run_id, status, attempts) do
    case Orchestrator.workstream_state(coordinator, run_id) do
      {:ok, %{status: ^status} = report} ->
        report

      _ ->
        Process.sleep(20)
        await_state(coordinator, run_id, status, attempts - 1)
    end
  end

  defp restart_coordinator(coordinator) do
    old = Process.whereis(coordinator)
    reference = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^reference, :process, ^old, :killed}

    await(fn ->
      case Process.whereis(coordinator) do
        pid when is_pid(pid) and pid != old ->
          try do
            if is_map(GenServer.call(pid, :snapshot)), do: pid
          catch
            :exit, _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp await(fun, attempts \\ 300)
  defp await(_fun, 0), do: flunk("coordinator did not restart")

  defp await(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(20)
        await(fun, attempts - 1)

      value ->
        value
    end
  end

  defp policy_source(format, timeout) do
    """
    version: 1
    revision: lifecycle-v1
    environment:
      image: #{@image}
      runner_version: docker-v1
    checks:
      - id: check
        adapter: command
        command: [python3, check.py]
        timeout_ms: #{timeout}
        paths: ['*']
        result_format: #{format}
    """
  end

  defp workstream_source(assertion) do
    """
    version: 1
    name: validation-lifecycle
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
        prompt: Prepare the existing candidate.
        next: validate
      - id: validate
        type: check
        inputs: [candidate]
        outputs: [validation]
        gate:
          evaluator: candidate_validation
          required:
            - check: check
              assertion: exit_status
              equals: 0
            - check: check
              assertion: #{assertion}
              equals: true
          success: question
          failure: blocked
      - id: question
        type: human_wait
        inputs: [validation]
        outputs: [answer]
        prompt: Continue?
        next: complete
    """
  end

  defp git!(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    String.trim(output)
  end
end
