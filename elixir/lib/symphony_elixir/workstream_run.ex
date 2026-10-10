defmodule SymphonyElixir.WorkstreamRun do
  @moduledoc """
  Durable local workstream transitions. The orchestrator alone commits transitions;
  workers execute one pinned stage and cannot choose the next stage or gate outcome.
  """

  @policy_digest :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower)

  for source <- ~w(workstream_runner.ex worker_operation.ex workstream_cancellation.ex agent_runner.ex ssh.ex codex/app_server.ex) do
    @external_resource Path.join(__DIR__, source)
  end

  @executor_digest ~w(workstream_runner.ex worker_operation.ex workstream_cancellation.ex agent_runner.ex ssh.ex codex/app_server.ex)
                   |> Enum.map(&File.read!(Path.join(__DIR__, &1)))
                   |> IO.iodata_to_binary()
                   |> then(&:crypto.hash(:sha256, &1))
                   |> Base.encode16(case: :lower)

  @external_resource Path.join(__DIR__, "validation.ex")
  @external_resource Path.join(__DIR__, "validation_policy.ex")
  @external_resource Path.join(__DIR__, "validation_command.ex")
  @external_resource Path.join(__DIR__, "candidate_git.ex")
  @external_resource Path.join(__DIR__, "workstream.ex")
  @validation_digest ["validation.ex", "validation_policy.ex", "validation_command.ex", "candidate_git.ex", "workstream.ex"]
                     |> Enum.map(&File.read!(Path.join(__DIR__, &1)))
                     |> IO.iodata_to_binary()
                     |> then(fn source -> :crypto.hash(:sha256, source) end)
                     |> Base.encode16(case: :lower)

  @spec policy() :: map()
  def policy,
    do: %{
      lifecycle_sha256: @policy_digest,
      executor_sha256: @executor_digest,
      validation_sha256: @validation_digest,
      gate_policy: "exit-status-v1",
      version: 1
    }

  @spec compatible_policy?(map()) :: boolean()
  def compatible_policy?(run), do: run.policy == policy()

  @spec new(String.t(), map(), Path.t(), keyword()) :: map()
  def new(task_id, definition, workspace, opts) do
    execution = SymphonyElixir.WorkstreamRunner.execution_context(opts)
    execution = Map.merge(execution, Map.get(definition, :pinned_validation_context, %{}))
    new(task_id, definition, workspace, opts, execution)
  end

  @spec new(String.t(), map(), Path.t(), keyword(), map()) :: map()
  def new(task_id, definition, workspace, opts, execution_context) do
    definition = Map.delete(definition, :pinned_validation_context)

    %{
      id: "run-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
      task_id: task_id,
      issue_id: Keyword.get(opts, :issue_id),
      branch: Keyword.get_lazy(opts, :branch, fn -> workspace_branch(workspace) end),
      session_id: nil,
      thread_id: nil,
      workspace: workspace,
      definition: definition,
      policy: policy(),
      execution: execution_context,
      status: :ready,
      phase: :queued,
      stage_id: definition.entry,
      current_attempt_id: nil,
      outputs: definition.input_values,
      artifacts: %{},
      attempts: [],
      operations: %{},
      repairs: %{},
      validation_repair_rounds: 0,
      review_repair_rounds: 0,
      transport_retries: 0,
      retry_operation_id: nil,
      pending_wait: nil,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @spec start_stage(map()) :: map()
  def start_stage(%{status: :ready} = run) do
    stage = Map.fetch!(run.definition.stages, run.stage_id)
    ordinal = length(run.attempts) + 1
    id = "#{run.id}/#{stage.id}/#{ordinal}"

    attempt = %{
      id: id,
      stage: stage.id,
      type: stage.type,
      ordinal: ordinal,
      status: :executing,
      result: nil,
      gate: nil,
      gate_detail: nil
    }

    if stage.type == :human_wait do
      wait = %{id: id <> "/wait", prompt: stage.prompt, inputs: Map.take(run.outputs, stage.inputs), artifact_ids: Map.take(run.artifacts, stage.inputs)}
      %{run | status: :waiting_for_answer, phase: :waiting_for_answer, current_attempt_id: id, attempts: run.attempts ++ [%{attempt | status: :waiting}], pending_wait: wait}
    else
      previous = run.operations[run.retry_operation_id]

      operation = %{
        id: id,
        attempt_id: id,
        stage: stage.id,
        type: stage.type,
        status: :executing,
        worker: nil,
        side_effect_id: if(previous, do: previous.side_effect_id, else: id),
        transport_retries: if(previous, do: previous.transport_retries, else: 0)
      }

      %{
        run
        | status: :executing,
          phase: if(stage.type == :agent, do: :implementing, else: :validating),
          current_attempt_id: id,
          attempts: run.attempts ++ [attempt],
          operations: Map.put(run.operations, id, operation),
          retry_operation_id: nil
      }
    end
  end

  @spec record_worker(map(), map()) :: map()
  def record_worker(run, identity) do
    update_in(run.operations[run.current_attempt_id].worker, fn _ -> identity end)
  end

  @spec finish_stage(map(), term()) :: map()
  def finish_stage(%{status: status} = run, result) when status in [:executing, :reconciling] do
    stage = Map.fetch!(run.definition.stages, run.stage_id)
    {result, gate, gate_detail} = finish_gate(run, stage, result)
    result = json_stage_result(result)
    evidence = result_evidence(result)
    gate = if stage.type == :check and is_nil(gate), do: if(passing_check?(result), do: :passed, else: :failed), else: gate
    run = update_attempt(run, %{status: :completed, result: evidence, gate: gate, gate_detail: gate_detail})
    run = put_in(run.operations[run.current_attempt_id].status, :completed)

    case {stage.type, result} do
      {:agent, {:ok, value}} when is_map(value) ->
        run |> put_outputs(stage, value) |> put_session(value) |> advance(stage.next)

      {:check, _} ->
        if gate == :passed do
          {:ok, value} = result
          run |> put_outputs(stage, value) |> advance(stage.gate.success)
        else
          if candidate_validation?(stage) do
            candidate_validation_failure(run, stage)
          else
            repair_or_block(run, stage)
          end
        end

      _ ->
        advance(run, :blocked)
    end
  end

  @spec wait_answer(map(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def wait_answer(%{status: :waiting_for_answer, pending_wait: %{id: id}} = run, id, reply) when is_map(reply) do
    stage = Map.fetch!(run.definition.stages, run.stage_id)

    case Jason.encode(reply) do
      {:ok, encoded} ->
        if Enum.sort(Map.keys(reply)) == Enum.sort(stage.outputs) and Jason.decode!(encoded) == reply and Enum.all?(reply, fn {_key, value} -> not is_nil(value) end) do
          evidence = %{reply: reply, wait_id: id, artifact_ids: run.pending_wait.artifact_ids}
          run = update_attempt(run, %{status: :completed, result: %{status: :ok, evidence: evidence}})
          run = Enum.reduce(reply, run, fn {key, value}, acc -> put_outputs(acc, %{outputs: [key]}, value) end)
          {:ok, run |> Map.put(:pending_wait, nil) |> advance(stage.next)}
        else
          {:error, :invalid_human_wait_outputs}
        end

      {:error, _} ->
        {:error, :invalid_human_wait_outputs}
    end
  end

  def wait_answer(_run, _id, _reply), do: {:error, :stale_or_missing_human_wait}

  @spec uncertain(map(), term()) :: map()
  def uncertain(run, reason) do
    %{run | status: :reconciling, phase: :reconciling}
    |> put_in([:operations, run.current_attempt_id, :reconciliation], inspect(reason))
  end

  @doc "Records a trusted termination for the stopped run's current operation."
  @spec confirm_termination(map()) :: map()
  def confirm_termination(%{status: :stopped, current_attempt_id: attempt_id} = run) when is_binary(attempt_id) do
    case Map.get(run.operations, attempt_id) do
      %{status: status} = operation when status in [:executing, :canceled] ->
        attempts = Enum.map(run.attempts, &confirm_canceled_attempt(&1, attempt_id))

        operation_cancellation =
          operation
          |> Map.get(:cancellation)
          |> cancellation_map()
          |> Map.put(:termination, :terminated)

        operation =
          operation
          |> Map.put(:status, :canceled)
          |> Map.delete(:reconciliation)
          |> Map.put(:cancellation, operation_cancellation)

        cancellation =
          run
          |> Map.get(:cancellation)
          |> cancellation_map()
          |> Map.put(:termination, :terminated)

        run
        |> Map.put(:attempts, attempts)
        |> Map.put(:operations, Map.put(run.operations, attempt_id, operation))
        |> Map.put(:cancellation, cancellation)

      _ ->
        run
    end
  end

  def confirm_termination(run), do: run

  defp confirm_canceled_attempt(%{id: id, status: status} = attempt, attempt_id)
       when id == attempt_id and status in [:executing, :canceled],
       do: Map.put(attempt, :status, :canceled)

  defp confirm_canceled_attempt(attempt, _attempt_id), do: attempt

  defp cancellation_map(value) when is_map(value), do: value
  defp cancellation_map(_value), do: %{}

  @spec retry_transport(map()) :: map()
  def retry_transport(run) do
    run = update_attempt(run, %{status: :interrupted})
    run = update_in(run.operations[run.current_attempt_id], fn operation -> %{operation | status: :not_applied, transport_retries: operation.transport_retries + 1} end)
    %{run | status: :ready, phase: :queued, transport_retries: run.transport_retries + 1, retry_operation_id: run.current_attempt_id}
  end

  @spec report(map()) :: map()
  def report(run) do
    run
    |> Map.drop([:definition, :execution])
    |> Map.put(:outputs, Map.drop(run.outputs, run.definition.inputs))
    |> Map.put(:definitions, Map.new(run.definition.definitions, fn {path, resource} -> {path, resource.sha256} end))
    |> Map.put(:agents, Map.new(run.definition.agents, fn {name, agent} -> {name, Map.take(agent, [:model, :reasoning_effort, :daybreak])} end))
  end

  defp workspace_branch(workspace) do
    case SymphonyElixir.CandidateGit.run(workspace, ["symbolic-ref", "--quiet", "--short", "HEAD"]) do
      {:ok, branch} -> String.trim(branch)
      _ -> nil
    end
  end

  defp update_attempt(run, changes) do
    %{run | attempts: Enum.map(run.attempts, fn attempt -> if attempt.id == run.current_attempt_id, do: Map.merge(attempt, changes), else: attempt end)}
  end

  defp finish_gate(run, %{type: :check} = stage, result) do
    if candidate_validation?(stage) do
      verify_candidate_result(run, stage, result)
    else
      {result, nil, nil}
    end
  end

  defp finish_gate(_run, _stage, result), do: {result, nil, nil}

  defp verify_candidate_result(run, stage, result) do
    context = %{
      task_id: run.task_id || "local",
      run_id: run.id || "local",
      attempt_id: run.current_attempt_id || "local",
      base_sha: run.execution[:validation_base]
    }

    opts = [
      workspace: run.workspace,
      validation_archive: run.execution[:validation_archive],
      validation_scratch: run.execution[:validation_scratch]
    ]

    case SymphonyElixir.Validation.verify_result(
           result,
           run.execution[:validation_policy],
           context,
           stage.gate.required,
           opts
         ) do
      {:ok, %{verdict: verdict} = detail} when verdict in [:passed, :failed] ->
        case verified_candidate_feedback(result, run.execution[:validation_archive]) do
          {:ok, feedback} ->
            {put_candidate_result(result, detail, feedback), verdict, json_value(detail)}

          {:error, reason} ->
            failed_validation_result(result, {:feedback_unavailable, reason})
        end

      {:error, reason} ->
        failed_validation_result(result, reason)
    end
  rescue
    error ->
      failed_validation_result(result, {:validation_verification_failed, error})
  end

  defp verified_candidate_feedback({:ok, %{receipt: receipt}}, archive) do
    case SymphonyElixir.Validation.feedback(receipt, archive) do
      {:ok, feedback} when is_list(feedback) -> {:ok, json_value(feedback)}
      {:error, _reason} = error -> error
    end
  end

  defp verified_candidate_feedback(_result, _archive), do: {:error, :missing_validation_receipt}

  defp failed_validation_result(result, reason) do
    failure = %{verdict: :failed, rationale: ["Validation evidence could not be verified."], evidence_id: nil}
    detail = %{"verdict" => "failed", "verified" => false, "reason" => inspect(reason)}
    {put_candidate_result(result, failure, nil), :failed, detail}
  end

  defp put_candidate_result(
         {:ok, %{receipt: %{"id" => id, "manifest_sha256" => manifest_sha256}}},
         gate,
         feedback
       )
       when is_binary(id) and is_binary(manifest_sha256) and is_list(feedback) do
    receipt = %{"id" => id, "manifest_sha256" => manifest_sha256}
    {:ok, %{receipt: receipt, gate: gate, feedback: feedback}}
  end

  defp put_candidate_result(_result, _gate, _feedback), do: {:error, :unverified_validation_result}

  defp candidate_validation?(%{type: :check, gate: %{evaluator: :candidate_validation}}), do: true
  defp candidate_validation?(_stage), do: false

  defp candidate_validation_failure(run, stage) do
    rounds = run.validation_repair_rounds + 1
    run = %{run | validation_repair_rounds: rounds}

    case stage.gate.failure do
      %{repair: repair, max_attempts: max_attempts} ->
        repairs = Map.get(run.repairs, stage.id, 0)

        if rounds < 3 and repairs < max_attempts do
          %{run | repairs: Map.put(run.repairs, stage.id, repairs + 1)} |> advance(repair)
        else
          advance(run, :blocked)
        end

      _ ->
        advance(run, :blocked)
    end
  end

  defp passing_check?({:ok, %{exit_status: 0, timed_out: false}}), do: true
  defp passing_check?(_), do: false

  # Opaque evaluator metadata uses JSON string keys, never transient BEAM atoms.
  defp json_stage_result({:ok, value} = result) when is_map(value) do
    case Jason.encode(value) do
      {:ok, _} -> result
      {:error, _} -> {:error, :invalid_stage_evidence}
    end
  end

  defp json_stage_result(result), do: result

  defp json_value(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp result_evidence({:ok, value}) when is_map(value), do: %{status: :ok, evidence: json_value(value)}
  defp result_evidence({:error, reason}), do: %{status: :error, reason: inspect(reason)}
  defp result_evidence(_), do: %{status: :error, reason: "invalid_stage_result"}

  defp put_outputs(run, stage, value) do
    value = json_value(value)
    outputs = Enum.reduce(stage.outputs, run.outputs, &Map.put(&2, &1, value))
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)
    artifact = %{run_id: run.id, attempt_id: run.current_attempt_id, sha256: digest}
    artifacts = Enum.reduce(stage.outputs, run.artifacts, &Map.put(&2, &1, artifact))
    %{run | outputs: outputs, artifacts: artifacts}
  end

  defp put_session(run, value), do: %{run | session_id: value[:session_id] || run.session_id, thread_id: value[:thread_id] || run.thread_id}

  defp advance(run, terminal) when terminal in [:complete, :blocked], do: %{run | status: terminal, phase: terminal, stage_id: terminal, current_attempt_id: nil}
  defp advance(run, next), do: %{run | status: :ready, phase: :queued, stage_id: next, current_attempt_id: nil}

  defp repair_or_block(run, %{id: id, gate: %{failure: %{repair: repair, max_attempts: max}}}) do
    count = Map.get(run.repairs, id, 0)
    if count < max, do: %{run | repairs: Map.put(run.repairs, id, count + 1)} |> advance(repair), else: advance(run, :blocked)
  end

  defp repair_or_block(run, _stage), do: advance(run, :blocked)
end
