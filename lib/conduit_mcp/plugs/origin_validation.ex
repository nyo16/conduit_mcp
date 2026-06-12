defmodule ConduitMcp.Plugs.OriginValidation do
  @moduledoc """
  Plug that validates the `Origin` request header against an allowlist.

  Reads the allowlist from `conn.private[:allowed_origins]`. Behavior:

  - `nil` or `"*"` — no restriction, all origins allowed
  - A list of strings — only those origins are allowed
  - OPTIONS requests always pass (CORS preflight)
  - Requests without an `Origin` header pass (browser-less clients don't send it)
  - Disallowed origins receive a 403 JSON error response

  ## Why missing `Origin` passes

  Native MCP clients (Claude Desktop, IDEs, CLIs) are not browsers and do not
  send an `Origin` header. The attack this plug defends against — DNS
  rebinding — requires a browser, and browsers always attach `Origin` to
  cross-origin requests. Rejecting header-less requests would therefore break
  every legitimate non-browser client without adding protection.

  The MCP specification recommends Origin validation for any server a browser
  could reach (especially servers bound to loopback on developer machines).
  Transports log a startup warning when `:allowed_origins` is unset; pass
  `allowed_origins: "*"` to acknowledge and silence it.
  """

  @behaviour Plug
  import Plug.Conn
  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    allowed_origins = conn.private[:allowed_origins]

    cond do
      is_nil(allowed_origins) or allowed_origins == "*" ->
        conn

      conn.method == "OPTIONS" ->
        conn

      true ->
        origin = get_req_header(conn, "origin") |> List.first()

        cond do
          is_nil(origin) ->
            conn

          is_list(allowed_origins) and origin in allowed_origins ->
            conn

          true ->
            Logger.warning("Blocked request from disallowed origin", origin: origin)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(403, JSON.encode!(%{"error" => "Origin not allowed"}))
            |> halt()
        end
    end
  end
end
