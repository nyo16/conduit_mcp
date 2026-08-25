defmodule ConduitMcp.Plugs.OriginValidation do
  @moduledoc """
  Plug that validates the `Origin` request header against an allowlist.

  Reads the allowlist from `conn.private[:allowed_origins]`. Accepted shapes:

  | `:allowed_origins` | Behaviour |
  |---|---|
  | `nil` (unset) | **Fails closed**: any request carrying an `Origin` is rejected |
  | `"*"` | All origins allowed — the explicit opt-out |
  | a list of strings | Only those origins are allowed |
  | a bare string | Only that origin is allowed |
  | a `Regex` | Origins matching the pattern are allowed |

  Other rules:

  - OPTIONS requests always pass (CORS preflight; the router answers them
    before any MCP handler runs)
  - Requests **without** an `Origin` header pass — see below
  - Disallowed origins receive a 403 JSON error response

  ## Why an unset allowlist fails closed

  It used to log a startup warning and allow everything. A warning does not
  stop a request: a page on `https://evil.example` could POST to a loopback
  MCP server and, because the response also carried `access-control-allow-origin: *`,
  read the reply. Defaulting to "no browser origin is trusted" is the only
  default that is safe for a server bound to loopback on a developer machine.

  Pass `allowed_origins: "*"` to restore the old behaviour explicitly.

  ## Why missing `Origin` still passes — and what that does not cover

  Native MCP clients (Claude Desktop, IDEs, CLIs) are not browsers and do not
  send an `Origin` header. Rejecting header-less requests would break every
  legitimate non-browser client, so they pass.

  > #### Origin validation is not DNS-rebinding protection {: .warning}
  >
  > After a successful DNS rebind the attacker's page is, from the browser's
  > point of view, *same-origin* with your server — and browsers attach no
  > `Origin` to a same-origin `GET`. Such a request therefore takes the
  > header-less path above and this plug never runs its allowlist. What Origin
  > validation *does* cover is the cross-origin case: a page on another origin
  > cannot POST to your server, because a cross-origin POST always carries
  > `Origin`.
  >
  > The control that covers rebinding is `Host` validation, which this library
  > does not implement. For a server a browser could reach — anything bound to
  > loopback on a developer machine — put it behind a proxy that rejects
  > unexpected `Host` values, or require authentication so the rebound request
  > has no credential. This matters most for
  > `ConduitMcp.Transport.SSE`'s `GET /sse`, which is a readable stream.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts), do: conn

  def call(conn, _opts) do
    allowed = conn.private[:allowed_origins]

    if allowed == "*" do
      conn
    else
      check_origin(conn, allowed, get_req_header(conn, "origin") |> List.first())
    end
  end

  # No Origin header: not a browser request, nothing to validate.
  defp check_origin(conn, _allowed, nil), do: conn

  defp check_origin(conn, allowed, origin) do
    if origin_allowed?(allowed, origin) do
      conn
    else
      Logger.warning("Blocked request from disallowed origin", origin: origin)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, JSON.encode!(%{"error" => "Origin not allowed"}))
      |> halt()
    end
  end

  # Unset: no browser origin is trusted.
  defp origin_allowed?(nil, _origin), do: false
  defp origin_allowed?(allowed, origin) when is_list(allowed), do: origin in allowed
  defp origin_allowed?(allowed, origin) when is_binary(allowed), do: allowed == origin
  defp origin_allowed?(%Regex{} = allowed, origin), do: Regex.match?(allowed, origin)

  defp origin_allowed?(allowed, _origin) do
    Logger.error(
      "ConduitMcp.Plugs.OriginValidation: unsupported :allowed_origins value " <>
        "#{inspect(allowed)}. Expected a list of strings, a string, a Regex, or \"*\"; " <>
        "failing closed."
    )

    false
  end
end
