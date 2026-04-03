defmodule ConduitMcp.Plugs.OriginValidation do
  @moduledoc """
  Plug that validates the `Origin` request header against an allowlist.

  Reads the allowlist from `conn.private[:allowed_origins]`. Behavior:

  - `nil` or `"*"` — no restriction, all origins allowed
  - A list of strings — only those origins are allowed
  - OPTIONS requests always pass (CORS preflight)
  - Requests without an `Origin` header pass (browser-less clients don't send it)
  - Disallowed origins receive a 403 JSON error response
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
