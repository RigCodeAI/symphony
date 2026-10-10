defmodule SymphonyElixir.LinearWebhookServer do
  @moduledoc "Optional listener exposing only the signed native Linear webhook."

  alias SymphonyElixir.Config

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    server = Config.settings!().server

    case Keyword.get(opts, :port, server.webhook_port) do
      port when is_integer(port) and port >= 0 ->
        host = Keyword.get(opts, :host, server.webhook_host)

        with {:ok, ip} <- :inet.parse_address(String.to_charlist(host)) do
          plug_opts = Keyword.take(opts, [:orchestrator])
          Bandit.start_link(plug: {SymphonyElixirWeb.LinearWebhookPlug, plug_opts}, ip: ip, port: port)
        end

      _ ->
        :ignore
    end
  end
end
