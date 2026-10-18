defmodule ConduitMcp.Era do
  @moduledoc """
  Classifies a decoded JSON-RPC request into a protocol era and builds its
  `ConduitMcp.Ctx`.

  Runs on the decoded body, so on HTTP it belongs after `Plug.Parsers`.

  ## Truth table

  `pv` is `params._meta["io.modelcontextprotocol/protocolVersion"]`, `caps`
  is `params._meta["io.modelcontextprotocol/clientCapabilities"]`.

  | `_meta` carries | method | result |
  |---|---|---|
  | `pv` and `caps` | any (including `initialize`) | `:modern` |
  | `pv` only, or `caps` only | any | `-32602`, HTTP 400 |
  | neither | `server/discover` | `:modern` (era-exempt; `version: nil`) |
  | neither | anything else | `:legacy` |

  The `Mcp-Session-Id` header never changes the era. A legacy request keeps
  the session the transport resolved (`Ctx.session`). A modern request that
  carries the header anyway (a "mixed" request) ignores the session — its
  context has no session and its conn drops the transport's session entries,
  so cancellation scoping falls back to the principal and then the client IP
  (`ConduitMcp.Cancellation.scope/1`) — except for one check: if the header
  names a live session that recorded a principal, the request's principal
  must be that principal, otherwise `-32600` (HTTP 400).

  ## Modern `_meta` validation

  A modern request is rejected with `-32602` (HTTP 400) when `pv` is not a
  string, `caps` is not an object, `io.modelcontextprotocol/clientInfo` is
  present but not an object, or `io.modelcontextprotocol/logLevel` is present
  but not an MCP logging level. Error messages name the key, never its value.

  Version *support* is not checked here: on HTTP the header/body version
  comparison (`-32020`) must come first, so `check_version/1` is a separate
  step run by `ConduitMcp.Plugs.HeaderValidation` and again by the modern
  handler.

  Every error from `classify/2` is a request-metadata rejection and is
  answered with HTTP 400.

  ## Trace context

  `traceparent`, `tracestate` and `baggage` are read from `_meta` in either
  era. An invalid value is dropped, never rejected: `traceparent` must be a
  W3C version-00-style value of exactly 55 characters with non-zero ids;
  `tracestate` and `baggage` must be at most 512 bytes of printable ASCII.
  """

  alias ConduitMcp.Ctx
  alias ConduitMcp.Errors
  alias ConduitMcp.Principal
  alias ConduitMcp.Protocol

  @protocol_version "io.modelcontextprotocol/protocolVersion"
  @client_capabilities "io.modelcontextprotocol/clientCapabilities"
  @client_info "io.modelcontextprotocol/clientInfo"
  @log_level "io.modelcontextprotocol/logLevel"

  @discover "server/discover"

  @trace_cap_bytes 512
  @traceparent ~r/\A[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}\z/
  @printable_ascii ~r/\A[\x20-\x7E]*\z/

  @typedoc "A rejection: the neutral error of `t:ConduitMcp.Handler.result/0`."
  @type error :: {:error, integer(), String.t(), map() | nil}

  @doc """
  Classifies `request` (a decoded JSON-RPC message) received on `conn`.

  Returns the request's context — with `conn` set to the conn the handler
  should use from here on — or a rejection (see the moduledoc).
  """
  @spec classify(map(), Plug.Conn.t() | map()) :: {:ok, Ctx.t()} | error()
  def classify(request, conn) when is_map(request) do
    meta = request_meta(request)

    case {Map.has_key?(meta, @protocol_version), Map.has_key?(meta, @client_capabilities)} do
      {true, true} ->
        modern(request, meta, conn)

      {true, false} ->
        meta_error("missing _meta \"#{@client_capabilities}\"")

      {false, true} ->
        meta_error("missing _meta \"#{@protocol_version}\"")

      {false, false} ->
        if Map.get(request, "method") == @discover,
          do: {:ok, exempt_discover(request, meta, conn)},
          else: {:ok, legacy(request, meta, conn)}
    end
  end

  @doc """
  Checks that a modern context's version is one this server implements.

  `:ok` for a legacy context and for an era-exempt `server/discover` sent
  without a version; otherwise `-32022` with `data` `%{"supported" => ...,
  "requested" => ...}` (HTTP 400).
  """
  @spec check_version(Ctx.t()) :: :ok | error()
  def check_version(%Ctx{era: :modern, version: version}) when is_binary(version) do
    if version in Protocol.modern_versions() do
      :ok
    else
      {:error, Errors.unsupported_protocol_version(), "Unsupported protocol version",
       %{
         "supported" => Protocol.supported_versions(),
         "requested" => ConduitMcp.Reflect.text(version, 40)
       }}
    end
  end

  def check_version(%Ctx{}), do: :ok

  # --- modern ------------------------------------------------------------

  defp modern(request, meta, conn) do
    with {:ok, version} <- fetch_string(meta, @protocol_version),
         {:ok, caps} <- fetch_object(meta, @client_capabilities),
         {:ok, info} <- fetch_optional_object(meta, @client_info),
         {:ok, level} <- fetch_log_level(meta),
         :ok <- check_session_binding(conn) do
      conn = drop_session(conn)

      ctx =
        base(request, meta, conn, :modern)
        |> Map.merge(%{
          version: version,
          client_info: info,
          client_capabilities: caps,
          extensions: extensions(caps),
          log_level: level
        })

      {:ok, ctx}
    end
  end

  defp exempt_discover(request, meta, conn),
    do: base(request, meta, drop_session(conn), :modern)

  defp fetch_string(meta, key) do
    case Map.fetch!(meta, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> meta_error("_meta \"#{key}\" must be a string")
    end
  end

  defp fetch_object(meta, key) do
    case Map.fetch!(meta, key) do
      value when is_map(value) -> {:ok, value}
      _ -> meta_error("_meta \"#{key}\" must be an object")
    end
  end

  defp fetch_optional_object(meta, key) do
    case Map.get(meta, key) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _ -> meta_error("_meta \"#{key}\" must be an object")
    end
  end

  defp fetch_log_level(meta) do
    case Map.get(meta, @log_level) do
      nil ->
        {:ok, nil}

      level ->
        if level in Ctx.log_levels(),
          do: {:ok, level},
          else:
            meta_error(
              "_meta \"#{@log_level}\" must be one of #{Enum.join(Ctx.log_levels(), ", ")}"
            )
    end
  end

  defp extensions(%{"extensions" => extensions}) when is_map(extensions), do: extensions
  defp extensions(_caps), do: %{}

  defp meta_error(message),
    do: {:error, Errors.invalid_params(), "Invalid request: " <> message, nil}

  # R12 / SV-8: the session is otherwise ignored on the modern path, but a
  # live session bound to a different principal must not be presentable
  # alongside modern `_meta`. A session that recorded no principal key (created
  # before principals were recorded) binds nothing.
  defp check_session_binding(%Plug.Conn{} = conn) do
    with [session_id | _] <- Plug.Conn.get_req_header(conn, "mcp-session-id"),
         {:ok, session_data} <- session_data(conn, session_id),
         true <- bound_to_other_principal?(session_data, conn) do
      {:error, Errors.invalid_request(),
       "Invalid request: Mcp-Session-Id is bound to a different principal", nil}
    else
      _ -> :ok
    end
  end

  defp check_session_binding(_conn), do: :ok

  @doc false
  # Whether `session_data` recorded a principal other than the caller's. A
  # session that recorded no principal key (created before principals were
  # recorded) binds nothing. Shared by the modern check above and the legacy
  # session lookup in `ConduitMcp.Transport.StreamableHTTP`.
  @spec bound_to_other_principal?(map(), Plug.Conn.t()) :: boolean()
  def bound_to_other_principal?(%{"principal" => bound}, conn), do: bound != Principal.id(conn)
  def bound_to_other_principal?(_session_data, _conn), do: false

  defp session_data(conn, session_id) do
    cond do
      conn.private[:mcp_session_id] == session_id and is_map(conn.private[:mcp_session_data]) ->
        {:ok, conn.private[:mcp_session_data]}

      is_list(conn.private[:session_config]) ->
        store = Keyword.get(conn.private[:session_config], :store, ConduitMcp.Session.EtsStore)
        ConduitMcp.Session.get(session_id, store)

      true ->
        :error
    end
  end

  defp drop_session(%{private: private} = conn) when is_map(private),
    do: %{conn | private: Map.drop(private, [:mcp_session_id, :mcp_session_data])}

  defp drop_session(conn), do: conn

  # --- legacy ------------------------------------------------------------

  defp legacy(request, meta, conn) do
    session = legacy_session(conn)

    %{
      base(request, meta, conn, :legacy)
      | session: session,
        version: session && session_version(session.data)
    }
  end

  defp legacy_session(%{private: %{mcp_session_id: id} = private}) when is_binary(id) do
    data = Map.get(private, :mcp_session_data)
    %{id: id, data: if(is_map(data), do: data, else: %{})}
  end

  defp legacy_session(_conn), do: nil

  defp session_version(%{"protocol_version" => version}) when is_binary(version), do: version
  defp session_version(_data), do: nil

  # --- shared ------------------------------------------------------------

  defp base(request, meta, conn, era) do
    %Ctx{
      era: era,
      principal: Principal.get(conn),
      conn: conn,
      request_id: Map.get(request, "id"),
      server_info: Ctx.server_info(conn),
      traceparent: traceparent(Map.get(meta, "traceparent")),
      tracestate: trace_text(Map.get(meta, "tracestate")),
      baggage: trace_text(Map.get(meta, "baggage"))
    }
  end

  defp request_meta(%{"params" => %{"_meta" => meta}}) when is_map(meta), do: meta
  defp request_meta(_request), do: %{}

  @doc """
  `value` when it is a well-formed W3C `traceparent` (version-00 style, 55
  characters, lowercase hex, non-zero ids, version not `ff`), else `nil`.
  The server reads `_meta.traceparent` through it, and the client checks
  what it propagates with it.

      iex> ConduitMcp.Era.traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
      "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

      iex> ConduitMcp.Era.traceparent("00-00000000000000000000000000000000-00f067aa0ba902b7-01")
      nil
  """
  @spec traceparent(term()) :: String.t() | nil
  def traceparent(value) when is_binary(value) and byte_size(value) == 55 do
    with true <- Regex.match?(@traceparent, value),
         [version, trace_id, parent_id, _flags] <- String.split(value, "-"),
         true <- version != "ff",
         true <- trace_id != String.duplicate("0", 32),
         true <- parent_id != String.duplicate("0", 16) do
      value
    else
      _ -> nil
    end
  end

  def traceparent(_value), do: nil

  defp trace_text(value) when is_binary(value) and byte_size(value) <= @trace_cap_bytes do
    if Regex.match?(@printable_ascii, value), do: value, else: nil
  end

  defp trace_text(_value), do: nil
end
