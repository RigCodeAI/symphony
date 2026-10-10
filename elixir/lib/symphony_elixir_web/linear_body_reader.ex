defmodule SymphonyElixirWeb.LinearBodyReader do
  @moduledoc "Retains the exact signed webhook bytes before JSON parsing."

  @spec read_body(Plug.Conn.t(), keyword()) :: {:ok | :more, binary(), Plug.Conn.t()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, bytes, conn} when status in [:ok, :more] ->
        if conn.request_path == "/hooks/linear" do
          previous = conn.assigns[:linear_raw_body] || ""

          raw = append_raw(previous, bytes)

          {status, bytes, Plug.Conn.assign(conn, :linear_raw_body, raw)}
        else
          {status, bytes, conn}
        end
    end
  end

  defp append_raw(:oversized, _bytes), do: :oversized
  defp append_raw(previous, bytes) when byte_size(previous) + byte_size(bytes) <= 262_144, do: previous <> bytes
  defp append_raw(_previous, _bytes), do: :oversized
end
