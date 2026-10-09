defmodule SymphonyElixir.ValidationCommand do
  @moduledoc """
  Runs candidate commands in disposable unprivileged containers. No host mounts,
  credentials, policy files or evidence store are exposed. The service owns the
  deadline and container teardown; exit 124/137 alone never implies a timeout.
  """
  @max_output 65_536

  @spec run(map(), map(), Path.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def run(check, environment, source, paths) do
    name = "factory-validation-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

    staging = name <> "-source"
    image_tag = name <> ":source"

    args = [
      "create",
      "--name",
      name,
      "--pull",
      "never",
      "--read-only",
      "--tmpfs",
      "/tmp:rw,nosuid,size=536870912",
      "--network",
      "none",
      "--user",
      "65534:65534",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--pids-limit",
      "128",
      "--memory",
      "512m",
      "--cpus",
      "1",
      "--ulimit",
      "fsize=67108864:67108864",
      "--workdir",
      "/candidate",
      "--env",
      "HOME=/tmp",
      "--env",
      "TMPDIR=/tmp",
      "--env",
      "CARGO_TARGET_DIR=/tmp/target",
      "--env",
      "PYTHONDONTWRITEBYTECODE=1",
      "--entrypoint",
      hd(check.command),
      image_tag | tl(check.command)
    ]

    try do
      # Stage source without executing candidate code, then seal it in an image.
      # The execution container has a read-only root and only a bounded /tmp.
      with {:ok, _} <- docker(["create", "--name", staging, "--pull", "never", "--entrypoint", "/bin/true", environment.image]),
           {:ok, _} <- docker(["cp", source <> "/.", staging <> ":/candidate"]),
           {:ok, image_id} <- docker(["commit", staging, image_tag]),
           {:ok, _} <- docker(args),
           {:ok, result} <- attach(name, check.timeout_ms),
           {:ok, state_json} <- docker(["inspect", "--format", "{{json .State}}", name]),
           {:ok, state} <- Jason.decode(String.trim(state_json)),
           {:ok, after_source} <- copy_result(name, source),
           {:ok, source_after} <- SymphonyElixir.Validation.source_digest(after_source, paths) do
        {:ok,
         Map.merge(result, %{
           source_after: source_after,
           oom_killed: state["OOMKilled"] == true,
           container_exit: state["ExitCode"],
           environment: environment.image,
           build_digest: String.trim(image_id),
           limits: %{memory_bytes: 536_870_912, cpus: 1, pids: 128, writable_bytes: 536_870_912}
         })}
      end
    after
      docker(["rm", "--force", name])
      docker(["rm", "--force", staging])
      docker(["image", "rm", "--force", image_tag])
    end
  end

  defp copy_result(name, source) do
    path = source <> "-after-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    with :ok <- File.mkdir(path), {:ok, _} <- docker(["cp", name <> ":/candidate/.", path]), do: {:ok, path}
  end

  defp attach(name, timeout_ms) do
    case System.find_executable("docker") do
      nil ->
        {:error, :docker_unavailable}

      executable ->
        port = Port.open({:spawn_executable, String.to_charlist(executable)}, [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(["start", "--attach", name], &String.to_charlist/1)])
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        collect(port, name, deadline, "", false)
    end
  end

  defp collect(port, name, deadline, output, truncated) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        available = max(@max_output - byte_size(output), 0)
        collect(port, name, deadline, output <> binary_part(data, 0, min(byte_size(data), available)), truncated or byte_size(data) > available)

      {^port, {:exit_status, status}} ->
        {:ok, %{exit_status: status, output: safe_output(output), truncated: truncated, timed_out: false, cause: "exited"}}
    after
      remaining ->
        docker(["kill", name])

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          5_000 -> Port.close(port)
        end

        {:ok, %{exit_status: nil, output: safe_output(output), truncated: truncated, timed_out: true, cause: "deadline_exceeded"}}
    end
  end

  defp safe_output(output) do
    # Invalid or truncated UTF-8 is retained as base64 rather than accepted as JSON.
    if String.valid?(output), do: output, else: "base64:" <> Base.encode64(output)
  end

  defp docker(args) do
    case System.cmd("docker", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, code} -> {:error, {:container_operation_failed, hd(args), code}}
    end
  rescue
    _ -> {:error, :docker_unavailable}
  end
end
