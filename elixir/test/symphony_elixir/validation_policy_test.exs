defmodule SymphonyElixir.ValidationPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ValidationPolicy

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-validation-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, canonical_root} = SymphonyElixir.PathSafety.canonicalize(root)

    workspace = Path.join(canonical_root, "candidate")
    policy_path = Path.join([canonical_root, "trusted", "validation.yml"])
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.dirname(policy_path))
    File.write!(policy_path, policy_yaml())

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: canonical_root, workspace: workspace, policy_path: policy_path}
  end

  test "loads a policy, validates its pinned runner and image, and hashes raw YAML", context do
    source = File.read!(context.policy_path)
    assert {:ok, policy} = ValidationPolicy.load(context.policy_path, context.workspace)

    assert policy.version == 1
    assert policy.revision == "rig-policy-2026-10-09"
    assert policy.digest == sha256(source)
    assert policy.text == source
    assert policy.path == context.policy_path

    assert policy.environment == %{
             image: "ghcr.io/rig/validator@sha256:" <> String.duplicate("a", 64),
             runner_version: "docker-v1"
           }

    assert policy.checks == [
             %{
               id: "unit-tests",
               adapter: "command",
               command: ["mix", "test"],
               timeout_ms: 300_000,
               paths: ["elixir/", "README.md"],
               result_format: "exit_status"
             },
             %{
               id: "architecture",
               adapter: "command",
               command: ["python3", "scripts/check_architecture.py"],
               timeout_ms: 30_000,
               paths: ["crates/"],
               result_format: "assertions_v1"
             },
             %{
               id: "focused-unittest",
               adapter: "command",
               command: [
                 "python3",
                 "-m",
                 "unittest",
                 "discover",
                 "-s",
                 "tools",
                 "-p",
                 "test_architecture.py",
                 "-k",
                 "test_supported_node_python_consumer_passes"
               ],
               timeout_ms: 300_000,
               paths: ["tools/"],
               result_format: "unittest"
             }
           ]
  end

  test "rejects policy paths inside, overlapping, or reached through a symlink", context do
    inside_path = Path.join(context.workspace, "policy.yml")
    File.write!(inside_path, policy_yaml())
    assert {:error, :policy_path_overlaps_workspace} = ValidationPolicy.load(inside_path, context.workspace)
    assert {:error, :policy_path_overlaps_workspace} = ValidationPolicy.load(context.policy_path, context.policy_path)

    symlink_path = Path.join(Path.dirname(context.policy_path), "policy-link.yml")
    File.ln_s!(context.policy_path, symlink_path)
    assert {:error, :policy_path_is_symlink} = ValidationPolicy.load(symlink_path, context.workspace)
  end

  test "rejects mutable images, unsupported runner versions, and unknown fields", context do
    write_policy!(context, String.replace(policy_yaml(), "ghcr.io/rig/validator@sha256:" <> String.duplicate("a", 64), "ghcr.io/rig/validator:latest"))

    assert {:error, {:invalid_policy_image, "ghcr.io/rig/validator:latest"}} =
             ValidationPolicy.load(context.policy_path, context.workspace)

    write_policy!(context, String.replace(policy_yaml(), "runner_version: docker-v1", "runner_version: docker-v2"))

    assert {:error, {:unsupported_policy_runner_version, "docker-v2"}} =
             ValidationPolicy.load(context.policy_path, context.workspace)

    write_policy!(context, policy_yaml() <> "unsupported: true\n")

    assert {:error, {:invalid_policy_fields, :policy, [], ["unsupported"]}} =
             ValidationPolicy.load(context.policy_path, context.workspace)
  end

  test "rejects unbounded checks, unsupported adapters, duplicate ids, and non-simple path globs", context do
    write_policy!(context, String.replace(policy_yaml(), "timeout_ms: 300000", "timeout_ms: 300001"))

    assert {:error, {:invalid_policy_timeout_ms, "unit-tests", 300_001}} =
             ValidationPolicy.load(context.policy_path, context.workspace)

    write_policy!(context, String.replace(policy_yaml(), "adapter: command", "adapter: arbitrary"))

    assert {:error, {:invalid_policy_adapter, "unit-tests", "arbitrary"}} =
             ValidationPolicy.load(context.policy_path, context.workspace)

    write_policy!(context, String.replace(policy_yaml(), "id: architecture", "id: unit-tests"))

    assert {:error, {:duplicate_policy_check_id, "unit-tests"}} =
             ValidationPolicy.load(context.policy_path, context.workspace)

    write_policy!(
      context,
      String.replace(policy_yaml(), "paths: [elixir/, README.md]", "paths: [\"elixir/*.ex\", README.md]")
    )

    assert {:error, {:invalid_policy_paths, "unit-tests"}} =
             ValidationPolicy.load(context.policy_path, context.workspace)
  end

  test "selects exact paths and simple directory prefixes, and rejects uncovered scope", context do
    assert {:ok, policy} = ValidationPolicy.load(context.policy_path, context.workspace)

    assert {:ok, [unit]} = ValidationPolicy.resolve(policy, ["README.md"])
    assert unit.id == "unit-tests"

    assert {:ok, [unit]} = ValidationPolicy.resolve(policy, ["elixir/lib/symphony_elixir/policy.ex"])
    assert unit.id == "unit-tests"

    assert {:ok, [architecture]} = ValidationPolicy.resolve(policy, ["crates/rig/src/lib.rs"])
    assert architecture.id == "architecture"

    assert {:error, :uncovered_diff_scope} = ValidationPolicy.resolve(policy, ["web/src/index.ts"])
    assert {:error, :uncovered_diff_scope} = ValidationPolicy.resolve(policy, ["../outside.txt"])
  end

  test "empty diffs select all ordinary checks", context do
    assert {:ok, policy} = ValidationPolicy.load(context.policy_path, context.workspace)
    assert {:ok, checks} = ValidationPolicy.resolve(policy, [])
    assert Enum.map(checks, & &1.id) == ["unit-tests", "architecture", "focused-unittest"]
  end

  test "coverage selection fails closed and cannot use a generic command check", context do
    assert {:ok, command_policy} = ValidationPolicy.load(context.policy_path, context.workspace)

    assert {:error, :coverage_adapter_unavailable} =
             ValidationPolicy.resolve(command_policy, ["anything.txt"], "coverage")

    coverage_yaml =
      policy_yaml()
      |> String.replace("paths: [elixir/, README.md]", "paths: [\"*\"]")

    coverage_yaml =
      coverage_yaml <>
        """
          - id: fixture-coverage
            adapter: coverage
            command: [coverage-tool]
            timeout_ms: 30000
            paths: [fixtures/]
            result_format: assertions_v1
        """

    write_policy!(context, coverage_yaml)
    assert {:ok, coverage_policy} = ValidationPolicy.load(context.policy_path, context.workspace)

    assert {:error, :coverage_adapter_unavailable} =
             ValidationPolicy.resolve(coverage_policy, ["fixtures/specimen.py"], "coverage")

    assert {:error, :coverage_adapter_unavailable} =
             ValidationPolicy.resolve(coverage_policy, ["fixtures/specimen.py"])
  end

  test "validates required assertions and rejects duplicates or non-scalar values" do
    required = [%{"check" => "unit-tests", "assertion" => "exit_status", "equals" => 0}]

    assert {:ok, [%{check: "unit-tests", assertion: "exit_status", equals: 0}]} =
             ValidationPolicy.validate_required(required)

    assert {:error, {:duplicate_required_assertion, "unit-tests", "exit_status"}} =
             ValidationPolicy.validate_required([
               %{check: "unit-tests", assertion: "exit_status", equals: 0},
               %{check: "unit-tests", assertion: "exit_status", equals: 1}
             ])

    assert {:error, {:invalid_required_assertion, 0, :invalid_value_types}} =
             ValidationPolicy.validate_required([%{check: "unit-tests", assertion: "exit_status", equals: 0.0}])

    assert {:error, :empty_required_assertions} = ValidationPolicy.validate_required([])
  end

  test "passes only complete final evidence with passing selected checks and matching assertions" do
    evidence = evidence()

    required = [
      %{check: "unit-tests", assertion: "exit_status", equals: 0},
      %{check: "focused-unittest", assertion: "test_count", equals: 1}
    ]

    assert ValidationPolicy.gate(evidence, required) == %{
             verdict: :passed,
             rationale: ["All selected checks completed successfully and every required assertion matched."],
             evidence_id: "evidence-123"
           }
  end

  test "fails closed for missing, stale, incomplete, skipped, failed, or mismatched evidence" do
    required = [
      %{check: "unit-tests", assertion: "exit_status", equals: 0},
      %{check: "focused-unittest", assertion: "test_count", equals: 1}
    ]

    assert %{verdict: :failed, rationale: [rationale]} = ValidationPolicy.gate(evidence(), [])
    assert is_binary(rationale)

    assert %{verdict: :failed, rationale: ["Evidence is missing or malformed."], evidence_id: nil} =
             ValidationPolicy.gate(nil, required)

    assert %{verdict: :failed, rationale: ["Evidence is missing or is not final."]} =
             ValidationPolicy.gate(Map.put(evidence(), "mode", "development"), required)

    assert %{verdict: :failed, rationale: ["Evidence is incomplete."]} =
             ValidationPolicy.gate(Map.put(evidence(), "complete", false), required)

    skipped = put_check(evidence(), fn check -> Map.put(check, "status", "skipped") end)
    assert %{verdict: :failed} = ValidationPolicy.gate(skipped, required)

    failed = put_check(evidence(), fn check -> Map.put(check, "exit_status", 1) end)

    assert %{verdict: :failed, rationale: ["A selected check failed."]} =
             ValidationPolicy.gate(failed, required)

    mismatch = put_check(evidence(), fn check -> put_in(check["assertions"]["exit_status"], 1) end)
    assert %{verdict: :failed} = ValidationPolicy.gate(mismatch, required)

    zero_tests =
      put_check_by_id(evidence(), "focused-unittest", fn check ->
        put_in(check["assertions"]["test_count"], 0)
      end)

    assert %{verdict: :failed} = ValidationPolicy.gate(zero_tests, required)

    missing = put_check(evidence(), fn check -> Map.put(check, "assertions", %{}) end)
    assert %{verdict: :failed} = ValidationPolicy.gate(missing, required)

    missing_check = Map.put(evidence(), "checks", [])
    assert %{verdict: :failed} = ValidationPolicy.gate(missing_check, required)
  end

  defp policy_yaml do
    """
    version: 1
    revision: rig-policy-2026-10-09
    environment:
      image: ghcr.io/rig/validator@sha256:#{String.duplicate("a", 64)}
      runner_version: docker-v1
    checks:
      - id: unit-tests
        adapter: command
        command: [mix, test]
        timeout_ms: 300000
        paths: [elixir/, README.md]
        result_format: exit_status
      - id: architecture
        adapter: command
        command: [python3, scripts/check_architecture.py]
        timeout_ms: 30000
        paths: [crates/]
        result_format: assertions_v1
      - id: focused-unittest
        adapter: command
        command: [python3, -m, unittest, discover, -s, tools, -p, test_architecture.py, -k, test_supported_node_python_consumer_passes]
        timeout_ms: 300000
        paths: [tools/]
        result_format: unittest
    """
  end

  defp evidence do
    %{
      "id" => "evidence-123",
      "mode" => "final",
      "complete" => true,
      "checks" => [
        %{
          "id" => "unit-tests",
          "status" => "completed",
          "exit_status" => 0,
          "assertions" => %{"exit_status" => 0}
        },
        %{
          "id" => "focused-unittest",
          "status" => "completed",
          "exit_status" => 0,
          "assertions" => %{"test_count" => 1}
        }
      ]
    }
  end

  defp put_check(evidence, update) do
    Map.update!(evidence, "checks", fn [check | rest] -> [update.(check) | rest] end)
  end

  defp put_check_by_id(evidence, id, update) do
    Map.update!(evidence, "checks", fn checks ->
      Enum.map(checks, fn check -> if check["id"] == id, do: update.(check), else: check end)
    end)
  end

  defp write_policy!(context, source), do: File.write!(context.policy_path, source)
  defp sha256(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
end
