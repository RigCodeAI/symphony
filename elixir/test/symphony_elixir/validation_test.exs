defmodule SymphonyElixir.ValidationTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.{Validation, ValidationPolicy}

  @image "python@sha256:78387bc3881b8273120a12ebe6c1ab22b018ccc2c9adf565ae1ac9b536e184ea"
  @moduletag :validation_docker

  setup do
    root = Path.join(System.tmp_dir!(), "validation-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "candidate")
    File.mkdir_p!(workspace)
    git(workspace, ["init", "--quiet"])
    git(workspace, ["config", "user.email", "fixture@example.invalid"])
    git(workspace, ["config", "user.name", "Fixture"])
    File.write!(Path.join(workspace, "check.py"), "print('pass')\n")
    commit(workspace)
    head = git(workspace, ["rev-parse", "HEAD"])
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      workspace: workspace,
      base: head,
      context: %{task_id: "fixture", run_id: "run", attempt_id: "attempt", base_sha: head},
      opts: [validation_archive: Path.join(root, "archive"), validation_scratch: Path.join(root, "scratch"), workspace: workspace]
    }
  end

  test "real clean candidate passes with authenticated identity and checksums; replay reuses evidence", c do
    policy = policy(c)
    required = [%{check: "check", assertion: "exit_status", equals: 0}]
    assert {:ok, result} = Validation.execute(c.workspace, policy, c.context, required, c.opts)
    assert result.gate.verdict == :passed
    assert {:ok, manifest} = Validation.read_receipt(result.receipt, c.opts[:validation_archive])
    assert manifest["candidate_sha"] == c.base
    assert manifest["policy_digest"] == policy.digest
    assert manifest["environment"]["image"] == @image
    assert manifest["checks"] |> hd() |> Map.get("status") == "completed"
    assert [artifact] = manifest["artifacts"]
    assert byte_size(artifact["sha256"]) == 64
    assert {:ok, ^result} = Validation.execute(c.workspace, policy, c.context, required, c.opts)
    refute File.exists?(Path.join(c.workspace, "manifest.json"))
    assert File.ls!(c.opts[:validation_scratch]) == []
  end

  test "failed checks and deliberate exit 124/137 are failures, not inferred timeouts", c do
    for status <- [1, 124, 137] do
      File.write!(Path.join(c.workspace, "check.py"), "import sys\nsys.exit(#{status})\n")
      commit(c.workspace)
      context = %{c.context | attempt_id: "exit-#{status}"}
      assert {:ok, result} = Validation.execute(c.workspace, policy(c), context, required(), c.opts)
      assert result.gate.verdict == :failed
      assert {:ok, manifest} = Validation.read_receipt(result.receipt, c.opts[:validation_archive])
      check = hd(manifest["checks"])
      assert check["exit_status"] == status
      assert check["reason"] == "exited"
    end
  end

  test "service deadline, malformed results and source substitution cannot pass", c do
    for {name, script, format, timeout, reason} <- [
          {"deadline", "import time\ntime.sleep(5)\n", "exit_status", 500, "deadline_exceeded"},
          {"malformed", "print('not json')\n", "assertions_v1", 3000, "malformed_assertions"},
          {"tamper", "open('check.py', 'w').write('forged')\n", "exit_status", 3000, "exited"}
        ] do
      File.write!(Path.join(c.workspace, "check.py"), script)
      commit(c.workspace)
      context = %{c.context | attempt_id: name}
      assert {:ok, result} = Validation.execute(c.workspace, policy(c, format, timeout), context, required(), c.opts)
      assert result.gate.verdict == :failed
      assert {:ok, manifest} = Validation.read_receipt(result.receipt, c.opts[:validation_archive])
      assert hd(manifest["checks"])["reason"] == reason
    end
  end

  test "a skipped required unittest or a zero-test success cannot qualify", c do
    for {name, script, reason} <- [
          {"skip", "import unittest\nclass Test(unittest.TestCase):\n @unittest.skip('unavailable')\n def test_required(self): pass\nunittest.main()\n", "skipped_required_tests"},
          {"empty", "import unittest\nunittest.main()\n", "no_tests_executed"}
        ] do
      File.write!(Path.join(c.workspace, "check.py"), script)
      commit(c.workspace)
      assert {:ok, result} = Validation.execute(c.workspace, policy(c, "unittest"), %{c.context | attempt_id: name}, required(), c.opts)
      assert result.gate.verdict == :failed
      assert {:ok, manifest} = Validation.read_receipt(result.receipt, c.opts[:validation_archive])
      assert hd(manifest["checks"])["reason"] == reason
    end
  end

  test "candidate code has no producer credentials, policy, repository metadata, or host mounts", c do
    File.write!(Path.join(c.workspace, "check.py"), """
    import os
    from pathlib import Path
    assert os.getuid() != 0
    assert 'GITHUB_TOKEN' not in os.environ
    assert 'FACTORY_PRODUCER_SECRET' not in os.environ
    assert not Path('/var/run/docker.sock').exists()
    assert not Path('/candidate/.git').exists()
    assert not Path(#{Jason.encode!(c.opts[:validation_archive])}).exists()
    assert not Path(#{Jason.encode!(Path.join(c.root, "policy.yaml"))}).exists()
    print('isolated')
    """)

    commit(c.workspace)
    System.put_env("FACTORY_PRODUCER_SECRET", "dev236-test-secret-value")
    on_exit(fn -> System.delete_env("FACTORY_PRODUCER_SECRET") end)
    assert {:ok, result} = Validation.execute(c.workspace, policy(c), c.context, required(), c.opts)
    assert result.gate.verdict == :passed
  end

  test "missing forged stale or tampered evidence and source/policy changes cannot qualify", c do
    policy = policy(c)
    assert {:ok, result} = Validation.execute(c.workspace, policy, c.context, required(), c.opts)
    assert {:error, _} = Validation.verify_result({:ok, %{receipt: %{"id" => String.duplicate("0", 64), "manifest_sha256" => String.duplicate("0", 64)}}}, policy, c.context, required(), c.opts)
    assert {:error, _} = Validation.verify_result({:ok, %{exit_status: 0, gate: %{verdict: :passed}}}, policy, c.context, required(), c.opts)
    assert {:error, _} = Validation.verify_result({:ok, result}, %{policy | digest: String.duplicate("0", 64)}, c.context, required(), c.opts)
    assert {:error, _} = Validation.verify_result({:ok, result}, policy, %{c.context | attempt_id: "stale"}, required(), c.opts)
    File.write!(Path.join(c.workspace, "check.py"), "print('changed')\n")
    assert {:error, :dirty_candidate_commit_required} = Validation.verify_result({:ok, result}, policy, c.context, required(), c.opts)
    commit(c.workspace)
    assert {:error, _} = Validation.verify_result({:ok, result}, policy, c.context, required(), c.opts)
    git(c.workspace, ["reset", "--hard", c.base])
    assert {:ok, manifest} = Validation.read_receipt(result.receipt, c.opts[:validation_archive])
    artifact = hd(manifest["artifacts"])
    File.write!(Path.join([c.opts[:validation_archive], result.receipt["id"], artifact["file"]]), "forged")
    assert {:error, :missing_or_corrupt_validation_artifacts} = Validation.verify_result({:ok, result}, policy, c.context, required(), c.opts)
    File.write!(Path.join([c.opts[:validation_archive], result.receipt["id"], "manifest.json"]), "{}")
    assert {:error, _} = Validation.verify_result({:ok, result}, policy, c.context, required(), c.opts)
  end

  test "same evaluator evidence satisfies one inline contract but fails another", c do
    File.write!(Path.join(c.workspace, "check.py"), "print('{\"assertions\":{\"qualified\":true,\"detected\":false}}')\n")
    commit(c.workspace)
    policy = policy(c, "assertions_v1")
    qualification = [%{check: "check", assertion: "qualified", equals: true}]
    capability = [%{check: "check", assertion: "detected", equals: true}]
    assert {:ok, result} = Validation.execute(c.workspace, policy, c.context, qualification, c.opts)
    assert result.gate.verdict == :passed
    assert {:ok, rejected} = Validation.verify_result({:ok, result}, policy, c.context, capability, c.opts)
    assert rejected.verdict == :failed
    assert rejected.evidence_id == result.gate.evidence_id
    refute rejected.rationale == result.gate.rationale
    assert {:ok, missing} = Validation.verify_result({:ok, result}, policy, c.context, [%{check: "check", assertion: "absent", equals: true}], c.opts)
    assert missing.verdict == :failed
  end

  test "candidate-owned policy edits cannot weaken pinned policy", c do
    policy = policy(c)
    File.write!(Path.join(c.workspace, "check.py"), "raise SystemExit(1)\n")
    File.write!(Path.join(c.workspace, "policy.yaml"), "checks: []\nrequired: []\n")
    commit(c.workspace)
    assert {:ok, result} = Validation.execute(c.workspace, policy, c.context, required(), c.opts)
    assert result.gate.verdict == :failed
    assert {:ok, manifest} = Validation.read_receipt(result.receipt, c.opts[:validation_archive])
    assert manifest["policy_digest"] == policy.digest
    assert hd(manifest["checks"])["exit_status"] == 1
  end

  test "development feedback cannot qualify final and final cannot skip required checks", c do
    policy = policy(c)
    File.write!(Path.join(c.workspace, "check.py"), "print('development')\n")
    assert {:ok, feedback} = Validation.execute(c.workspace, policy, c.context, required(), Keyword.put(c.opts, :mode, :development))
    assert {:ok, manifest} = Validation.read_receipt(feedback.receipt, c.opts[:validation_archive])
    assert manifest["mode"] == "development"
    assert {:error, _} = Validation.verify_result({:ok, feedback}, policy, c.context, required(), c.opts)
    commit(c.workspace)
    assert {:error, :final_validation_cannot_skip_checks} = Validation.execute(c.workspace, policy, c.context, required(), Keyword.put(c.opts, :checks, ["check"]))
    assert {:ok, final} = Validation.execute(c.workspace, policy, c.context, required(), c.opts)
    assert final.gate.verdict == :passed
    assert final.receipt != feedback.receipt
  end

  defp required, do: [%{check: "check", assertion: "exit_status", equals: 0}]

  defp policy(c, format \\ "exit_status", timeout \\ 5000) do
    path = Path.join(c.root, "policy.yaml")

    File.write!(path, """
    version: 1
    revision: fixture-v1
    environment:
      image: #{@image}
      runner_version: docker-v1
    checks:
      - id: check
        adapter: command
        command: [python3, check.py]
        timeout_ms: #{timeout}
        paths: ['*']
        result_format: #{format}
    """)

    {:ok, policy} = ValidationPolicy.load(path, c.workspace)
    policy
  end

  defp commit(workspace) do
    git(workspace, ["add", "."])
    git(workspace, ["commit", "--quiet", "--allow-empty", "-m", "fixture"])
  end

  defp git(workspace, args) do
    {output, 0} = System.cmd("git", args, cd: workspace, stderr_to_stdout: true)
    String.trim(output)
  end
end

defmodule SymphonyElixir.ValidationStorageTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Validation

  test "storage cannot overlap filesystem root or the source checkout" do
    assert {:error, :validation_storage_overlaps_candidate} = Validation.storage_roots("/candidate", validation_archive: "/", validation_scratch: "/safe-scratch")
    assert {:error, :validation_storage_overlaps_candidate} = Validation.storage_roots("/candidate", validation_archive: "/safe-archive", validation_scratch: "/")
    source = Path.expand("../../..", __DIR__)
    assert {:error, :validation_storage_overlaps_candidate} = Validation.storage_roots("/candidate", validation_archive: Path.join(source, "generated"), validation_scratch: "/safe-scratch")
  end
end
