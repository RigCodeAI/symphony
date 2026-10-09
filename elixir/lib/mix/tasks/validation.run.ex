defmodule Mix.Tasks.Validation.Run do
  @moduledoc "Runs trusted development or final validation without starting tracker dispatch."
  use Mix.Task
  alias SymphonyElixir.{Validation, ValidationPolicy, Workstream}
  @shortdoc "Validate a candidate using a pinned policy and an inline workstream gate"

  @impl Mix.Task
  def run(args) do
    for app <- [:yaml_elixir, :jason], do: Application.ensure_all_started(app)

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          workspace: :string,
          policy: :string,
          workstream: :string,
          inputs: :string,
          stage: :string,
          base: :string,
          archive: :string,
          scratch: :string,
          task: :string,
          run: :string,
          attempt: :string,
          mode: :string,
          check: :keep
        ]
      )

    if rest != [] or invalid != [], do: Mix.raise("Invalid validation arguments")

    mode =
      case Keyword.get(opts, :mode, "final") do
        "development" -> :development
        "final" -> :final
        _ -> Mix.raise("mode must be development or final")
      end

    workspace = required!(opts, :workspace)
    inputs = opts |> required!(:inputs) |> File.read!() |> Jason.decode!()

    with {:ok, definition} <- Workstream.load(required!(opts, :workstream), inputs),
         %{gate: %{evaluator: :candidate_validation, required: required}} <- definition.stages[required!(opts, :stage)],
         {:ok, policy} <- ValidationPolicy.load(required!(opts, :policy), workspace) do
      context = %{task_id: required!(opts, :task), run_id: required!(opts, :run), attempt_id: required!(opts, :attempt), base_sha: required!(opts, :base)}
      execution = [validation_archive: required!(opts, :archive), validation_scratch: required!(opts, :scratch), mode: mode]
      execution = if Keyword.has_key?(opts, :check), do: Keyword.put(execution, :checks, Keyword.get_values(opts, :check)), else: execution

      case Validation.execute(workspace, policy, context, required, execution) do
        {:ok, result} ->
          Mix.shell().info(Jason.encode!(result, pretty: true))
          if mode == :final and result.gate.verdict != :passed, do: Mix.raise("Candidate validation gate failed; inspect receipt and rationale")

        {:error, reason} ->
          Mix.raise("Candidate validation blocked: #{inspect(reason)}")
      end
    else
      nil -> Mix.raise("Unknown stage")
      {:error, reason} -> Mix.raise("Validation definition blocked: #{inspect(reason)}")
      _ -> Mix.raise("Stage must use a candidate_validation evaluator")
    end
  end

  defp required!(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> value
      _ -> Mix.raise("Missing --#{key}")
    end
  end
end
