defmodule Mix.Tasks.Workstream.Run do
  @moduledoc """
  Validates or executes a local workstream without starting tracker polling.
  """
  use Mix.Task
  alias SymphonyElixir.{Workstream, WorkstreamRunner}
  @shortdoc "Run a local file-defined workstream"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    {:ok, _} = Application.ensure_all_started(:jason)
    Logger.configure(level: :info)

    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [
          inputs: :string,
          workspace: :string,
          workspace_root: :string,
          validate_only: :boolean,
          codex_command: :string
        ]
      )

    with [path] <- paths,
         [] <- invalid,
         input_path when is_binary(input_path) <- opts[:inputs],
         {:ok, json} <- File.read(input_path),
         {:ok, inputs} when is_map(inputs) <- Jason.decode(json) do
      evaluate(path, inputs, opts)
    else
      _ -> Mix.raise("Usage: mix workstream.run FILE --inputs JSON [--validate-only | --workspace PATH --workspace-root PATH]")
    end
  end

  defp evaluate(path, inputs, opts) do
    result =
      if opts[:validate_only] do
        case Workstream.load(path, inputs) do
          {:ok, definition} -> {:ok, %{status: :valid, name: definition.name}}
          error -> error
        end
      else
        if not is_binary(opts[:workspace]) or not is_binary(opts[:workspace_root]),
          do: Mix.raise("Execution requires --workspace and --workspace-root")

        WorkstreamRunner.run(path, inputs, opts)
      end

    case result do
      {:ok, report} ->
        Mix.shell().info(Jason.encode!(report, pretty: true))
        if report.status == :blocked, do: Mix.raise("Workstream blocked; inspect gate output above")

      {:error, reason} ->
        Mix.raise("Workstream rejected: #{inspect(reason)}")
    end
  end
end
