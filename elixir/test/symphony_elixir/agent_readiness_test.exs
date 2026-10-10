defmodule SymphonyElixir.AgentReadinessTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentReadiness

  defp agent(overrides \\ %{}) do
    Map.merge(
      %{
        name: "worker",
        model: "gpt-6.1-sol",
        reasoning_effort: "high",
        daybreak: false,
        authentication: %{mode: :subscription, reference: "inherited"}
      },
      overrides
    )
  end

  defp runtime(overrides \\ %{}) do
    Map.merge(
      %{
        account: %{type: "chatgpt", plan_type: "plus"},
        models: [
          %{
            "id" => "gpt-6.1-sol",
            "supportedReasoningEfforts" => [%{"reasoningEffort" => "high"}],
            "availableAccessPrograms" => %{"cyber" => ["standard"]}
          }
        ],
        limits: %{"ordinaryUsageAllowed" => true}
      },
      overrides
    )
  end

  test "dispatch accepts subscription and legacy agents but rejects other authentication" do
    assert :ok = AgentReadiness.dispatch(agent())
    assert :ok = AgentReadiness.dispatch(%{daybreak: false})

    assert {:error, :unsupported_authentication} =
             AgentReadiness.dispatch(agent(%{authentication: %{mode: :api, reference: "key"}}))
  end

  test "probe definitions require explicit Daybreak, subscription, model, and effort settings" do
    assert :ok = AgentReadiness.validate_definition(agent())
    assert :ok = AgentReadiness.validate_definition(agent(%{daybreak: true}))

    assert {:error, :invalid_daybreak} =
             AgentReadiness.validate_definition(Map.delete(agent(), :daybreak))

    assert {:error, :chatgpt_subscription_required} =
             AgentReadiness.validate_definition(agent(%{authentication: %{mode: :subscription, reference: ""}}))

    assert {:error, :chatgpt_subscription_required} =
             AgentReadiness.validate_definition(agent(%{authentication: %{mode: :subscription, reference: "   "}}))

    assert {:error, :chatgpt_subscription_required} =
             AgentReadiness.validate_definition(Map.delete(agent(), :authentication))

    assert {:error, :invalid_agent_model} =
             AgentReadiness.validate_definition(agent(%{model: "  "}))

    assert {:error, :invalid_agent_reasoning_effort} =
             AgentReadiness.validate_definition(Map.delete(agent(), :reasoning_effort))
  end

  test "Daybreak is blocked before authentication checks and invalid settings are rejected" do
    assert {:error, :daybreak_execution_unverified} =
             AgentReadiness.dispatch(agent(%{daybreak: true, authentication: %{mode: :api}}))

    assert {:error, :invalid_daybreak} = AgentReadiness.dispatch(agent(%{daybreak: "true"}))
    assert {:error, :invalid_daybreak} = AgentReadiness.check(agent(%{daybreak: nil}), runtime())
  end

  test "readiness requires a ChatGPT subscription and does not fall back to API credentials" do
    assert :ok = AgentReadiness.check(agent(), runtime())

    assert {:error, :chatgpt_subscription_required} =
             AgentReadiness.check(
               agent(%{authentication: %{mode: :api, reference: "key"}}),
               runtime()
             )

    assert {:error, :chatgpt_account_required} =
             AgentReadiness.check(agent(), runtime(%{account: %{type: "api"}}))
  end

  test "readiness requires the exact requested model and reasoning effort" do
    other_model = %{
      "id" => "gpt-6.1-alt",
      "supportedReasoningEfforts" => [%{"reasoningEffort" => "high"}],
      "availableAccessPrograms" => %{"cyber" => ["standard"]}
    }

    assert {:error, :model_not_advertised} =
             AgentReadiness.check(agent(), runtime(%{models: [other_model]}))

    assert {:error, :model_catalog_missing} =
             AgentReadiness.check(agent(), runtime(%{models: nil}))

    assert {:error, :reasoning_effort_not_advertised} =
             AgentReadiness.check(agent(%{reasoning_effort: "max"}), runtime())

    model_without_efforts = %{
      "id" => "gpt-6.1-sol",
      "availableAccessPrograms" => %{"cyber" => ["standard"]}
    }

    assert {:error, :reasoning_effort_catalog_missing} =
             AgentReadiness.check(agent(), runtime(%{models: [model_without_efforts]}))
  end

  test "readiness requires the requested Cyber access program to be advertised" do
    model_without_access = %{
      "id" => "gpt-6.1-sol",
      "supportedReasoningEfforts" => [%{"reasoningEffort" => "high"}]
    }

    assert {:error, :access_program_catalog_missing} =
             AgentReadiness.check(agent(), runtime(%{models: [model_without_access]}))

    model_with_daybreak_only = %{
      "id" => "gpt-6.1-sol",
      "supportedReasoningEfforts" => [%{"reasoningEffort" => "high"}],
      "availableAccessPrograms" => %{"cyber" => ["daybreakBlue"]}
    }

    assert {:error, :access_program_not_advertised} =
             AgentReadiness.check(agent(), runtime(%{models: [model_with_daybreak_only]}))
  end

  test "Daybreak eligibility requires its explicit catalog entry but never enables dispatch" do
    daybreak_agent = agent(%{daybreak: true})

    assert {:error, :access_program_not_advertised} =
             AgentReadiness.check(daybreak_agent, runtime())

    model_with_daybreak = %{
      "id" => "gpt-6.1-sol",
      "supportedReasoningEfforts" => [%{"reasoningEffort" => "high"}],
      "availableAccessPrograms" => %{"cyber" => ["standard", "daybreakBlue"]}
    }

    assert :ok = AgentReadiness.check(daybreak_agent, runtime(%{models: [model_with_daybreak]}))

    assert {:error, :daybreak_execution_unverified} = AgentReadiness.dispatch(daybreak_agent)
  end

  test "explicit usage pause flags block while absent usage values are not treated as zero" do
    assert {:error, :usage_paused} =
             AgentReadiness.check(agent(), runtime(%{limits: %{"ordinaryUsageAllowed" => false}}))

    assert {:error, :usage_paused} =
             AgentReadiness.check(
               agent(),
               runtime(%{limits: %{"rateLimits" => [%{"spendControlReached" => true}]}})
             )

    assert :ok = AgentReadiness.check(agent(), runtime(%{limits: %{"rateLimits" => [%{}]}}))
  end

  test "requested settings stay on the named agent without model substitution" do
    requested = AgentReadiness.requested(agent(%{model: "chosen-model"}))

    assert requested == %{
             model: "chosen-model",
             reasoning_effort: "high",
             daybreak: false,
             cyber_access_program: "standard",
             authentication: %{mode: :subscription, reference: "inherited"}
           }

    assert {:error, :model_not_advertised} =
             AgentReadiness.check(agent(%{model: "chosen-model"}), runtime())
  end
end
