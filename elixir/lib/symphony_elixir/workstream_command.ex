defmodule SymphonyElixir.WorkstreamCommand do
  @moduledoc """
  Executes a local Linux gate with bounded time and output. GNU timeout owns the
  process group so timed-out checks cannot overlap a repair attempt.
  """

  @max_output 65_536
  @allowed_env ~w(PATH HOME LANG LC_ALL TMPDIR CARGO_HOME RUSTUP_HOME CARGO_BUILD_JOBS)

  @spec run([String.t()], Path.t(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def run([command | args], workspace, timeout_ms, inputs \\ %{}) do
    with timeout when is_binary(timeout) <- System.find_executable("timeout"),
         executable when is_binary(executable) <- gate_executable(command, workspace) do
      env =
        Enum.map(System.get_env(), fn {key, value} ->
          {String.to_charlist(key), if(key in @allowed_env, do: String.to_charlist(value), else: false)}
        end) ++ [{~c"WORKSTREAM_INPUTS_JSON", String.to_charlist(Jason.encode!(inputs))}]

      port =
        Port.open({:spawn_executable, ~c"/bin/sh"}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          cd: String.to_charlist(workspace),
          env: env,
          args: Enum.map(command_args(timeout, executable, args, timeout_ms), &String.to_charlist/1)
        ])

      {:os_pid, group_id} = Port.info(port, :os_pid)
      # The startup handshake keeps even an immediate check alive until its PID is known.
      Port.command(port, "start\n")
      collect(port, group_id, "", false)
    else
      nil -> {:error, :gate_executable_or_gnu_timeout_missing}
    end
  end

  defp gate_executable(command, workspace) do
    path = if String.contains?(command, "/"), do: Path.expand(command, workspace), else: command
    System.find_executable(path)
  end

  defp command_args(timeout, executable, args, timeout_ms) do
    ["-c", "read -r start; exec \"$@\"", "workstream", timeout, "--signal=TERM", "--kill-after=1s", "#{timeout_ms / 1000}s", executable | args]
  end

  defp collect(port, group_id, output, truncated) do
    receive do
      {^port, {:data, data}} ->
        available = max(@max_output - byte_size(output), 0)
        chunk = binary_part(data, 0, min(available, byte_size(data)))
        collect(port, group_id, output <> chunk, truncated or byte_size(data) > available)

      {^port, {:exit_status, status}} ->
        # Also stop children left behind by a command that exited before its timeout.
        System.cmd("kill", ["-KILL", "--", "-#{group_id}"], stderr_to_stdout: true)
        {safe_output, expanded} = output |> redact() |> valid_utf8() |> bounded_output()
        truncated = truncated or expanded
        {:ok, %{exit_status: status, output: safe_output, truncated: truncated, timed_out: status in [124, 137]}}
    end
  end

  defp redact(output) do
    output = String.replace(output, ~r/(?:sk-|gh[pousr]_|github_pat_)[A-Za-z0-9_-]+/, "[REDACTED]")

    Enum.reduce(System.get_env(), output, fn {key, value}, acc ->
      if String.match?(key, ~r/TOKEN|SECRET|PASSWORD|API_KEY|ACCESS_KEY/) and byte_size(value) >= 8, do: String.replace(acc, value, "[REDACTED]"), else: acc
    end)
  end

  defp valid_utf8(output) do
    output |> utf8_chunks([]) |> IO.iodata_to_binary()
  end

  defp utf8_chunks(output, chunks) do
    case :unicode.characters_to_binary(output) do
      valid when is_binary(valid) -> Enum.reverse([valid | chunks])
      {:error, valid, <<_invalid, rest::binary>>} -> utf8_chunks(rest, ["�", valid | chunks])
      {:incomplete, valid, _rest} -> Enum.reverse(["�", valid | chunks])
    end
  end

  defp bounded_output(output) when byte_size(output) <= @max_output, do: {output, false}

  defp bounded_output(output) do
    case :unicode.characters_to_binary(binary_part(output, 0, @max_output)) do
      valid when is_binary(valid) -> {valid, true}
      {:incomplete, valid, _rest} -> {valid, true}
    end
  end
end
