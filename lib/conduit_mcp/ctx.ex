defmodule ConduitMcp.Ctx do
  @moduledoc """
  The per-request context: which protocol era a request belongs to and what
  it declared about itself.

  `ConduitMcp.Era.classify/2` builds it once per request; the handler stores
  it in `conn.private[:mcp_ctx]` before any callback runs, so callbacks keep
  receiving a `Plug.Conn` and read the context with `from_conn/1`:

      def handle_call_tool(conn, "whoami", _params) do
        case ConduitMcp.Ctx.from_conn(conn) do
          %ConduitMcp.Ctx{era: :modern, client_info: info} -> text(inspect(info))
          _ -> text("legacy client")
        end
      end

  ## Fields

    * `:era` — `:modern` (`2026-07-28`, per-request `_meta`) or `:legacy`
      (`initialize`-negotiated).
    * `:version` — the modern request's `_meta` protocol version; for a
      legacy request, the version negotiated into its session, if any.
      `nil` for an era-exempt `server/discover` sent without `_meta`.
    * `:client_info` — the modern `io.modelcontextprotocol/clientInfo`
      (self-reported: never base a security decision on it).
    * `:client_capabilities` — the modern per-request
      `io.modelcontextprotocol/clientCapabilities`; `%{}` for legacy.
    * `:extensions` — `client_capabilities["extensions"]`, or `%{}`.
    * `:log_level` — the modern `io.modelcontextprotocol/logLevel`. Without
      it the server must not send `notifications/message` for the request;
      see `log?/2`.
    * `:principal` — `ConduitMcp.Principal.get/1` of the request.
    * `:session` — legacy only: `%{id: session_id, data: session_data}` when
      the transport resolved an `Mcp-Session-Id`; always `nil` for modern.
    * `:conn` — the request's `Plug.Conn`.
    * `:request_id` — the JSON-RPC id (`nil` for a notification).
    * `:server_info` — the `%{"name" => ..., "version" => ...}` this server
      reports (from the transport's `:server_name` / `:server_version`, an
      Endpoint's `:name` / `:version`, or the library defaults).
    * `:traceparent`, `:tracestate`, `:baggage` — the W3C trace-context keys
      from a modern request's `_meta`, validated by `ConduitMcp.Era`:
      `traceparent` must be a well-formed 55-character value, `tracestate`
      and `baggage` at most 512 bytes of printable ASCII. Anything else is
      dropped (`nil`) rather than rejected.

  ## Never log or emit it whole

  `Inspect` omits `:conn`, `:principal` and `:session`, which carry
  credentials and identities. Telemetry metadata never contains a `Ctx`; the
  request event copies individual, already-validated fields instead.
  """

  @derive {Inspect, except: [:conn, :principal, :session]}
  defstruct era: :legacy,
            version: nil,
            client_info: nil,
            client_capabilities: %{},
            extensions: %{},
            log_level: nil,
            principal: nil,
            session: nil,
            conn: nil,
            request_id: nil,
            server_info: nil,
            traceparent: nil,
            tracestate: nil,
            baggage: nil

  @type era :: :modern | :legacy

  @type t :: %__MODULE__{
          era: era(),
          version: String.t() | nil,
          client_info: map() | nil,
          client_capabilities: map(),
          extensions: map(),
          log_level: String.t() | nil,
          principal: ConduitMcp.Principal.t() | nil,
          session: %{id: String.t(), data: map()} | nil,
          conn: Plug.Conn.t() | map() | nil,
          request_id: term(),
          server_info: %{required(String.t()) => String.t()} | nil,
          traceparent: String.t() | nil,
          tracestate: String.t() | nil,
          baggage: String.t() | nil
        }

  @private_key :mcp_ctx

  # MCP `LoggingLevel`, least to most severe (RFC 5424 order).
  @log_levels ~w(debug info notice warning error critical alert emergency)

  @doc """
  Stores `ctx` in `conn.private[:mcp_ctx]` and returns the conn.

  The stored copy has `:conn` cleared, so a conn never nests older versions of
  itself; `from_conn/1` puts the current conn back.
  """
  @spec put(Plug.Conn.t() | map(), t()) :: Plug.Conn.t() | map()
  def put(%{private: private} = conn, %__MODULE__{} = ctx) when is_map(private),
    do: %{conn | private: Map.put(private, @private_key, %{ctx | conn: nil})}

  def put(conn, %__MODULE__{}), do: conn

  @doc """
  The request's context, with `:conn` set to `conn`, or `nil` when no
  context has been stored on it.
  """
  @spec from_conn(Plug.Conn.t() | map()) :: t() | nil
  def from_conn(%{private: %{@private_key => %__MODULE__{} = ctx}} = conn),
    do: %{ctx | conn: conn}

  def from_conn(_conn), do: nil

  @doc """
  The server identity reported to clients: `%{"name" => ..., "version" => ...}`.

  Read from the transport-resolved `conn.private[:server_name]` /
  `[:server_version]`, defaulting to `"conduit-mcp"` and the library version.
  """
  @spec server_info(Plug.Conn.t() | map()) :: %{required(String.t()) => String.t()}
  def server_info(conn) do
    private =
      case conn do
        %{private: private} when is_map(private) -> private
        _ -> %{}
      end

    %{
      "name" => Map.get(private, :server_name) || "conduit-mcp",
      "version" =>
        Map.get(private, :server_version) || to_string(Application.spec(:conduit_mcp, :vsn))
    }
  end

  @doc """
  The valid MCP logging levels, least severe first.
  """
  @spec log_levels() :: [String.t()]
  def log_levels, do: @log_levels

  @doc """
  Whether a `notifications/message` at `level` may be sent for this request.

  Modern era: only when the request carried
  `io.modelcontextprotocol/logLevel` and `level` is at least that severe —
  the specification forbids log notifications for a request without it.
  Legacy era: always `true`; the legacy era sets its level once, through
  `logging/setLevel`, which the server's own callback handles.

  ## Examples

      iex> ctx = %ConduitMcp.Ctx{era: :modern, log_level: "warning"}
      iex> ConduitMcp.Ctx.log?(ctx, "error")
      true
      iex> ConduitMcp.Ctx.log?(ctx, "info")
      false
      iex> ConduitMcp.Ctx.log?(%ConduitMcp.Ctx{era: :modern}, "emergency")
      false
  """
  @spec log?(t(), String.t()) :: boolean()
  def log?(%__MODULE__{era: :legacy}, _level), do: true
  def log?(%__MODULE__{log_level: nil}, _level), do: false

  def log?(%__MODULE__{log_level: threshold}, level) do
    case {severity(level), severity(threshold)} do
      {nil, _} -> false
      {_, nil} -> false
      {wanted, floor} -> wanted >= floor
    end
  end

  defp severity(level), do: Enum.find_index(@log_levels, &(&1 == level))
end
