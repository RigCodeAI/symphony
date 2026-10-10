defmodule SymphonyElixir.LinearHttpTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.AgentRuntimeSupervisor
  alias SymphonyElixirWeb.Endpoint

  test "HTTP verifies original JSON bytes before durable receipt and duplicate acknowledgement" do
    root = Path.join(System.tmp_dir!(), "linear-http-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    endpoint_config = Application.get_env(:symphony_elixir, Endpoint)
    old_secret = System.get_env("LINEAR_API_TOKEN")
    secret = "controlled-webhook-secret"
    System.put_env("LINEAR_API_TOKEN", secret)

    config = %{
      "organization_id" => "org",
      "team_id" => "dev",
      "app_user_id" => "app",
      "oauth_client_id" => "oauth",
      "webhook_secret_env" => "LINEAR_API_TOKEN",
      "token_env" => "LINEAR_API_KEY",
      "store_path" => Path.join(root, "state.sqlite"),
      "workspace_root" => Path.join(root, "workspaces"),
      "workstream_path" => Path.join(root, "software-change.yaml"),
      "agent_id" => "default-cloud",
      "rig_label" => "factory:rig"
    }

    path = Path.join(root, "WORKFLOW.md")
    File.write!(path, "---\n" <> Jason.encode!(%{"tracker" => %{"kind" => "memory"}, "linear_delegation" => config}) <> "\n---\nControlled HTTP test")
    Workflow.set_workflow_file_path(path)

    runtime =
      start_supervised!(
        {AgentRuntimeSupervisor,
         [name: __MODULE__.Runtime, orchestrator_name: __MODULE__.Coordinator, task_supervisor_name: __MODULE__.Tasks, workstream_store_path: config["store_path"], linear_delegation: config]}
      )

    start_supervised!({HttpServer, [port: 0, orchestrator: __MODULE__.Coordinator]})
    url = "http://127.0.0.1:#{HttpServer.bound_port()}/hooks/linear"

    on_exit(fn ->
      restore_env("LINEAR_API_TOKEN", old_secret)
      Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
      if Process.alive?(runtime), do: Supervisor.stop(runtime)
      File.rm_rf!(root)
    end)

    payload = %{
      "type" => "AppUserNotification",
      "action" => "issueUnassignedFromYou",
      "organizationId" => "org",
      "appUserId" => "app",
      "oauthClientId" => "oauth",
      "webhookTimestamp" => System.system_time(:millisecond),
      "notification" => %{"type" => "issueUnassignedFromYou", "issueId" => "pilot"}
    }

    raw = Jason.encode!(payload, pretty: true)
    signature = :crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower)
    headers = [{"content-type", "application/json"}, {"linear-event", "AppUserNotification"}, {"linear-delivery", "a8b4a528-6ac9-459d-835d-a591f9ac56e5"}, {"linear-signature", signature}]
    assert %{status: 200, body: %{"status" => "accepted"}} = Req.post!(url, body: raw, headers: headers, retry: false)
    assert %{status: 200, body: %{"status" => "duplicate"}} = Req.post!(url, body: raw, headers: headers, retry: false)
    assert [%{issue_id: "pilot", status: :stopped}] = Orchestrator.snapshot(__MODULE__.Coordinator, 1_000).linear.tasks
    assert %{status: 401} = Req.post!(url, body: raw <> " ", headers: headers, retry: false)
    unrelated = Map.put(payload, "appUserId", "other") |> Jason.encode!()
    other_signature = :crypto.mac(:hmac, :sha256, secret, unrelated) |> Base.encode16(case: :lower)
    assert %{status: 422} = Req.post!(url, body: unrelated, headers: List.keyreplace(headers, "linear-signature", 0, {"linear-signature", other_signature}), retry: false)
    store = :sys.get_state(__MODULE__.Coordinator).workstreams.store
    assert {:ok, %{events: events}} = SymphonyElixir.WorkstreamStore.linear_load(store)
    assert map_size(events) == 1
  end
end
