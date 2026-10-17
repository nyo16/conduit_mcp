defmodule ConduitMcp.Protocol.Modern do
  @moduledoc """
  Shapes a neutral handler result (`t:ConduitMcp.Handler.result/0`) into the
  JSON-RPC 2.0 response map of the modern (`2026-07-28`) protocol era, and
  maps modern errors to their HTTP status.

  ## Results

  Every successful result gets:

    * `"resultType" => "complete"`;
    * `_meta["io.modelcontextprotocol/serverInfo"]` — the server's name and
      version. Request-scoped `io.modelcontextprotocol/*` keys a method
      echoed from the request's `_meta` (protocol version, client
      capabilities, client info, log level) are removed from the result's
      `_meta`; other keys, such as a `progressToken`, are kept;
    * on the six cacheable results — `server/discover`, `tools/list`,
      `prompts/list`, `resources/list`, `resources/templates/list` and
      `resources/read` — `"ttlMs"` and `"cacheScope"`.

  Cache hints default to the application environment:

      config :conduit_mcp, cache_ttl_ms: 60_000, cache_scope: :private

  (`:private` or `:public`; defaults `60_000` and `:private`). A caller can
  override them per response with the `:cache` option of `to_response/4`.
  `{:ok, result}` is always a complete result.

  ## Input required

  `{:input_required, input_requests, request_state}` — produced by the
  handler once it has gated the input requests and sealed the callback's
  state into the `request_state` token — becomes an `InputRequiredResult`:
  `"resultType" => "input_required"`, `"inputRequests"`, `"requestState"`
  and the `serverInfo` `_meta`, but never `ttlMs`/`cacheScope`, on any
  method (an interim result must not be cached).

  ## Errors

  Error responses keep the legacy shape. One code is rewritten: `-32002`
  (resource not found in `2025-11-25` and earlier, and the code
  `handle_read_resource/2` callbacks return) becomes `-32602`, because
  `2026-07-28` forbids emitting `-32002`.

  ## HTTP status

  `http_status/1` maps a response (or bare code) produced while running a
  method: `-32020`/`-32021`/`-32022` ⇒ 400, `-32601` ⇒ 404, everything else
  (results, and errors such as an unknown tool's `-32602`) ⇒ 200. A
  rejection raised *before* the method runs — any `ConduitMcp.Era.classify/2`
  error, including its `-32602` for invalid `_meta`, and any
  `ConduitMcp.Plugs.HeaderValidation` error — is always 400.
  """

  alias ConduitMcp.Errors
  alias ConduitMcp.Protocol

  @cacheable_methods [
    "server/discover",
    "tools/list",
    "prompts/list",
    "resources/list",
    "resources/templates/list",
    "resources/read"
  ]

  @server_info_key "io.modelcontextprotocol/serverInfo"

  @request_meta_keys [
    "io.modelcontextprotocol/protocolVersion",
    "io.modelcontextprotocol/clientCapabilities",
    "io.modelcontextprotocol/clientInfo",
    "io.modelcontextprotocol/logLevel"
  ]

  @default_ttl_ms 60_000
  @default_scope :private

  @typedoc "Cache hints: a TTL in milliseconds and a scope."
  @type cache :: %{ttl_ms: non_neg_integer(), scope: :private | :public}

  @typedoc """
  Options for `to_response/4`:

    * `:server_info` — `%{"name" => ..., "version" => ...}`, put into the
      result's `_meta`; omitted when absent.
    * `:cache` — a `t:cache/0` overriding the configured default for this
      response (cacheable methods only).
  """
  @type option :: {:server_info, map()} | {:cache, cache()}

  @doc """
  Builds the modern JSON-RPC response to `method` request `id`.

  ## Examples

      iex> ConduitMcp.Protocol.Modern.to_response(1, "tools/call", {:ok, %{"content" => []}})
      %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"content" => [], "resultType" => "complete"}}

      iex> ConduitMcp.Protocol.Modern.to_response(1, "resources/read", {:error, -32002, "Resource not found", nil})
      %{"jsonrpc" => "2.0", "id" => 1, "error" => %{"code" => -32602, "message" => "Resource not found"}}
  """
  @spec to_response(
          Protocol.json_rpc_id() | nil,
          String.t() | nil,
          ConduitMcp.Handler.result(),
          [option()]
        ) :: map()
  def to_response(id, method, result, opts \\ [])

  def to_response(id, method, {:ok, result}, opts) do
    result =
      result
      |> Map.put("resultType", "complete")
      |> put_cache_hints(method, Keyword.get(opts, :cache))
      |> put_meta(Keyword.get(opts, :server_info))

    Protocol.success_response(id, result)
  end

  def to_response(id, _method, {:input_required, input_requests, request_state}, opts)
      when is_map(input_requests) and is_binary(request_state) do
    result =
      %{
        "resultType" => "input_required",
        "inputRequests" => input_requests,
        "requestState" => request_state
      }
      |> put_meta(Keyword.get(opts, :server_info))

    Protocol.success_response(id, result)
  end

  def to_response(id, _method, {:error, code, message, data}, _opts) do
    code = modern_code(code)

    if is_nil(data),
      do: Protocol.error_response(id, code, message),
      else: Protocol.error_response(id, code, message, data)
  end

  @doc """
  The HTTP status for a modern response, or for an error code, produced while
  running a method (see the moduledoc for rejections raised before it).
  """
  @spec http_status(map() | integer()) :: 200 | 400 | 404
  def http_status(%{"error" => %{"code" => code}}), do: http_status(code)
  def http_status(%{}), do: 200

  def http_status(code) when is_integer(code) do
    cond do
      code in [
        Errors.header_mismatch(),
        Errors.missing_required_client_capability(),
        Errors.unsupported_protocol_version()
      ] ->
        400

      code == Errors.method_not_found() ->
        404

      true ->
        200
    end
  end

  @doc """
  The methods whose complete results carry `ttlMs` and `cacheScope`.
  """
  @spec cacheable_methods() :: [String.t()]
  def cacheable_methods, do: @cacheable_methods

  @doc """
  The configured default cache hints (`:cache_ttl_ms`, `:cache_scope`).
  """
  @spec default_cache() :: cache()
  def default_cache do
    %{
      ttl_ms: Application.get_env(:conduit_mcp, :cache_ttl_ms, @default_ttl_ms),
      scope: Application.get_env(:conduit_mcp, :cache_scope, @default_scope)
    }
  end

  @doc """
  The modern era's "resource not found" code, `-32602`.
  """
  @spec resource_not_found() :: integer()
  def resource_not_found, do: Errors.invalid_params()

  defp modern_code(code) do
    if code == Protocol.Legacy.resource_not_found(), do: resource_not_found(), else: code
  end

  defp put_cache_hints(result, method, cache) when method in @cacheable_methods do
    %{ttl_ms: ttl_ms, scope: scope} = cache || default_cache()

    result
    |> Map.put("ttlMs", ttl_ms)
    |> Map.put("cacheScope", scope_string(scope))
  end

  defp put_cache_hints(result, _method, _cache), do: result

  defp scope_string(scope) when scope in [:private, "private"], do: "private"
  defp scope_string(scope) when scope in [:public, "public"], do: "public"

  defp scope_string(scope) do
    raise ArgumentError,
          "cache scope must be :private or :public (config :conduit_mcp, :cache_scope); " <>
            "got #{inspect(scope)}"
  end

  defp put_meta(result, server_info) do
    meta =
      case Map.get(result, "_meta") do
        meta when is_map(meta) -> Map.drop(meta, @request_meta_keys)
        _ -> %{}
      end

    meta = if server_info, do: Map.put(meta, @server_info_key, server_info), else: meta

    if meta == %{}, do: Map.delete(result, "_meta"), else: Map.put(result, "_meta", meta)
  end
end
