defmodule SymphonyElixir.WorkstreamCancellation do
  @moduledoc """
  Cancellation through the pinned external operation adapter.

  Process groups provide bounded best-effort cleanup, but descendants can escape
  with `setsid`, so the local group adapter always reports `:unknown`. A systemd
  operation releases capacity only after the worker confirms termination of the
  exact contained operation. That control path requires worker qualification.
  """

  @kind "linux-process-group"
  @term_grace_ms 250
  @kill_wait_ms 500
  @poll_interval_ms 10

  @identity_keys ~w(kind operation_id machine_id boot_id pid pgid start_ticks)

  @doc "Captures the current Linux process-group identity without signaling it."
  @spec capture_identity(pos_integer(), String.t()) :: {:ok, map()} | {:error, atom()}
  def capture_identity(pid, operation_id)
      when is_integer(pid) and pid > 0 and is_binary(operation_id) and operation_id != "" do
    with {:ok, host} <- local_host_identity(),
         {:ok, process} <- read_process(pid),
         true <- process.pgid == pid do
      {:ok,
       %{
         "kind" => @kind,
         "operation_id" => operation_id,
         "machine_id" => host.machine_id,
         "boot_id" => host.boot_id,
         "pid" => pid,
         "pgid" => process.pgid,
         "start_ticks" => process.start_ticks
       }}
    else
      false -> {:error, :process_is_not_group_leader}
      {:error, reason} -> {:error, reason}
    end
  end

  def capture_identity(_pid, _operation_id), do: {:error, :invalid_identity_request}

  @doc "Validates that an identity still names the same local Linux process group."
  @spec validate_identity(map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def validate_identity(identity, operation_id)
      when is_map(identity) and is_binary(operation_id) and operation_id != "" do
    with {:ok, normalized} <- normalize_identity(identity, operation_id),
         {:ok, host} <- local_host_identity(),
         :ok <- same_host(normalized, host),
         {:ok, process} <- read_process(normalized["pid"]),
         :ok <- same_process(normalized, process) do
      {:ok, normalized}
    end
  end

  def validate_identity(_identity, _operation_id), do: {:error, :invalid_identity}

  @doc """
  Sends TERM, waits for a bounded grace period, and KILLs remaining group members.

  The coordinator's BEAM worker PID is intentionally not used as process identity.
  Even after local cleanup, process-group control cannot prove that no descendant
  escaped the group, so the result remains `:unknown` and must not trigger replacement.
  """
  @spec cancel(map(), map(), pid() | nil) :: :unknown | :terminated
  def cancel(run, %{external_process: %{"kind" => "systemd-unit"} = identity}, _worker_pid),
    do: SymphonyElixir.WorkerOperation.stop(run.execution[:worker_control], identity)

  def cancel(_run, operation, _worker_pid) when is_map(operation) do
    with operation_id when is_binary(operation_id) and operation_id != "" <- map_value(operation, :id),
         identity when is_map(identity) <- map_value(operation, :external_process),
         {:ok, normalized} <- validate_identity(identity, operation_id),
         {:ok, original_members} <- group_identities(normalized["pgid"]),
         :ok <- signal_group("TERM", normalized["pgid"]) do
      Process.sleep(@term_grace_ms)

      case group_members(normalized["pgid"]) do
        {:ok, []} ->
          :ok

        {:ok, _members} ->
          case signal_original_group(normalized["pgid"], original_members) do
            :ok -> wait_for_group_exit(normalized["pgid"], @kill_wait_ms)
            _ -> :ok
          end

        {:error, _reason} ->
          :ok
      end

      # Read the registered PID again after signaling. The result is still
      # unknown because this adapter does not own an unescapable process boundary.
      _ = verify_registered_process(normalized)
      :unknown
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  def cancel(_run, _operation, _worker_pid), do: :unknown

  defp normalize_identity(identity, operation_id) do
    normalized = Map.take(identity, @identity_keys)

    cond do
      normalized["kind"] != @kind ->
        {:error, :unsupported_process_kind}

      normalized["operation_id"] != operation_id ->
        {:error, :operation_mismatch}

      not valid_host_field?(normalized["machine_id"]) or not valid_host_field?(normalized["boot_id"]) ->
        {:error, :invalid_host_identity}

      not positive_integer?(normalized["pid"]) or not positive_integer?(normalized["pgid"]) or
          not positive_integer?(normalized["start_ticks"]) ->
        {:error, :invalid_process_identity}

      normalized["pid"] != normalized["pgid"] or normalized["pgid"] == 1 ->
        {:error, :process_is_not_group_leader}

      true ->
        {:ok, normalized}
    end
  end

  defp local_host_identity do
    if :os.type() == {:unix, :linux} do
      with {:ok, machine_id} <- read_host_file("/etc/machine-id"),
           {:ok, boot_id} <- read_host_file("/proc/sys/kernel/random/boot_id") do
        {:ok, %{machine_id: machine_id, boot_id: boot_id}}
      end
    else
      {:error, :linux_required}
    end
  end

  defp read_host_file(path) do
    case File.read(path) do
      {:ok, value} ->
        value = String.trim(value)
        if value == "", do: {:error, :host_identity_unavailable}, else: {:ok, value}

      {:error, _reason} ->
        {:error, :host_identity_unavailable}
    end
  end

  defp same_host(identity, host) do
    cond do
      identity["machine_id"] != host.machine_id -> {:error, :machine_mismatch}
      identity["boot_id"] != host.boot_id -> {:error, :boot_mismatch}
      true -> :ok
    end
  end

  defp read_process(pid) when is_integer(pid) and pid > 0 do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> parse_process_stat(stat)
      {:error, :enoent} -> {:error, :process_not_found}
      {:error, :eacces} -> {:error, :process_metadata_unavailable}
      {:error, _reason} -> {:error, :process_metadata_unavailable}
    end
  end

  defp read_process(_pid), do: {:error, :invalid_process_identity}

  defp parse_process_stat(stat) do
    case :binary.matches(stat, ") ") do
      [] ->
        {:error, :invalid_process_metadata}

      matches ->
        {offset, 2} = List.last(matches)
        fields_start = offset + 2
        fields = binary_part(stat, fields_start, byte_size(stat) - fields_start) |> String.split()

        with [_state | after_state] <- fields,
             pgid_text when is_binary(pgid_text) <- Enum.at(after_state, 1),
             start_text when is_binary(start_text) <- Enum.at(after_state, 18),
             {pgid, ""} <- Integer.parse(pgid_text),
             {start_ticks, ""} <- Integer.parse(start_text),
             true <- pgid > 0 and start_ticks > 0 do
          {:ok, %{pgid: pgid, start_ticks: start_ticks}}
        else
          _ -> {:error, :invalid_process_metadata}
        end
    end
  end

  defp same_process(identity, process) do
    cond do
      process.pgid != identity["pgid"] -> {:error, :process_group_mismatch}
      process.start_ticks != identity["start_ticks"] -> {:error, :process_start_mismatch}
      true -> :ok
    end
  end

  defp verify_registered_process(identity) do
    case read_process(identity["pid"]) do
      {:ok, process} -> same_process(identity, process)
      {:error, reason} -> {:error, reason}
    end
  end

  defp group_members(pgid) do
    with {:ok, entries} <- File.ls("/proc") do
      entries
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, found} ->
        case Integer.parse(entry) do
          {pid, ""} ->
            case read_process(pid) do
              {:ok, %{pgid: ^pgid}} -> {:cont, {:ok, [pid | found]}}
              {:ok, _other_group} -> {:cont, {:ok, found}}
              {:error, :process_not_found} -> {:cont, {:ok, found}}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          _ ->
            {:cont, {:ok, found}}
        end
      end)
    else
      {:error, _reason} -> {:error, :process_table_unavailable}
    end
  end

  defp signal_group(signal, pgid) do
    case System.cmd("kill", ["-#{signal}", "--", "-#{pgid}"], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> {:error, :signal_failed}
    end
  rescue
    _ -> {:error, :signal_failed}
  end

  defp group_identities(pgid) do
    with {:ok, members} <- group_members(pgid) do
      Enum.reduce_while(members, {:ok, []}, fn pid, {:ok, found} ->
        case read_process(pid) do
          {:ok, %{pgid: ^pgid, start_ticks: ticks}} -> {:cont, {:ok, [{pid, ticks} | found]}}
          {:error, :process_not_found} -> {:cont, {:ok, found}}
          _ -> {:halt, {:error, :process_identity_changed}}
        end
      end)
    end
  end

  defp signal_original_group(pgid, original_members) do
    # A numeric group may be reused after TERM. KILL requires a surviving
    # member with the same start identity captured before TERM.
    if Enum.any?(original_members, fn {pid, ticks} ->
         read_process(pid) == {:ok, %{pgid: pgid, start_ticks: ticks}}
       end) do
      signal_group("KILL", pgid)
    else
      {:error, :process_identity_changed}
    end
  end

  defp wait_for_group_exit(pgid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_group_exit_until(pgid, deadline)
  end

  defp wait_for_group_exit_until(pgid, deadline) do
    case group_members(pgid) do
      {:ok, []} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(@poll_interval_ms)
          wait_for_group_exit_until(pgid, deadline)
        end
    end
  end

  defp valid_host_field?(value), do: is_binary(value) and value != ""

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp map_value(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
