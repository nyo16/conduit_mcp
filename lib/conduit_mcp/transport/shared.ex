defmodule ConduitMcp.Transport.Shared do
  @moduledoc """
  The single implementation of everything `ConduitMcp.Transport.StreamableHTTP`
  and `ConduitMcp.Transport.SSE` have in common.

  The two transports used to carry ~120 lines of copy-pasted plumbing, and the
  copies diverged. Only StreamableHTTP knew about the `:oauth` auth strategy,
  so an SSE server configured with `strategy: :oauth` fell through to
  `ConduitMcp.Plugs.Auth`'s catch-all and returned a blanket 401 — plus a
  `Logger.error` — on *every* request. Two other features
  (`/.well-known/oauth-protected-resource` and the `mcp-protocol-version`
  header) existed on one transport purely because nobody copied them back.

  `use ConduitMcp.Transport.Shared` therefore generates, in both routers:

    * the `Plug.Router` pipeline up to the transport-specific plugs,
    * `init/1` and `call/2`,
    * the shared plug functions (`add_cors_headers`, `authenticate`,
      `rate_limit`, `message_rate_limit`),

  and `shared_routes/0` generates the shared routes (`options _`,
  `get "/health"`, `get "/.well-known/oauth-protected-resource"`, `match _`).
  No function body exists in both transports.

  ## Plugs are resolved once

  `init/1` resolves `:auth`, `:rate_limit` and `:message_rate_limit` into
  `{module, initialised_opts}` pairs, so `call/2` is `mod.call(conn, opts)`.
  Previously every plug's `init/1` ran on every request — including
  `ConduitMcp.Plugs.OAuth.init/1`, which is the only place an unusable
  configuration can be reported as a configuration error rather than a 401.

  ## Deliberate asymmetries

  Anything the two transports genuinely do differently is listed in their own
  moduledocs with a reason. Undocumented asymmetry is exactly what produced
  the `:oauth` bug.
  """

  require Logger

  alias ConduitMcp.Handler
  alias ConduitMcp.OptionalDeps
  alias ConduitMcp.Plugs
  alias ConduitMcp.Protocol
  alias ConduitMcp.Reflect

  import Plug.Conn

  @typedoc "A plug resolved at `init/1` time: the module and its initialised options."
  @type resolved_plug :: {module(), term()} | nil

  @doc """
  Generates the shared `Plug.Router` pipeline, `init/1`, `call/2` and the
  shared plug functions.

  Options:

    * `:extra_plugs` — plug names to insert between `:message_rate_limit` and
      `:dispatch` (StreamableHTTP uses this for `:validate_session`).
  """
  defmacro __using__(opts) do
    extra_plugs = Keyword.get(opts, :extra_plugs, [])

    quote do
      use Plug.Router

      require Logger

      alias ConduitMcp.Transport.Shared

      plug(Plug.Logger)
      plug(ConduitMcp.Plugs.SecurityHeaders)
      plug(ConduitMcp.Plugs.OriginValidation)
      plug(:add_cors_headers)
      plug(:match)
      plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, length: 1_000_000)
      plug(:authenticate)
      plug(:rate_limit)
      plug(:message_rate_limit)

      for extra <- unquote(extra_plugs) do
        plug(extra)
      end

      plug(:dispatch)

      @impl Plug
      def init(opts), do: Shared.init(opts, __MODULE__)

      @impl Plug
      def call(conn, opts) do
        conn
        |> Shared.put_private(opts, __transport_private__(opts))
        |> super(opts)
      end

      @doc false
      # Transport-specific `conn.private` entries merged on top of the shared
      # ones. Override to add your own.
      def __transport_private__(_opts), do: %{}

      defoverridable __transport_private__: 1

      defp add_cors_headers(conn, _opts), do: Shared.add_cors_headers(conn)
      defp authenticate(conn, _opts), do: Shared.authenticate(conn)
      defp rate_limit(conn, _opts), do: Shared.run_plug(conn, :rate_limit_plug)

      defp message_rate_limit(conn, _opts),
        do: Shared.run_plug(conn, :message_rate_limit_plug)
    end
  end

  @doc """
  Generates the routes both transports serve: the CORS preflight catch-all,
  `GET /health`, the RFC 9728 protected-resource metadata endpoint, and the
  404 catch-all.

  Call this **last** in the router — `match _` must be the final route.
  """
  defmacro shared_routes do
    quote do
      # CORS preflight. Terminates every OPTIONS in the router before any MCP
      # handler, so a preflight can never bypass auth.
      options _ do
        send_resp(var!(conn), 200, "")
      end

      get "/health" do
        ConduitMcp.Transport.Shared.send_json(var!(conn), 200, %{status: "ok"})
      end

      # OAuth Protected Resource Metadata (RFC 9728). Served by both
      # transports: a client that discovers the SSE endpoint needs the same
      # metadata to find the authorization server.
      get "/.well-known/oauth-protected-resource" do
        ConduitMcp.Transport.Shared.oauth_protected_resource(var!(conn))
      end

      match _ do
        send_resp(var!(conn), 404, "Not found")
      end
    end
  end

  # --- init/1 -----------------------------------------------------------

  @doc """
  Validates and resolves transport options once, at `init/1`.

  Returns the options with `:auth_config`, `:auth_plug`, `:rate_limit_plug`,
  `:message_rate_limit_plug` and `:shared_private` added.
  """
  @spec init(keyword(), module()) :: keyword()
  def init(opts, transport) do
    server_module = Keyword.get(opts, :server_module)

    if is_nil(server_module) do
      raise ArgumentError, "server_module is required"
    end

    validate_cors_origin!(Keyword.get(opts, :cors_origin))
    warn_if_origins_unset(opts, transport)

    endpoint_config = endpoint_config(server_module)
    auth_config = Keyword.get(opts, :auth) || Keyword.get(endpoint_config, :auth)

    rate_limit_config =
      Keyword.get(opts, :rate_limit) || Keyword.get(endpoint_config, :rate_limit)

    message_rate_limit_config =
      Keyword.get(opts, :message_rate_limit) ||
        Keyword.get(endpoint_config, :message_rate_limit)

    opts
    |> Keyword.put(:auth_config, auth_config)
    |> Keyword.put(:auth_plug, resolve_auth_plug(auth_config))
    |> Keyword.put(:rate_limit_plug, resolve_plug(Plugs.RateLimit, rate_limit_config))
    |> Keyword.put(
      :message_rate_limit_plug,
      resolve_plug(Plugs.MessageRateLimit, message_rate_limit_config)
    )
    |> then(&Keyword.put(&1, :shared_private, shared_private(&1, endpoint_config)))
  end

  # `:allowed_origins` accepts a *list* and is documented two bullets above
  # `:cors_origin` in both transports, so passing a list here is a natural
  # mistake. `put_resp_header/3` is guarded on a binary value, so without this
  # the mistake is a FunctionClauseError on every request instead of a
  # configuration error at boot — which is the whole point of resolving
  # configuration in `init/1`.
  defp validate_cors_origin!(nil), do: :ok
  defp validate_cors_origin!(origin) when is_binary(origin), do: :ok

  defp validate_cors_origin!(origin) do
    raise ArgumentError,
          ":cors_origin must be a single header value (a string) or nil; got " <>
            "#{inspect(origin)}. Note that :allowed_origins — not :cors_origin — is the " <>
            "option that accepts a list."
  end

  @doc """
  Reads a `use ConduitMcp.Endpoint` server's compile-time config, which both
  transports use as defaults for options not passed explicitly.
  """
  @spec endpoint_config(module() | nil) :: keyword()
  def endpoint_config(nil), do: []

  def endpoint_config(server_module) do
    if Code.ensure_loaded?(server_module) and
         function_exported?(server_module, :__endpoint_config__, 0) do
      server_module.__endpoint_config__()
    else
      []
    end
  end

  @doc """
  Resolves an auth configuration into `{module, initialised_opts}`.

  `strategy: :oauth` needs `ConduitMcp.Plugs.OAuth`, which is compiled only
  when `:joken` was available when `:conduit_mcp` itself was built. When it is
  missing this raises `ConduitMcp.OptionalDependencyError` naming both the
  dependency and `mix deps.compile conduit_mcp --force`, rather than letting
  the request fall through to `ConduitMcp.Plugs.Auth`'s catch-all and 401.

  Returns `nil` when no auth is configured.
  """
  @spec resolve_auth_plug(keyword() | nil) :: resolved_plug()
  def resolve_auth_plug(nil), do: nil

  def resolve_auth_plug(auth_config) do
    if Keyword.get(auth_config, :strategy) == :oauth do
      mod = OptionalDeps.oauth_plug!()

      # apply/3 keeps the compiler from resolving the (conditionally
      # compiled) OAuth plug at compile time — a bare consumer build has
      # no such module and must not emit an undefined-function warning.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      {mod, apply(mod, :init, [auth_config])}
    else
      {Plugs.Auth, Plugs.Auth.init(auth_config)}
    end
  end

  @doc false
  @spec resolve_plug(module(), keyword() | nil) :: resolved_plug()
  def resolve_plug(_mod, nil), do: nil
  def resolve_plug(mod, config), do: {mod, mod.init(config)}

  @doc """
  Warns once per boot (from `init/1`) when no Origin policy was chosen at all.

  Pass `allowed_origins: "*"` to opt out explicitly.
  """
  @spec warn_if_origins_unset(keyword(), module()) :: :ok
  def warn_if_origins_unset(opts, transport) do
    unless Keyword.has_key?(opts, :allowed_origins) do
      Logger.warning(
        "#{inspect(transport)}: no :allowed_origins configured — every request " <>
          "carrying an Origin header will be rejected with 403. Set " <>
          "allowed_origins: [\"https://yourapp.example\"] per the MCP specification, " <>
          "or allowed_origins: \"*\" to allow all origins explicitly."
      )
    end

    :ok
  end

  defp shared_private(opts, endpoint_config) do
    %{
      server_module: Keyword.get(opts, :server_module),
      allowed_origins: Keyword.get(opts, :allowed_origins),
      cors_origin: Keyword.get(opts, :cors_origin),
      cors_methods: Keyword.get(opts, :cors_methods, "GET, POST, OPTIONS"),
      cors_headers: Keyword.get(opts, :cors_headers, "content-type, authorization"),
      auth_config: Keyword.get(opts, :auth_config),
      auth_plug: Keyword.get(opts, :auth_plug),
      rate_limit_plug: Keyword.get(opts, :rate_limit_plug),
      message_rate_limit_plug: Keyword.get(opts, :message_rate_limit_plug),
      server_name: Keyword.get(opts, :server_name) || Keyword.get(endpoint_config, :name),
      server_version: Keyword.get(opts, :server_version) || Keyword.get(endpoint_config, :version)
    }
  end

  # --- call/2 -----------------------------------------------------------

  @doc false
  @spec put_private(Plug.Conn.t(), keyword(), map()) :: Plug.Conn.t()
  def put_private(conn, opts, transport_private) do
    private = Map.merge(Keyword.fetch!(opts, :shared_private), transport_private)
    %{conn | private: Map.merge(conn.private, private)}
  end

  @doc false
  # CORS is **off by default**. `access-control-allow-origin: "*"` used to be
  # emitted on every response, which is what let a page on another origin
  # *read* the reply to a cross-origin POST — no DNS rebinding required, since
  # `options _` answers the preflight 200 and `ACAO: *` then authorises the
  # read. Set `cors_origin:` explicitly to opt in.
  @spec add_cors_headers(Plug.Conn.t()) :: Plug.Conn.t()
  def add_cors_headers(conn) do
    case conn.private[:cors_origin] do
      nil ->
        conn

      cors_origin ->
        conn
        |> put_resp_header("access-control-allow-origin", cors_origin)
        |> put_resp_header(
          "access-control-allow-methods",
          conn.private[:cors_methods] || "GET, POST, OPTIONS"
        )
        |> put_resp_header(
          "access-control-allow-headers",
          conn.private[:cors_headers] || "content-type, authorization"
        )
    end
  end

  @doc false
  # Runs a plug resolved at init/1, if one was configured.
  @spec run_plug(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  def run_plug(conn, key) do
    case conn.private[key] do
      nil -> conn
      {mod, plug_opts} -> mod.call(conn, plug_opts)
    end
  end

  @metadata_path [".well-known", "oauth-protected-resource"]

  @doc false
  # RFC 9728 requires the protected-resource metadata document to be publicly
  # reachable: it is what a client fetches *after* a 401 to discover the
  # authorization server. Running the auth plug over it would make discovery
  # depend on already being authenticated.
  @spec authenticate(Plug.Conn.t()) :: Plug.Conn.t()
  def authenticate(%Plug.Conn{path_info: @metadata_path} = conn), do: conn
  def authenticate(conn), do: run_plug(conn, :auth_plug)

  # --- routes -----------------------------------------------------------

  @doc false
  @spec oauth_protected_resource(Plug.Conn.t()) :: Plug.Conn.t()
  def oauth_protected_resource(conn) do
    auth_config = conn.private[:auth_config]

    if is_list(auth_config) and auth_config != [] and
         Keyword.get(auth_config, :strategy) == :oauth do
      send_json(conn, 200, ConduitMcp.OAuth.ResourceMetadata.build(auth_config))
    else
      send_resp(conn, 404, "Not found")
    end
  end

  @doc """
  The shared JSON-RPC POST body dispatch.

  `prepare` runs after a successful response map is produced and before it is
  sent, so a transport can attach transport-specific headers or state. It
  returns `{:ok, conn}` to continue, or `{:error, conn}` when it has already
  sent a response of its own.
  """
  @spec dispatch_post(Plug.Conn.t(), (Plug.Conn.t(), map() ->
                                        {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t()})) ::
          Plug.Conn.t()
  def dispatch_post(conn, prepare \\ fn conn, _response -> {:ok, conn} end) do
    case conn.body_params do
      params when is_map(params) ->
        Logger.debug("Received request",
          method: Reflect.text(params["method"]),
          id: Reflect.text(params["id"], 64)
        )

        case Handler.handle_request(params, conn.private[:server_module], conn) do
          :ok ->
            # A notification: nothing to return.
            send_resp(conn, 204, "")

          response_map when is_map(response_map) ->
            conn = put_protocol_version_header(conn)

            case prepare.(conn, response_map) do
              {:ok, conn} -> send_json(conn, 200, response_map)
              {:error, conn} -> conn
            end
        end

      _ ->
        send_json(
          conn,
          400,
          Protocol.error_response(
            nil,
            Protocol.invalid_request(),
            "Request body must be valid JSON"
          )
        )
    end
  end

  @doc false
  @spec put_protocol_version_header(Plug.Conn.t()) :: Plug.Conn.t()
  def put_protocol_version_header(conn) do
    put_resp_header(conn, "mcp-protocol-version", Protocol.protocol_version())
  end

  @doc false
  @spec send_json(Plug.Conn.t(), non_neg_integer(), term()) :: Plug.Conn.t()
  def send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
