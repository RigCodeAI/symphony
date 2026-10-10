# Controlled local HTTP intake. No installed app, model, cloud or publication.
{:ok, _} = Application.ensure_all_started(:jason)

defmodule LinearIntakeSmoke do
  alias SymphonyElixir.{HttpServer, Orchestrator, WorkstreamStore}

  def run(root) do
    if Path.type(root) != :absolute or File.exists?(root), do: raise("Use a new, disposable absolute directory")
    File.mkdir_p!(root)
    workflow = Path.join(root, "WORKFLOW.md")
    db = Path.join(root, "state.sqlite")

    config = %{
      "organization_id" => "controlled-org",
      "team_id" => "controlled-dev",
      "app_user_id" => "controlled-app",
      "oauth_client_id" => "controlled-oauth",
      "webhook_secret_env" => "LINEAR_API_TOKEN",
      "token_env" => "LINEAR_API_KEY",
      "store_path" => db,
      "workspace_root" => Path.join(root, "workspaces"),
      "workstream_path" => Path.join(root, "not-dispatched.yaml"),
      "agent_id" => "default-cloud",
      "rig_label" => "factory:rig"
    }

    File.write!(
      workflow,
      "---\n" <> Jason.encode!(%{"tracker" => %{"kind" => "memory"}, "server" => %{"port" => 0, "host" => "127.0.0.1"}, "linear_delegation" => config}) <> "\n---\nControlled intake only\n"
    )

    Application.put_env(:symphony_elixir, :workflow_file_path, workflow)
    secret = "controlled-local-intake-secret"
    System.put_env("LINEAR_API_TOKEN", secret)
    {:ok, _} = Application.ensure_all_started(:symphony_elixir)
    %{linear: %{enabled: true, tasks: []}} = Orchestrator.snapshot()
    ^db = :sys.get_state(Orchestrator).workstreams.store_path
    url = "http://127.0.0.1:#{HttpServer.bound_port()}/hooks/linear"

    payload = %{
      "type" => "AppUserNotification",
      "action" => "issueUnassignedFromYou",
      "organizationId" => "controlled-org",
      "appUserId" => "controlled-app",
      "oauthClientId" => "controlled-oauth",
      "webhookTimestamp" => System.system_time(:millisecond),
      "notification" => %{"type" => "issueUnassignedFromYou", "issueId" => "controlled-issue"}
    }

    raw = Jason.encode!(payload, pretty: true)
    signature = :crypto.mac(:hmac, :sha256, secret, raw) |> Base.encode16(case: :lower)
    headers = [{"content-type", "application/json"}, {"linear-event", "AppUserNotification"}, {"linear-delivery", "a8b4a528-6ac9-459d-835d-a591f9ac56e5"}, {"linear-signature", signature}]
    %{status: 200, body: %{"status" => "accepted"}} = Req.post!(url, body: raw, headers: headers, retry: false)
    %{status: 200, body: %{"status" => "duplicate"}} = Req.post!(url, body: raw, headers: headers, retry: false)
    %{status: 401} = Req.post!(url, body: raw <> " ", headers: headers, retry: false)
    old = Process.whereis(Orchestrator)
    ref = Process.monitor(old)
    Process.exit(old, :kill)

    receive do
      {:DOWN, ^ref, :process, ^old, :killed} -> :ok
    after
      2000 -> raise "coordinator did not stop"
    end

    snapshot = await_restart(old)
    [%{issue_id: "controlled-issue", status: :stopped}] = snapshot.linear.tasks
    %{status: 200, body: %{"status" => "duplicate"}} = Req.post!(url, body: raw, headers: headers, retry: false)
    {:ok, %{events: events}} = WorkstreamStore.linear_load(:sys.get_state(Orchestrator).workstreams.store)
    1 = map_size(events)

    report = %{
      status: "passed",
      controlled_intake: true,
      live_acceptance: false,
      checks: ["workflow-configured application startup", "signed raw HTTP bytes", "duplicate receipt", "invalid signature", "coordinator restart"],
      snapshot: snapshot.linear
    }

    path = Path.join(root, "report.json")
    File.write!(path, Jason.encode!(report, pretty: true))
    IO.puts(Jason.encode!(%{status: "passed", report: path, database: db}, pretty: true))
    :ok = Application.stop(:symphony_elixir)
  end

  defp await_restart(old, attempts \\ 200)
  defp await_restart(_old, 0), do: raise("coordinator did not recover")

  defp await_restart(old, attempts) do
    case Process.whereis(Orchestrator) do
      pid when is_pid(pid) and pid != old ->
        Orchestrator.snapshot()

      _ ->
        Process.sleep(10)
        await_restart(old, attempts - 1)
    end
  end
end

case System.argv() do
  [root] -> LinearIntakeSmoke.run(root)
  _ -> raise "Usage: mix run --no-start ../factory/scripts/linear-intake-smoke.exs /absolute/new/directory"
end
