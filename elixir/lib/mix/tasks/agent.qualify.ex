defmodule Mix.Tasks.Agent.Qualify do
  @moduledoc "Attempts one bounded worker turn for a named agent and writes a qualification receipt."
  use Mix.Task
  alias SymphonyElixir.AgentQualification
  @shortdoc "Qualify one named agent on the current worker"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    {:ok, _} = Application.ensure_all_started(:jason)

    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [
          workspace: :string,
          workspace_root: :string,
          receipt: :string,
          authentication_reference: :string,
          codex_command: :string,
          source_revision: :string,
          deployment_revision: :string,
          worker: :string
        ]
      )

    with [path] <- paths,
         [] <- invalid,
         true <- Enum.all?([:workspace, :workspace_root, :receipt, :authentication_reference], &is_binary(opts[&1])),
         {:ok, receipt} <- AgentQualification.run(path, opts),
         :ok <- write_receipt(opts[:receipt], receipt) do
      Mix.shell().info("#{receipt.agent}: #{receipt.status}; receipt #{opts[:receipt]}")
      if receipt.status == :blocked, do: Mix.raise("Qualification blocked: #{receipt.blocker}")
    else
      {:error, reason} -> Mix.raise("Qualification rejected: #{inspect(reason)}")
      _ -> Mix.raise("Usage: mix agent.qualify AGENT --workspace PATH --workspace-root PATH --receipt FILE --authentication-reference REF")
    end
  end

  defp write_receipt(path, receipt) do
    # Never replace a prior attempt; each invocation has a distinct receipt path.
    with {:ok, file} <- File.open(path, [:write, :exclusive]) do
      try do
        :ok = File.chmod(path, 0o600)
        :ok = IO.binwrite(file, Jason.encode!(receipt, pretty: true) <> "\n")
        :ok = :file.sync(file)
      after
        File.close(file)
      end
    end
  end
end
