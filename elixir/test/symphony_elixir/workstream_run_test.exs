defmodule SymphonyElixir.WorkstreamRunTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.WorkstreamRun

  defp definition(failure) do
    %{
      name: "smoke",
      inputs: ["task"],
      input_values: %{"task" => "smoke"},
      entry: "agent",
      agents: %{"worker" => %{model: "controlled", reasoning_effort: "medium", daybreak: false}},
      definitions: %{"fixture" => %{sha256: "pinned"}},
      stages: %{
        "agent" => %{id: "agent", type: :agent, outputs: ["candidate"], next: "check"},
        "check" => %{id: "check", type: :check, outputs: ["result"], gate: %{success: "wait", failure: failure}},
        "wait" => %{id: "wait", type: :human_wait, inputs: ["result"], outputs: ["answer"], prompt: "Continue?", next: :complete}
      }
    }
  end

  defp new(failure \\ :blocked), do: WorkstreamRun.new("task", definition(failure), System.tmp_dir!(), workspace_root: System.tmp_dir!(), codex_command: "pinned", branch: "cycle/test")

  defp to_check(run), do: run |> WorkstreamRun.start_stage() |> WorkstreamRun.finish_stage({:ok, %{session_id: "session", thread_id: "thread"}}) |> WorkstreamRun.start_stage()

  test "failed and malformed agent outcomes block instead of satisfying a gate" do
    for result <- [{:error, :broken}, :malformed, {:ok, "not evidence"}, {:ok, %{opaque: self()}}] do
      report = new() |> WorkstreamRun.start_stage() |> WorkstreamRun.finish_stage(result)
      assert report.status == :blocked
      assert List.last(report.attempts).result.status == :error
    end
  end

  test "checks fail closed on missing, timed-out and unknown evidence" do
    for result <- [{:ok, %{exit_status: 0}}, {:ok, %{exit_status: 0, timed_out: true}}, {:error, :timeout}, :malformed] do
      blocked = new() |> to_check() |> WorkstreamRun.finish_stage(result)
      assert blocked.status == :blocked
      assert List.last(blocked.attempts).gate == :failed
    end
  end

  test "repair budget is separate from transport retries and side-effect IDs survive transport retry" do
    run = new(%{repair: "agent", max_attempts: 1}) |> WorkstreamRun.start_stage()
    first = run.current_attempt_id
    run = WorkstreamRun.record_worker(run, %{pid: "pid", boot_id: "boot"})
    assert run.operations[first].worker.boot_id == "boot"
    run = run |> WorkstreamRun.uncertain(:unreachable) |> WorkstreamRun.retry_transport() |> WorkstreamRun.start_stage()
    assert run.transport_retries == 1
    assert run.operations[run.current_attempt_id].side_effect_id == first
    assert run.operations[run.current_attempt_id].transport_retries == 1
    run = run |> WorkstreamRun.finish_stage({:ok, %{}}) |> WorkstreamRun.start_stage() |> WorkstreamRun.finish_stage({:ok, %{exit_status: 1, timed_out: false}})
    assert run.repairs == %{"check" => 1}
    run = run |> to_check() |> WorkstreamRun.finish_stage({:ok, %{exit_status: 1, timed_out: false}})
    assert run.status == :blocked
    assert run.repairs == %{"check" => 1}
  end

  test "human wait accepts only JSON outputs bound to the current wait" do
    run = new() |> to_check() |> WorkstreamRun.finish_stage({:ok, %{exit_status: 0, timed_out: false}}) |> WorkstreamRun.start_stage()
    wait = run.pending_wait
    assert {:error, :stale_or_missing_human_wait} = WorkstreamRun.wait_answer(run, "stale", %{"answer" => true})
    assert {:error, :stale_or_missing_human_wait} = WorkstreamRun.wait_answer(run, wait.id, "text")
    assert {:error, :invalid_human_wait_outputs} = WorkstreamRun.wait_answer(run, wait.id, %{"answer" => nil})
    assert {:error, :invalid_human_wait_outputs} = WorkstreamRun.wait_answer(run, wait.id, %{"answer" => self()})
    assert {:ok, completed} = WorkstreamRun.wait_answer(run, wait.id, %{"answer" => true})
    assert completed.status == :complete
    assert completed.pending_wait == nil
    assert completed.outputs["answer"] == true
    assert List.last(completed.attempts).result.evidence.artifact_ids == wait.artifact_ids
    assert WorkstreamRun.compatible_policy?(completed)
    refute WorkstreamRun.compatible_policy?(%{completed | policy: %{}})
    report = WorkstreamRun.report(completed)
    refute Map.has_key?(report.outputs, "task")
    refute Map.has_key?(report, :execution)
    assert report.definitions == %{"fixture" => "pinned"}
  end
end
