defmodule SymphonyElixirWeb.LinearWebhookPlug do
  @moduledoc "Public webhook surface; no dashboard, API, sessions or method override."
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", request_path: "/hooks/linear"} = conn, opts) do
    conn = Plug.Conn.assign(conn, :linear_orchestrator, Keyword.get(opts, :orchestrator))

    case Plug.Conn.read_body(conn, length: 262_144, read_length: 262_144, read_timeout: 5_000) do
      {:ok, bytes, conn} ->
        conn |> Plug.Conn.assign(:linear_raw_body, bytes) |> SymphonyElixirWeb.LinearWebhookController.create(%{})

      {:more, _bytes, conn} ->
        Plug.Conn.send_resp(conn, 413, "Request too large")

      {:error, _reason} ->
        Plug.Conn.send_resp(conn, 400, "Invalid request")
    end
  end

  def call(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "Not found")
end
