defmodule ConduitMcp.Client.Transport.StreamableHTTP do
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.OAuth
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.Telemetry
  alias ConduitMcp.Client.URLPolicy
  alias ConduitMcp.Headers
  alias ConduitMcp.OptionalDeps

  require Logger

  @max_bytes 8 * 1024 * 1024

  # Headers the transport owns; `:headers` may not set them.
  @reserved_headers ~w(accept accept-encoding authorization connection content-length
                       content-type host last-event-id mcp-method mcp-name
                       mcp-protocol-version mcp-session-id te transfer-encoding upgrade)

  @protocol_version "io.modelcontextprotocol/protocolVersion"

  # RFC 9110 field-name `tchar`s (names are lowercased first).
  @tchars ~c"!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyz"

  @schema NimbleOptions.new!(
            url: [
              type: {:custom, __MODULE__, :validate_url, []},
              required: true,
              doc: """
              The server's MCP endpoint, an absolute `http` or `https` URL
              (no user info, no fragment). Every request is POSTed to it.
              """
            ],
            server_url_policy: [
              type: {:in, [:any, :public_only]},
              default: :any,
              doc: """
              `:public_only` applies `ConduitMcp.Client.URLPolicy` to the
              URL before every request, in the request's own process:
              `https` only, and the host is resolved (A and AAAA) and
              refused if any address is private, loopback, link-local or
              otherwise internal (unless `:allow_private` admits it). The
              request then connects to the first vetted address - the name
              is never resolved a second time, so a DNS answer that changes
              between the check and the connect (rebinding) cannot redirect
              it - with TLS SNI, certificate verification and the `Host`
              header all bound to the URL's host name. Such connections
              come from pools the transport starts in the Finch instance
              (yours with `:finch`), one per vetted address, configured by
              `:pool_size` and `:transport_opts`. Refused together with
              `:insecure_skip_tls_verify`. For a URL that comes from end
              users rather than operator configuration. `:any` trusts the
              URL and lets Finch resolve it.
              """
            ],
            allow_private: [
              type: {:list, :any},
              default: [],
              doc: "CIDRs that `server_url_policy: :public_only` admits anyway."
            ],
            resolver: [
              type: {:or, [{:fun, 1}, nil]},
              default: nil,
              doc: """
              The DNS resolver `server_url_policy: :public_only` uses, a
              `t:ConduitMcp.Client.URLPolicy.resolver/0`; called in the
              request's process, never the connection. Default: the system
              resolver.
              """
            ],
            headers: [
              type: {:custom, __MODULE__, :validate_headers, []},
              default: [],
              doc: """
              Extra headers for every request, as `{name, value}` pairs; a
              value may be a `ConduitMcp.Client.Secret`. Headers the
              transport sets itself (`accept`, `authorization`,
              `content-type`, `mcp-*`, `last-event-id`, hop-by-hop ones) are
              refused: use `:auth` for credentials.
              """
            ],
            auth: [
              type: {:custom, __MODULE__, :validate_auth, []},
              default: nil,
              doc: """
              Credentials for every request: `{:bearer, token}` (a string or
              a `ConduitMcp.Client.Secret`); a one-arity function called
              in the request's own process before each request with
              `%{url: url, method: method}` and returning `{:ok, token}`,
              `{:ok, nil}` (no credentials) or `{:error, reason}` (the
              request fails with `kind: :auth`); `{:oauth, opts}` for the
              OAuth 2.1 authorization-code flow, or `{:client_credentials,
              opts}` for machine-to-machine OAuth (see
              `ConduitMcp.Client.OAuth` and `ConduitMcp.Client.OAuth.Config`).
              Never sent over `http` to a host other than loopback: such a
              configuration raises.
              """
            ],
            credential_id: [
              type: :any,
              default: nil,
              doc: """
              With an `:auth` function only: any term naming whose tokens
              the function returns (a user id, a service name). Results the
              server marks `cacheScope: "private"` are cached for this
              identity (HT-11, see `ConduitMcp.Client.Cache`). Without it,
              the function may return anyone's token from one request to
              the next, so private results fetched with it are never served
              from the cache.
              """
            ],
            finch: [
              type: {:or, [:atom, nil]},
              default: nil,
              doc: """
              The name of a `Finch` pool you started. Default: a pool the
              client starts under its own supervisor (HTTP/1, `:pool_size`
              connections, TLS peer verification against the system CA
              store), named from a hash of the client's name. Give the
              library's pool to no other code.
              """
            ],
            pool_size: [
              type: :pos_integer,
              default: 100,
              doc: """
              Connections in the library-started pool. Each open event
              stream (a streamed response, a listen) holds one.
              """
            ],
            transport_opts: [
              type: :keyword_list,
              default: [],
              doc: """
              TLS options for the library-started pool, and with
              `server_url_policy: :public_only` for the pinned pools (Mint
              `:transport_opts`, for example `cacertfile:`). Anything that
              turns certificate verification off (`verify:` other than
              `:verify_peer`, or a `verify_fun:`) is refused; see
              `:insecure_skip_tls_verify`.
              """
            ],
            insecure_skip_tls_verify: [
              type: :boolean,
              default: false,
              doc: """
              Do not verify the server's TLS certificate. For local
              development only: a warning is logged whenever the transport
              starts. Needs the library-started pool, and is refused with
              `server_url_policy: :public_only`.
              """
            ],
            redirect: [
              type: {:in, [false, :same_origin]},
              default: false,
              doc: """
              `false` refuses every redirect (the request fails).
              `:same_origin` follows 307 and 308 redirects to the same
              scheme, host and port (at most 5), re-sending the request and
              its credentials; any other redirect still fails.
              """
            ],
            max_message_bytes: [
              type: :pos_integer,
              default: @max_bytes,
              doc: """
              The largest JSON body, and the largest event of an event
              stream (also each line of one), in bytes. More fails the
              request with `kind: :message_too_large`. Bodies are never
              decompressed: a response with a `content-encoding` fails.
              """
            ],
            request_timeout: [
              type: :pos_integer,
              default: 60_000,
              doc: """
              The total time, in milliseconds, of a request the connection
              sends on its own (handshake, health check). Caller requests
              are bounded by their own `:timeout` and `:max_total_timeout`.
              Bytes arriving slowly never extend either.
              """
            ],
            listen_idle_timeout: [
              type: :pos_integer,
              default: 120_000,
              doc: """
              Milliseconds a long-lived stream (a modern
              `subscriptions/listen`, the legacy GET stream) may stay silent
              - keep-alive comments count as traffic - before it is dropped
              and reopened.
              """
            ]
          )

  @moduledoc """
  A `ConduitMcp.Client.Transport` for the MCP Streamable HTTP transport, in
  both protocol eras. Needs the optional `:finch` dependency
  (`{:finch, "~> 0.21"}`); without it the client raises
  `ConduitMcp.OptionalDependencyError` when it starts.

      {ConduitMcp.Client,
       name: :docs,
       transport:
         {ConduitMcp.Client.Transport.StreamableHTTP,
          url: "https://mcp.example.com/mcp",
          auth: {:bearer, ConduitMcp.Client.Secret.new(System.fetch_env!("DOCS_TOKEN"))}}}

  `kind/0` is `:http`: era discovery follows the HTTP rules of
  `ConduitMcp.Client.Negotiation` and `:probe_timeout` defaults to 5 s.

  ## Processes

  The transport's callbacks run in the connection and never wait on the
  network. Each request runs in its own process, an *exchange*, under the
  client's `Task.Supervisor` and monitored by the connection: it POSTs the
  message, reads the answer (a JSON body or an event stream), sends the
  response straight to the caller and tells the connection it is done.
  Notifications and (legacy) server requests found on any stream go to
  the connection, which routes them. A legacy session also gets one
  *listener* process for the standalone GET stream.

  The HTTP pool is Finch: the one named by `:finch`, else one started under
  the client's supervisor (`child_specs/2`) and stopped with it. With
  `server_url_policy: :public_only` each request vets the URL in its own
  process and connects to the vetted address, through a pool per address
  started in that Finch instance (see the option, and the guide
  `client_security.md`).

  A bearer token must be visible ASCII (0x21-0x7E): one an `:auth`
  function or a token store returns with any other byte - a trailing
  newline, a control byte - fails the request with `kind: :auth, reason:
  :invalid_token`, an error that holds no part of the token.

  ## Requests

  Every POST carries `accept: application/json, text/event-stream`,
  `content-type: application/json` and `accept-encoding: identity`.

    * Modern (`2026-07-28`): `MCP-Protocol-Version` equal to the request's
      `_meta` version, `Mcp-Method`, `Mcp-Name` on `tools/call`,
      `resources/read`, `prompts/get` and the tasks extension's
      `tasks/get|update|cancel` (`ConduitMcp.Headers`), and the
      `Mcp-Param-*` headers `ConduitMcp.Client.call_tool/4` computes from
      the cached tool definition.
    * Legacy: `MCP-Protocol-Version` once negotiated, and `Mcp-Session-Id`
      once the server issued one. A session id must be 1 to 1024 visible
      ASCII characters (0x21-0x7E), else the handshake fails
      (`:invalid_session_id`); it is held as a `ConduitMcp.Client.Secret`.

  Answers: `202`/`204` complete a notification or response; a `401`, or a
  `403`, fails the request with `kind: :auth` and `data: %{status:,
  challenges:}` (`ConduitMcp.Client.OAuth.Challenge`); a `429` with
  `kind: :rate_limited` and `data: %{retry_after: seconds | nil}`; a 4xx
  carrying a JSON-RPC error is delivered as that error (so a modern `400`
  `-32022` or `404` `-32601` is a typed protocol error); a legacy `404` to a
  request that carried a session id means the session expired: the
  connection initializes a new session and sends that request once more.
  `5xx`, redirects (see `:redirect`) and network failures are `kind:
  :transport`.

  ## Streams

  An event-stream answer may carry notifications and, in the legacy era,
  server requests before the response. When a legacy stream ends early
  after an event id, the exchange waits the stream's `retry:` (default
  1 s, at most 30 s) and resumes it with a GET carrying `Last-Event-ID`,
  up to five times. A modern stream that ends without a response fails the
  request (`:stream_closed`); it is never replayed.

  The legacy standalone GET stream is opened once a session is ready; a
  `405`, or a `200` that is not an event stream, turns it off for the
  session. It is reopened (resuming with `Last-Event-ID`) when it drops.
  Modern `subscriptions/listen` streams are requests like any other (see
  `ConduitMcp.Client.Connection`); they get `:listen_idle_timeout` instead
  of a total deadline.

  ## Cancellation

  Modern: the exchange is stopped, which closes its socket - the server
  sees the disconnect as cancellation. Legacy: `notifications/cancelled` is
  POSTed first. `close/2` sends a legacy session's `DELETE` (bounded by
  1 s; a `405` is fine).

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @behaviour ConduitMcp.Client.Transport

  @impl true
  def kind, do: :http

  @impl true
  def validate_options(opts) do
    _http = OptionalDeps.finch!()

    with {:ok, opts} <- schema_validate(opts),
         :ok <- check_credentials(opts),
         :ok <- check_credential_id(opts),
         :ok <- check_tls(opts),
         :ok <- check_allow_private(opts) do
      oauth_config(opts)
    end
  end

  defp schema_validate(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, opts} -> {:ok, opts}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # `{:oauth, opts}` / `{:client_credentials, opts}` become `{:oauth,
  # %ConduitMcp.Client.OAuth.Config{}}` for this server URL. The OAuth
  # modules need Finch too; asking now fails at boot, never per request.
  defp oauth_config(opts) do
    case opts[:auth] do
      {:oauth, %OAuth.Config{}} ->
        {:ok, opts}

      {grant, oauth_opts} when grant in [:oauth, :client_credentials] ->
        _session = OptionalDeps.oauth_client!()

        oauth_opts = Keyword.put(oauth_opts, :server_url, opts[:url])

        oauth_opts =
          if grant == :client_credentials,
            do: Keyword.put(oauth_opts, :grant, :client_credentials),
            else: oauth_opts

        case OAuth.Config.new(oauth_opts) do
          {:ok, config} -> {:ok, Keyword.put(opts, :auth, {:oauth, config})}
          {:error, message} -> {:error, "invalid value for :auth option: " <> message}
        end

      _other ->
        {:ok, opts}
    end
  end

  # HT-8: credentials never cross a network in clear text.
  defp check_credentials(opts) do
    %URI{scheme: scheme, host: host} = URI.parse(opts[:url])

    if opts[:auth] != nil and scheme == "http" and not loopback?(host),
      do:
        {:error,
         "invalid value for :auth option: credentials are never sent over plain http " <>
           "to a host that is not loopback; use an https :url"},
      else: :ok
  end

  # Other `:auth` forms carry their own identity (`ConduitMcp.Client.Cache`).
  defp check_credential_id(opts) do
    if opts[:credential_id] != nil and not is_function(opts[:auth], 1),
      do: {:error, "invalid value for :credential_id option: it needs an :auth function"},
      else: :ok
  end

  # HT-8: verification is turned off by `:insecure_skip_tls_verify` only.
  # Every `:verify` entry is checked, not just the first: `:ssl` honours a
  # later duplicate. A `:verify_fun` replaces the certificate checks
  # altogether, so it is refused too.
  defp check_tls(opts) do
    tls = opts[:transport_opts]

    cond do
      Enum.any?(Keyword.get_values(tls, :verify), &(&1 != :verify_peer)) ->
        {:error,
         "invalid value for :transport_opts option: only verify: :verify_peer is accepted; " <>
           "set insecure_skip_tls_verify: true to disable certificate checks"}

      Keyword.has_key?(tls, :verify_fun) ->
        {:error,
         "invalid value for :transport_opts option: verify_fun is refused; " <>
           "set insecure_skip_tls_verify: true to disable certificate checks"}

      opts[:insecure_skip_tls_verify] and opts[:finch] != nil ->
        {:error,
         "invalid value for :insecure_skip_tls_verify option: it applies to the " <>
           "library-started pool only; configure TLS on your :finch pool instead"}

      # W-S4: the pinned connection is bound to the URL's host only by the
      # certificate check; without it any server at the vetted address (or
      # on the path to it) gets the request and its credentials.
      opts[:insecure_skip_tls_verify] and opts[:server_url_policy] == :public_only ->
        {:error,
         "invalid value for :insecure_skip_tls_verify option: it is refused with " <>
           "server_url_policy: :public_only, whose address pinning relies on " <>
           "certificate verification"}

      true ->
        :ok
    end
  end

  defp check_allow_private(opts) do
    Enum.each(opts[:allow_private], fn cidr ->
      if URLPolicy.parse_cidr(cidr) == :error do
        throw({:bad_cidr, cidr})
      end
    end)
  catch
    {:bad_cidr, cidr} -> {:error, "invalid value for :allow_private option: #{inspect(cidr)}"}
  end

  @doc false
  # Whether `host` (a URI host) is a loopback name or address.
  @spec loopback?(String.t() | nil) :: boolean()
  def loopback?(nil), do: false
  def loopback?("localhost"), do: true

  def loopback?(host) do
    case :inet.parse_strict_address(
           String.to_charlist(String.trim(host, "[") |> String.trim("]"))
         ) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  @doc """
  The children the client starts before its connection: the Finch pool,
  unless `:finch` names one of yours, and for `auth: {:oauth, ...}` without
  a `:store` the default in-memory `ConduitMcp.Client.OAuth.TokenStore.ETS`.
  """
  @impl true
  def child_specs(opts, key) do
    http = OptionalDeps.finch!()

    pool =
      if opts[:finch] do
        []
      else
        [
          http.child_spec(http.pool_name(key), opts[:url],
            size: opts[:pool_size],
            transport_opts: opts[:transport_opts],
            insecure: opts[:insecure_skip_tls_verify]
          )
        ]
      end

    pool ++ token_store(opts[:auth], key)
  end

  defp token_store({:oauth, %OAuth.Config{store: nil}}, key) do
    {module, store_opts} = OAuth.TokenStore.ETS.default(key)
    [Supervisor.child_spec({module, store_opts}, id: :oauth_token_store)]
  end

  defp token_store(_auth, _key), do: []

  @impl true
  def init(opts, %{owner: owner, task_sup: task_sup, key: key}) do
    http = OptionalDeps.finch!()

    case validate_options(opts) do
      {:ok, opts} ->
        if opts[:insecure_skip_tls_verify] do
          Logger.warning(
            "MCP client transport started with insecure_skip_tls_verify: true; " <>
              "the server's TLS certificate is not verified"
          )
        end

        {:ok,
         %{
           owner: owner,
           task_sup: task_sup,
           ref: make_ref(),
           http: http,
           exchange: Module.concat(__MODULE__, Exchange),
           listener_module: Module.concat(__MODULE__, Listener),
           opts: opts,
           # `{:oauth, %OAuth.Config{}}` until the connection hands over its
           # `ConduitMcp.Client.OAuth.Session` (`set_auth/2`)
           auth: opts[:auth],
           url: opts[:url],
           finch: opts[:finch] || http.pool_name(key),
           url_policy: url_policy(opts),
           era: nil,
           version: nil,
           session: nil,
           # xref => %{pid:, mon:, id:, era:}
           exchanges: %{},
           # monitor ref => xref
           mons: %{},
           # request id => xref
           by_id: %{},
           # requests whose session expired, waiting for the next session
           parked: [],
           # %{pid:, mon:, xref:} | :disabled | nil
           listener: nil
         }}

      {:error, message} ->
        {:error, {:invalid_options, message}}
    end
  end

  # `server_url_policy: :public_only`, computed once: what each request's
  # process needs to vet the URL and connect to the vetted address
  # (`ConduitMcp.Client.HTTP` starts one pinned pool per address).
  defp url_policy(opts) do
    if opts[:server_url_policy] == :public_only do
      check = [allow_private: opts[:allow_private]]
      check = if opts[:resolver], do: [{:resolver, opts[:resolver]} | check], else: check

      %{
        check: check,
        pool: [
          size: opts[:pool_size],
          transport_opts: Keyword.put_new(opts[:transport_opts], :verify, :verify_peer)
        ]
      }
    end
  end

  @impl true
  def connect(state) do
    send(
      state.owner,
      {__MODULE__, state.ref, nil, :events, [{:connected, %{origin: origin(state.url)}}]}
    )

    {:ok, state}
  end

  defp origin(url) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    default = URI.default_port(scheme)
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    if port == default, do: "#{scheme}://#{host}", else: "#{scheme}://#{host}:#{port}"
  end

  # --- requests ------------------------------------------------------------

  @impl true
  def request(state, message, reply_to, wire_opts) do
    case encode(message) do
      {:ok, body} ->
        mode = if Keyword.get(wire_opts, :listen, false), do: :listen, else: :request
        spec = spec(state, message, body, mode, reply_to, wire_opts)
        {:ok, message["id"], start(state, spec)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def notify(state, message), do: post(state, message)

  @impl true
  def respond(state, message), do: post(state, message)

  defp post(state, message) do
    case encode(message) do
      {:ok, body} -> {:ok, start(state, spec(state, message, body, :post, nil, []))}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp encode(message) do
    {:ok, JSON.encode!(message)}
  rescue
    _error in [Protocol.UndefinedError, ArgumentError] -> {:error, :unencodable}
  end

  defp spec(state, message, body, mode, reply_to, wire_opts) do
    method = message["method"]
    params = message["params"] || %{}
    era = message_era(params)
    session = if era == :legacy and method != "initialize", do: state.session

    %{
      owner: state.owner,
      tag: __MODULE__,
      tref: state.ref,
      xref: nil,
      http: state.http,
      finch: state.finch,
      url: state.url,
      mode: mode,
      id: message["id"],
      method: method,
      message: message,
      body: body,
      reply_to: reply_to,
      era: era,
      session: session,
      capture_session?: method == "initialize",
      resubmitted?: false,
      relayed?: false,
      probe?: Keyword.get(wire_opts, :probe, false),
      headers: headers(state, method, params, era, session, wire_opts),
      auth: state.auth,
      redirect: state.opts[:redirect],
      url_policy: state.url_policy,
      max_bytes: state.opts[:max_message_bytes],
      deadline: deadline(state, mode, wire_opts),
      idle_timeout: if(mode == :listen, do: state.opts[:listen_idle_timeout], else: :infinity),
      version: state.version
    }
  end

  defp message_era(%{"_meta" => %{@protocol_version => version}}) when is_binary(version),
    do: :modern

  defp message_era(_params), do: :legacy

  defp headers(state, method, params, era, session, wire_opts) do
    base = [
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ]

    base ++ era_headers(state, method, params, era, session, wire_opts) ++ state.opts[:headers]
  end

  defp era_headers(_state, method, params, :modern, _session, wire_opts) do
    version = get_in(params, ["_meta", @protocol_version])

    [{"mcp-protocol-version", version}, Headers.method_header(method)] ++
      List.wrap(Headers.name_header(method, params)) ++
      Keyword.get(wire_opts, :headers, [])
  end

  defp era_headers(state, method, _params, :legacy, session, _wire_opts),
    do: legacy_headers(state, method, session)

  @doc false
  # The legacy session headers (also used by the GET stream and DELETE).
  @spec legacy_headers(map(), String.t() | nil, Secret.t() | nil) :: [{String.t(), term()}]
  def legacy_headers(state, method, session) do
    version =
      if state.version != nil and method != "initialize",
        do: [{"mcp-protocol-version", state.version}],
        else: []

    sid = if session, do: [{"mcp-session-id", session}], else: []
    version ++ sid
  end

  # The connection's own deadline cancels caller requests; this backstop
  # bounds an exchange the connection lost track of. Listens have none.
  defp deadline(_state, :listen, _wire_opts), do: :infinity

  defp deadline(state, _mode, wire_opts) do
    case Keyword.get(wire_opts, :max_deadline) do
      at when is_integer(at) -> at + 1_000
      nil -> System.monotonic_time(:millisecond) + state.opts[:request_timeout]
    end
  end

  defp start(state, spec) do
    xref = make_ref()
    spec = %{spec | xref: xref}
    exchange = state.exchange
    metadata = Telemetry.inherited_logger_metadata()

    run = fn ->
      Logger.metadata(metadata)
      exchange.run(spec)
    end

    case Task.Supervisor.start_child(state.task_sup, run) do
      {:ok, pid} ->
        mon = Process.monitor(pid)
        entry = %{pid: pid, mon: mon, id: spec.id, era: spec.era, mode: spec.mode}

        %{
          state
          | exchanges: Map.put(state.exchanges, xref, entry),
            mons: Map.put(state.mons, mon, xref),
            by_id:
              if(spec.mode == :post, do: state.by_id, else: Map.put(state.by_id, spec.id, xref))
        }

      {:error, reason} ->
        # The task supervisor is shutting down with the client.
        send(state.owner, {__MODULE__, state.ref, nil, :events, failure(spec, reason)})
        state
    end
  end

  defp failure(%{mode: :post}, _reason), do: []

  defp failure(spec, reason),
    do: [{:exchange_done, spec.id, {:error, {:transport_error, {:not_started, reason}}}}]

  # --- cancellation ----------------------------------------------------------

  @impl true
  def cancel(state, id, _handle, reason) do
    state = %{state | parked: Enum.reject(state.parked, &(&1.id == id))}

    case Map.fetch(state.by_id, id) do
      {:ok, xref} ->
        entry = Map.fetch!(state.exchanges, xref)

        state =
          if entry.era == :legacy,
            do: post(state, cancelled(id, reason)) |> elem(1),
            else: state

        stop_exchange(state, xref)

      :error ->
        {:ok, state}
    end
  end

  defp cancelled(id, reason) do
    %{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id, "reason" => Atom.to_string(reason)}
    }
  end

  # Killing the exchange kills the Finch worker linked to it, which owns the
  # socket: the connection closes and the server sees the disconnect.
  defp stop_exchange(state, xref) do
    %{pid: pid, mon: mon, id: id} = Map.fetch!(state.exchanges, xref)
    Process.demonitor(mon, [:flush])
    Process.exit(pid, :kill)

    {:ok,
     %{
       state
       | exchanges: Map.delete(state.exchanges, xref),
         mons: Map.delete(state.mons, mon),
         by_id:
           if(Map.get(state.by_id, id) == xref,
             do: Map.delete(state.by_id, id),
             else: state.by_id
           )
     }}
  end

  # --- sessions ----------------------------------------------------------------

  @impl true
  def set_session(state, %{era: era, version: version}) do
    state = %{state | era: era, version: version}

    if era == :legacy do
      state
      |> resubmit_parked()
      |> restart_listener()
    else
      state
    end
  end

  @doc false
  # The connection's OAuth session (`ConduitMcp.Client.OAuth.Session`):
  # every exchange started from now on reads its bearer through it.
  @impl true
  def set_auth(state, session), do: %{state | auth: {:oauth, session}}

  defp resubmit_parked(%{parked: parked} = state) do
    Enum.reduce(Enum.reverse(parked), %{state | parked: []}, &resubmit(&2, &1))
  end

  defp resubmit(state, spec) do
    method = spec.method
    params = spec.message["params"] || %{}

    spec = %{
      spec
      | session: state.session,
        version: state.version,
        resubmitted?: true,
        headers: headers(state, method, params, :legacy, state.session, [])
    }

    start(state, spec)
  end

  defp restart_listener(state) do
    state = stop_listener(state)
    listener = state.listener_module
    xref = make_ref()

    spec = %{
      owner: state.owner,
      tag: __MODULE__,
      tref: state.ref,
      xref: xref,
      http: state.http,
      finch: state.finch,
      url: state.url,
      headers: [{"accept", "text/event-stream"}] ++ state.opts[:headers],
      session_headers: legacy_headers(state, nil, state.session),
      auth: state.auth,
      redirect: state.opts[:redirect],
      url_policy: state.url_policy,
      max_bytes: state.opts[:max_message_bytes],
      idle_timeout: state.opts[:listen_idle_timeout]
    }

    metadata = Telemetry.inherited_logger_metadata()

    run = fn ->
      Logger.metadata(metadata)
      listener.run(spec)
    end

    case Task.Supervisor.start_child(state.task_sup, run) do
      {:ok, pid} -> %{state | listener: %{pid: pid, mon: Process.monitor(pid), xref: xref}}
      {:error, _reason} -> state
    end
  end

  defp stop_listener(%{listener: %{pid: pid, mon: mon}} = state) do
    Process.demonitor(mon, [:flush])
    Process.exit(pid, :kill)
    %{state | listener: nil}
  end

  defp stop_listener(state), do: %{state | listener: nil}

  # --- messages ------------------------------------------------------------------

  @impl true
  def handle_info({__MODULE__, ref, nil, _kind, events}, %{ref: ref} = state),
    do: {:ok, events, state}

  def handle_info({__MODULE__, ref, xref, kind, events}, %{ref: ref} = state) do
    cond do
      Map.has_key?(state.exchanges, xref) -> exchange_events(xref, kind, events, state)
      match?(%{xref: ^xref}, state.listener) -> listener_events(kind, events, state)
      # A message from an exchange already cancelled or replaced.
      true -> {:ok, [], state}
    end
  end

  def handle_info({__MODULE__, _old_ref, _xref, _kind, _events}, state), do: {:ok, [], state}

  def handle_info({:DOWN, mon, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.mons, mon) -> exchange_down(mon, reason, state)
      match?(%{mon: ^mon}, state.listener) -> {:ok, [], %{state | listener: :disabled}}
      true -> :unknown
    end
  end

  def handle_info(_message, _state), do: :unknown

  defp exchange_events(xref, kind, events, state) do
    {events, state} = Enum.flat_map_reduce(events, state, &internal_event/2)

    state =
      if kind == :done do
        %{mon: mon, id: id} = Map.fetch!(state.exchanges, xref)
        Process.demonitor(mon, [:flush])

        %{
          state
          | exchanges: Map.delete(state.exchanges, xref),
            mons: Map.delete(state.mons, mon),
            by_id:
              if(Map.get(state.by_id, id) == xref,
                do: Map.delete(state.by_id, id),
                else: state.by_id
              )
        }
      else
        state
      end

    {:ok, events, state}
  end

  defp internal_event({:session_id, sid}, state),
    do: {[], %{state | session: Secret.new(sid)}}

  defp internal_event({:expired, spec}, state), do: expired(spec, state)
  defp internal_event(event, state), do: {[event], state}

  # A legacy 404 to a request that carried session id `spec.session`.
  defp expired(%{resubmitted?: true} = spec, state),
    do: {[{:exchange_done, spec.id, {:error, Error.new(:session_expired)}}], state}

  defp expired(spec, state) do
    cond do
      # This session ended: forget it, park the request, re-initialize.
      same_session?(spec.session, state.session) ->
        state = %{state | session: nil, parked: [spec | state.parked]} |> stop_listener()
        {[{:session_expired, spec.id}], state}

      # A new session is being negotiated: wait for it.
      state.session == nil ->
        {[], %{state | parked: [spec | state.parked]}}

      # Sent with a session already replaced: send it with the new one.
      true ->
        {[], resubmit(state, spec)}
    end
  end

  defp same_session?(a, b),
    do: Secret.secret?(a) and Secret.secret?(b) and Secret.expose(a) == Secret.expose(b)

  defp listener_events(:done, events, state) do
    disabled? = Enum.any?(events, &match?({:listener_disabled, _}, &1))
    events = Enum.reject(events, &match?({:listener_disabled, _}, &1))

    state =
      case state.listener do
        %{mon: mon} when disabled? ->
          Process.demonitor(mon, [:flush])
          %{state | listener: :disabled}

        _other ->
          state
      end

    {:ok, events, state}
  end

  defp listener_events(:events, events, state), do: {:ok, events, state}

  defp exchange_down(mon, reason, state) do
    {xref, mons} = Map.pop(state.mons, mon)
    {entry, exchanges} = Map.pop(state.exchanges, xref)

    by_id =
      if Map.get(state.by_id, entry.id) == xref,
        do: Map.delete(state.by_id, entry.id),
        else: state.by_id

    state = %{state | mons: mons, exchanges: exchanges, by_id: by_id}

    events =
      if entry.mode == :post,
        do: [],
        else: [{:exchange_done, entry.id, {:error, {:exchange_down, reason_tag(reason)}}}]

    {:ok, events, state}
  end

  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag({reason, _}) when is_atom(reason), do: reason
  defp reason_tag(_reason), do: :crashed

  # --- close ------------------------------------------------------------------------

  @impl true
  def close(state, _reason) do
    state = stop_listener(state)

    Enum.each(state.exchanges, fn {_xref, %{pid: pid, mon: mon}} ->
      Process.demonitor(mon, [:flush])
      Process.exit(pid, :kill)
    end)

    delete_session(state)
  end

  # SHOULD: a legacy client ends its session with DELETE. Bounded by 1 s; any
  # answer (a 405 included) or failure is fine.
  #
  # Under `server_url_policy: :public_only` the DELETE must be vetted and
  # pinned like every other request, which resolves the host (perhaps with
  # the host's `:resolver`): that runs in a task, never in the connection,
  # which waits for it no longer than the same 1 s.
  defp delete_session(%{era: :legacy, session: session, url_policy: %{}} = state)
       when session != nil do
    spec = %{
      http: state.http,
      finch: state.finch,
      url: state.url,
      headers: legacy_headers(state, nil, session),
      auth: static_auth(state.opts[:auth]),
      redirect: state.opts[:redirect],
      url_policy: state.url_policy,
      deadline: System.monotonic_time(:millisecond) + 1_000
    }

    exchange = state.exchange
    task = Task.Supervisor.async_nolink(state.task_sup, fn -> exchange.delete(spec) end)
    _ = Task.yield(task, 1_000) || Task.shutdown(task, :brutal_kill)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp delete_session(%{era: :legacy, session: session} = state) when session != nil do
    request = %{
      method: :delete,
      url: state.url,
      headers: legacy_headers(state, nil, session) ++ auth_header(state.opts[:auth]),
      finch: state.finch
    }

    _ = state.http.request(request, 1_000)
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp delete_session(_state), do: :ok

  defp static_auth({:bearer, _token} = auth), do: auth
  defp static_auth(_auth), do: nil

  # Static credentials only, as every DELETE gets: the unpinned one runs in
  # the connection, which never runs user code. `validate_auth/1` already
  # checked a static token.
  defp auth_header({:bearer, token}) do
    case bearer(token) do
      {:ok, header} -> [{"authorization", header}]
      {:error, _error} -> []
    end
  end

  defp auth_header(_auth), do: []

  @doc false
  # The `Authorization` value for `token`. A token must be 1 or more visible
  # ASCII characters (0x21-0x7E, which covers RFC 6750 `b64token`): Mint
  # refuses any other byte in a header value by echoing the whole value in
  # its error, so such a token - a function's `"tok\n"`, a host store's or
  # an authorization server's control byte - is refused here, by an error
  # that names no value.
  @spec bearer(String.t() | Secret.t()) :: {:ok, Secret.t()} | {:error, Error.t()}
  def bearer(token) do
    token = token_text(token)

    if bearer_token?(token),
      do: {:ok, Secret.new("Bearer " <> token)},
      else: {:error, Error.new(:auth, :invalid_token)}
  end

  @doc false
  @spec bearer_token?(term()) :: boolean()
  def bearer_token?(token) when is_binary(token), do: String.match?(token, ~r/\A[\x21-\x7E]+\z/)
  def bearer_token?(_token), do: false

  # --- option validators --------------------------------------------------------------

  @doc false
  @spec validate_url(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "expected an http or https URL, got: #{inspect(url)}"}

      uri.userinfo != nil ->
        {:error, "expected a URL without user info (use :auth for credentials)"}

      uri.fragment != nil ->
        {:error, "expected a URL without a fragment, got: #{inspect(url)}"}

      true ->
        case URLPolicy.check(url, :any) do
          {:ok, _target} -> {:ok, url}
          {:error, reason} -> {:error, "invalid URL #{inspect(url)}: #{inspect(reason)}"}
        end
    end
  end

  def validate_url(other), do: {:error, "expected a URL string, got: #{inspect(other)}"}

  @doc false
  # Names may appear in messages; values never do (they may be secrets).
  @spec validate_headers(term()) :: {:ok, [{String.t(), term()}]} | {:error, String.t()}
  def validate_headers(headers) when is_list(headers) or is_map(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, acc} when is_binary(name) ->
        name = String.downcase(name)

        cond do
          not token?(name) ->
            {:halt, {:error, "invalid header name #{inspect(name)}"}}

          name in @reserved_headers or String.starts_with?(name, "mcp-") ->
            {:halt, {:error, "header #{inspect(name)} is set by the transport"}}

          not valid_header_value?(value) ->
            {:halt,
             {:error,
              "the value of header #{inspect(name)} must be a string (or a " <>
                "ConduitMcp.Client.Secret wrapping one) of visible ASCII characters, " <>
                "spaces and tabs"}}

          true ->
            {:cont, {:ok, [{name, value} | acc]}}
        end

      _entry, _acc ->
        {:halt, {:error, "expected a list of {name, value} string pairs"}}
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      error -> error
    end
  end

  def validate_headers(_other), do: {:error, "expected a list of {name, value} string pairs"}

  defp token?(name), do: name != "" and Enum.all?(:binary.bin_to_list(name), &(&1 in @tchars))

  # What Mint accepts in a header value: visible ASCII, space and tab. Any
  # other byte would fail every request with an error echoing the value.
  defp valid_header_value?(value) do
    value = token_text(value)

    is_binary(value) and String.match?(value, ~r/\A[\x20-\x7E\t]*\z/)
  end

  @doc false
  @spec validate_auth(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_auth(nil), do: {:ok, nil}

  # A plain token is wrapped, so the options never show it (`inspect/1`,
  # supervisor reports).
  def validate_auth({:bearer, token}) do
    if bearer_token?(token_text(token)),
      do: {:ok, {:bearer, Secret.new(token)}},
      else:
        {:error,
         "expected {:bearer, token} with a non-empty token (a string or Secret) of " <>
           "visible ASCII characters only"}
  end

  def validate_auth(fun) when is_function(fun, 1), do: {:ok, fun}

  # Built into a `ConduitMcp.Client.OAuth.Config` once the URL is known
  # (`validate_options/1`).
  def validate_auth({:oauth, %OAuth.Config{}} = auth), do: {:ok, auth}

  def validate_auth({grant, opts} = auth)
      when grant in [:oauth, :client_credentials] and is_list(opts),
      do: {:ok, auth}

  def validate_auth(_other),
    do:
      {:error,
       "expected nil, {:bearer, token}, a one-arity function, {:oauth, opts} " <>
         "or {:client_credentials, opts}"}

  defp token_text(token), do: if(Secret.secret?(token), do: Secret.expose(token), else: token)
end
