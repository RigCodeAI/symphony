defmodule SymphonyElixir.WorkstreamCancellationTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.WorkstreamCancellation

  if :os.type() != {:unix, :linux} do
    @moduletag skip: "controlled process-group cancellation requires Linux"
  end

  test "cancels a controlled parent and child within a bounded time, but keeps the result unknown" do
    {port, leader_pid, child_pid, identity} =
      start_group(
        "/bin/sh -c 'trap \"\" TERM; printf \"CHILD %s\\n\" \"$$\"; exec sleep 60' & printf 'READY %s\\n' \"$$\"; wait",
        "op-controlled"
      )

    operation = %{id: "op-controlled", external_process: identity}
    started = System.monotonic_time(:millisecond)

    try do
      assert :unknown = WorkstreamCancellation.cancel(%{}, operation, self())
      assert System.monotonic_time(:millisecond) - started < 2_000
      assert wait_until_dead(leader_pid, 1_500)
      assert wait_until_dead(child_pid, 1_500)
    after
      kill_process(leader_pid)
      kill_process(child_pid)
      close_port(port)
    end
  end

  test "stale start ticks never signal the currently running process group" do
    {port, leader_pid, child_pid, identity} =
      start_group(
        "/bin/sh -c 'trap \"\" TERM; printf \"CHILD %s\\n\" \"$$\"; exec sleep 60' & printf 'READY %s\\n' \"$$\"; wait",
        "op-stale"
      )

    stale_identity = Map.update!(identity, "start_ticks", &(&1 + 1))
    operation = %{id: "op-stale", external_process: stale_identity}

    try do
      assert {:error, :process_start_mismatch} = WorkstreamCancellation.validate_identity(stale_identity, "op-stale")
      assert :unknown = WorkstreamCancellation.cancel(%{}, operation, self())
      assert process_running?(leader_pid)
      assert process_running?(child_pid)
    after
      kill_process(leader_pid)
      kill_process(child_pid)
      close_port(port)
    end
  end

  test "an escaped setsid descendant survives group cleanup and is explicitly cleaned by the test" do
    script =
      "setsid /bin/sh -c 'trap \"\" TERM; printf \"CHILD %s\\n\" \"$$\"; exec sleep 60' & printf 'READY %s\\n' \"$$\"; wait"

    {port, leader_pid, escaped_pid, identity} = start_group(script, "op-escaped")
    operation = %{id: "op-escaped", external_process: identity}

    try do
      assert :unknown = WorkstreamCancellation.cancel(%{}, operation, self())
      assert wait_until_dead(leader_pid, 1_500)
      assert process_running?(escaped_pid)
    after
      kill_process(escaped_pid)
      close_port(port)
    end
  end

  test "missing process identity does not signal a process group" do
    {port, leader_pid, child_pid, _identity} =
      start_group(
        "/bin/sh -c 'trap \"\" TERM; printf \"CHILD %s\\n\" \"$$\"; exec sleep 60' & printf 'READY %s\\n' \"$$\"; wait",
        "op-no-identity"
      )

    try do
      assert :unknown = WorkstreamCancellation.cancel(%{}, %{id: "op-no-identity"}, self())
      assert process_running?(leader_pid)
      assert process_running?(child_pid)
    after
      kill_process(leader_pid)
      kill_process(child_pid)
      close_port(port)
    end
  end

  defp start_group(script, operation_id) do
    setsid = System.find_executable("setsid") || raise "setsid is required for Linux cancellation tests"
    shell = System.find_executable("sh") || raise "sh is required for Linux cancellation tests"

    port =
      Port.open({:spawn_executable, String.to_charlist(setsid)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: Enum.map(["--fork", "--wait", shell, "-c", script], &String.to_charlist/1)
      ])

    {leader_pid, child_pid} = await_ready(port, "")
    assert leader_pid != child_pid
    {:ok, identity} = WorkstreamCancellation.capture_identity(leader_pid, operation_id)
    {port, leader_pid, child_pid, identity}
  end

  defp await_ready(port, output) do
    receive do
      {^port, {:data, data}} ->
        output = output <> data

        leader = Regex.run(~r/READY\s+(\d+)/, output)
        child = Regex.run(~r/CHILD\s+(\d+)/, output)

        case {leader, child} do
          {[_, leader_pid], [_, child_pid]} -> {String.to_integer(leader_pid), String.to_integer(child_pid)}
          _ -> await_ready(port, output)
        end

      {^port, {:exit_status, status}} ->
        flunk("controlled process group exited before startup: #{status}")
    after
      3_000 -> flunk("timed out waiting for controlled process group startup")
    end
  end

  defp process_running?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        case :binary.matches(stat, ") ") do
          [] ->
            false

          matches ->
            {offset, 2} = List.last(matches)
            rest = binary_part(stat, offset + 2, byte_size(stat) - offset - 2)
            state = rest |> String.split() |> hd()
            state not in ["Z", "X"]
        end

      {:error, _reason} ->
        false
    end
  end

  defp wait_until_dead(pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_dead_loop(pid, deadline)
  end

  defp wait_until_dead_loop(pid, deadline) do
    if process_running?(pid) do
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        wait_until_dead_loop(pid, deadline)
      end
    else
      true
    end
  end

  defp kill_process(pid) do
    if process_running?(pid), do: System.cmd("kill", ["-KILL", "--", Integer.to_string(pid)], stderr_to_stdout: true)
  end

  defp close_port(port) do
    receive do
      {^port, {:exit_status, _status}} -> :ok
      {^port, {:data, _data}} -> close_port(port)
    after
      100 ->
        if Port.info(port), do: Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end
end
