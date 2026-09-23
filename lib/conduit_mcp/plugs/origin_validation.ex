defmodule ConduitMcp.Plugs.OriginValidation do
  @moduledoc """
  Plug that validates the `Origin` request header against an allowlist.

  Reads the allowlist from `conn.private[:allowed_origins]`. Accepted shapes:

  | `:allowed_origins` | Behaviour |
  |---|---|
  | `nil` (unset) | **Fails closed**: any request carrying an `Origin` is rejected |
  | `"*"` | All origins allowed — the explicit opt-out |
  | a list of strings | Only those origins are allowed (exact match) |
  | a bare string | Only that origin is allowed (exact match) |
  | a `Regex` | Origins matching the pattern are allowed |

  `ConduitMcp.Transport.StreamableHTTP` and `ConduitMcp.Transport.SSE` check
  the shape at `init/1` and raise `ArgumentError` for anything else. When this
  plug is used on its own, an unsupported value fails closed.

  > #### Anchor a `Regex` allowlist {: .warning}
  >
  > The pattern is tested with `Regex.match?/2`, which matches anywhere in the
  > origin. `~r/https:\\/\\/example\\.com/` therefore also allows
  > `https://example.com.evil.test`. Anchor both ends:
  > `~r/\\Ahttps:\\/\\/example\\.com\\z/`.

  Other rules:

  - OPTIONS requests always pass (CORS preflight; the router answers them
    before any MCP handler runs)
  - Requests **without** an `Origin` header pass — see below
  - Disallowed origins receive a 403 JSON error response

  ## Why an unset allowlist fails closed

  A warning does not stop a request: a page on `https://evil.example` could
  POST to a loopback MCP server and, if the response carried
  `access-control-allow-origin: *`, read the reply. "No browser origin is
  trusted" is the only default that is safe for a server bound to loopback on
  a developer machine.

  Pass `allowed_origins: "*"` to allow every origin explicitly.

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

  # Unsupported shape. The transports reject it in `init/1`; a standalone use
  # of this plug fails closed.
  defp origin_allowed?(_allowed, _origin), do: false
end
