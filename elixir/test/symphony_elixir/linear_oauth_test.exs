defmodule SymphonyElixir.Linear.OAuthTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias SymphonyElixir.Linear.OAuth

  setup do
    previous = System.get_env("LINEAR_API_KEY")
    System.put_env("LINEAR_API_KEY", "private-client-secret")
    on_exit(fn -> if previous, do: System.put_env("LINEAR_API_KEY", previous), else: System.delete_env("LINEAR_API_KEY") end)
    clock = start_supervised!({Agent, fn -> %{time: 100, count: 0} end})
    parent = self()

    request = fn form ->
      send(parent, {:token_form, form})
      number = Agent.get_and_update(clock, fn value -> {value.count + 1, %{value | count: value.count + 1}} end)
      {:ok, %{status: 200, body: %{"access_token" => "token-#{number}", "token_type" => "Bearer", "expires_in" => 60}}}
    end

    name = String.to_atom("oauth_test_#{System.unique_integer([:positive])}")
    server = start_supervised!({OAuth, name: name, request_fun: request, clock: fn -> Agent.get(clock, & &1.time) end})
    config = %{"oauth_client_id" => "installed-client-id", "client_secret_env" => "LINEAR_API_KEY"}
    %{server: server, clock: clock, config: config}
  end

  test "each run mints fixed app scopes once and uses only its own in-memory token", c do
    request = fn _payload, token -> {:ok, %{status: 200, body: %{"token_seen" => token}}} end
    opts = [server: c.server, request_fun: request]
    assert {:ok, %{body: %{"token_seen" => "token-1"}}} = OAuth.graphql(c.config, "run-1", %{}, opts)
    assert {:ok, %{body: %{"token_seen" => "token-1"}}} = OAuth.graphql(c.config, "run-1", %{}, opts)
    assert {:ok, %{body: %{"token_seen" => "token-2"}}} = OAuth.graphql(c.config, "run-2", %{}, opts)
    assert_receive {:token_form, form}
    assert form == [grant_type: "client_credentials", scope: "read,write,app:assignable", client_id: "installed-client-id", client_secret: "private-client-secret"]
    assert_receive {:token_form, ^form}
    refute_receive {:token_form, _}
    status = inspect(:sys.get_status(c.server))
    refute status =~ "private-client-secret"
    refute status =~ "token-1"
  end

  test "the normal Linear GraphQL client uses minted bearer auth instead of the client secret", c do
    request = fn payload, token ->
      assert payload["query"] == "query { viewer { id } }"
      assert token == "token-1"
      refute token == System.get_env("LINEAR_API_KEY")
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "app-user"}}}}}
    end

    opts = OAuth.client_opts(c.config, "run-1", server: c.server, request_fun: request)
    assert {:ok, %{"data" => %{"viewer" => %{"id" => "app-user"}}}} = SymphonyElixir.Linear.Client.graphql("query { viewer { id } }", %{}, opts)
  end

  test "missing client secret blocks before token or GraphQL requests", c do
    System.delete_env("LINEAR_API_KEY")
    assert {:error, :linear_oauth_credentials_missing} = OAuth.graphql(c.config, "run-1", %{}, server: c.server, request_fun: fn _, _ -> flunk("no GraphQL without credentials") end)
    refute_receive {:token_form, _}
  end

  test "401 renews once and a second 401 does not loop or expose response credentials", c do
    request = fn _payload, token ->
      send(self(), {:request, token})
      {:ok, %{status: 401, body: "private-client-secret " <> token}}
    end

    assert {:ok, %{status: 401, body: :redacted}} = OAuth.graphql(c.config, "run-1", %{}, server: c.server, request_fun: request)
    assert_receive {:request, "token-1"}
    assert_receive {:request, "token-2"}
    refute_receive {:request, _}
    assert Agent.get(c.clock, & &1.count) == 2
  end

  test "expiry renews and restart loses rather than persists tokens", c do
    request = fn _payload, token -> {:ok, %{status: 200, body: token}} end
    opts = [server: c.server, request_fun: request]
    assert {:ok, %{body: "token-1"}} = OAuth.graphql(c.config, "run-1", %{}, opts)
    Agent.update(c.clock, &%{&1 | time: 131})
    assert {:ok, %{body: "token-2"}} = OAuth.graphql(c.config, "run-1", %{}, opts)
    stop_supervised!(OAuth)

    restarted =
      start_supervised!({OAuth, name: :oauth_restarted_test, request_fun: fn _ -> {:ok, %{status: 200, body: %{"access_token" => "fresh-token", "token_type" => "Bearer", "expires_in" => 60}}} end})

    assert {:ok, %{body: "fresh-token"}} = OAuth.graphql(c.config, "run-1", %{}, server: restarted, request_fun: request)
  end

  test "token failures and malformed expiry fail closed without echoing secrets", c do
    for body <- [%{"error_description" => "private-client-secret"}, %{"access_token" => "bad-token", "token_type" => "Bearer", "expires_in" => 0}] do
      stop_supervised!(OAuth)
      server = start_supervised!({OAuth, name: :oauth_failure_test, request_fun: fn _ -> {:ok, %{status: 200, body: body}} end})

      log =
        capture_log(fn ->
          assert {:error, :linear_oauth_token_failed} = OAuth.graphql(c.config, "run-1", %{}, server: server, request_fun: fn _, _ -> flunk("must not send GraphQL without a valid token") end)
        end)

      refute log =~ "private-client-secret"
      refute log =~ "bad-token"
    end
  end
end
