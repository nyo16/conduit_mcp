defmodule ConduitMcp.Plugs.SecurityHeaders do
  @moduledoc """
  Plug that adds standard security response headers to all responses.

  Sets the following headers:
  - `X-Content-Type-Options: nosniff` — prevents MIME-type sniffing
  - `X-Frame-Options: DENY` — prevents clickjacking via iframes
  - `Cache-Control: no-store` — prevents caching of API responses

  `Strict-Transport-Security` is intentionally omitted because this library
  may run behind a reverse proxy that handles TLS. Add it in your own plug
  pipeline if needed.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("cache-control", "no-store")
  end
end
