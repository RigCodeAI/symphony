# Local trusted-validation demo. No model turn, publication or cloud resources.
for app <- [:yaml_elixir, :jason], do: {:ok, _} = Application.ensure_all_started(app)

defmodule ValidationSmoke do
  alias SymphonyElixir.{Validation, ValidationPolicy, Workstream}

  def run(source, root) do
    if Path.type(root) != :absolute or File.exists?(root), do: raise("Use a new absolute output directory")
    repository = Path.join(root, "workspaces/rig")
    File.mkdir_p!(Path.dirname(repository))
    git!(source, ["clone", "--no-hardlinks", "--no-local", source, repository])
    git!(repository, ["remote", "set-url", "--push", "origin", "DISABLED"])
    git!(repository, ["config", "user.name", "Validation Demo"])
    git!(repository, ["config", "user.email", "validation@example.invalid"])
    git!(repository, ["switch", "-c", "cycle/dev-236-demo"])
    base = git!(repository, ["rev-parse", "HEAD"])
    factory = Path.expand("..", __DIR__)
    {:ok, definition} = Workstream.load(Path.join(factory, "workstreams/rig-validation.yaml"), %{"task" => "Harmless local README comment"})
    required = definition.stages["validate"].gate.required
    {:ok, policy} = ValidationPolicy.load(Path.join(factory, "policies/rig-local.yaml"), repository)
    context = %{task_id: "DEV-236-demo", run_id: "local-rig", attempt_id: "final", base_sha: base}
    opts = [validation_archive: Path.join(root, "archive"), validation_scratch: Path.join(root, "scratch"), workspace: repository]

    File.write!(Path.join(repository, "README.md"), "\n<!-- Local DEV-236 validation demonstration. -->\n", [:append])
    {:ok, feedback} = Validation.execute(repository, policy, %{context | attempt_id: "development"}, required, Keyword.put(opts, :mode, :development))
    {:ok, feedback_manifest} = Validation.read_receipt(feedback.receipt, opts[:validation_archive])
    "development" = feedback_manifest["mode"]
    [check] = feedback_manifest["checks"]
    0 = check["exit_status"]
    1 = check["assertions"]["test_count"]
    {:error, :dirty_candidate_commit_required} = Validation.verify_result({:ok, feedback}, policy, context, required, opts)

    git!(repository, ["add", "README.md"])
    git!(repository, ["commit", "-m", "docs: demonstrate local candidate validation"])
    {:ok, final} = Validation.execute(repository, policy, context, required, opts)
    :passed = final.gate.verdict
    {:ok, final_manifest} = Validation.read_receipt(final.receipt, opts[:validation_archive])
    {:ok, ^final} = Validation.execute(repository, policy, context, required, opts)
    # Source edits invalidate final eligibility, then restore only this demo edit.
    File.write!(Path.join(repository, "README.md"), "\nTampered after validation\n", [:append])
    {:error, :dirty_candidate_commit_required} = Validation.verify_result({:ok, final}, policy, context, required, opts)
    git!(repository, ["restore", "README.md"])
    {:ok, %{verdict: :passed}} = Validation.verify_result({:ok, final}, policy, context, required, opts)
    report = %{base: base, candidate: final_manifest["candidate_sha"], policy: policy.digest,
      development: feedback, final: final, test_count: 1, repository: repository,
      command: check["command"], assertions: ["development cannot qualify", "final passes", "replay reuses receipt", "source edits invalidate", "source restored requalifies"]}
    File.write!(Path.join(root, "report.json"), Jason.encode!(report, pretty: true))
    IO.puts(Jason.encode!(report, pretty: true))
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end
end
case System.argv() do
  [source, root] -> ValidationSmoke.run(Path.expand(source), root)
  _ -> raise("Usage: mix run --no-start ../factory/scripts/validation-smoke.exs /absolute/rig-source /tmp/new-validation-demo")
end
