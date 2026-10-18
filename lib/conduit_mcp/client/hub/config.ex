defmodule ConduitMcp.Client.Hub.Config do
  @schema NimbleOptions.new!(
            name: [
              type: :any,
              required: true,
              doc: """
              Any term naming the hub; every `ConduitMcp.Client.Hub`
              function addresses the hub by it.
              """
            ],
            policy: [
              type: {:custom, __MODULE__, :validate_policy, []},
              required: true,
              doc: """
              **Required** (R6, PO-2): the `ConduitMcp.Client.Policy` every
              server's calls are decided by - `ConduitMcp.Client.Policy.compile/1`
              options, a compiled policy, `{:named, name}`, or `:allow_all`
              (`ConduitMcp.Client.Policy.allow_all/0`), which must be spelled
              out. Rules match `{server_id, tool}` (PO-3), never the
              exposed name.
              """
            ],
            servers: [
              type: {:custom, __MODULE__, :validate_servers, []},
              default: [],
              doc: """
              `[{server_id, client_opts}]` (or a keyword list with atom ids),
              started in this order. Ids follow
              `ConduitMcp.Client.Naming.validate_server_id/1` and must be
              unique. `client_opts` are `ConduitMcp.Client` options except
              `:name` and `:server_id`, which the hub sets; governance
              options there override the hub's (see the moduledoc of
              `ConduitMcp.Client.Hub`).
              """
            ],
            on_ask: [
              type: {:or, [{:fun, 2}, {:tuple, [:atom, :atom]}, nil]},
              doc: "The approver for `:ask` decisions (the client's `:on_ask`)."
            ],
            ask_timeout: [type: :pos_integer, doc: "The client's `:ask_timeout`."],
            grant_ttl: [type: :pos_integer, doc: "The client's `:grant_ttl`."],
            hooks: [
              type: {:custom, __MODULE__, :validate_hooks, []},
              doc: """
              Hooks (`ConduitMcp.Client.Hooks`) for every server, as a keyword
              list; they run before a server's own `:hooks` of the same event.
              """
            ],
            hook_timeout: [type: :pos_integer, doc: "The client's `:hook_timeout`."],
            tools: [
              type: {:custom, __MODULE__, :validate_tool_filter, []},
              doc: """
              A `ConduitMcp.Client.ToolFilter` for every server. A server's own
              `:tools` adds its `:exclude` patterns to these and, when it has
              any, replaces the `:include` patterns.
              """
            ],
            validate: [type: :keyword_list, doc: "The client's `:validate`."],
            max_result_bytes_for_llm: [
              type: :pos_integer,
              doc: "The client's `:max_result_bytes_for_llm`."
            ],
            clock: [type: {:or, [{:fun, 0}, nil]}, doc: "The client's `:clock` (tests)."],
            telemetry: [
              type: {:custom, ConduitMcp.Client.Config, :validate_telemetry, []},
              doc: """
              The client's `:telemetry` (payload capture) for every server; a
              server's own `:telemetry` replaces it.
              """
            ],
            prefix: [
              type: :string,
              default: "",
              doc: """
              Prepended to every exposed tool name (`ConduitMcp.Client.Naming`),
              `[A-Za-z0-9_-]`, counted in the 64-byte limit.
              """
            ],
            restart_backoff: [
              type: {:fun, 1},
              doc: """
              `fn attempt -> milliseconds end`: the wait before starting a
              failed server again, `attempt` counting consecutive failures
              from 1 (a server that ran for a minute starts over at 1).
              Default: full jitter from 1 s, doubling, capped at 30 s
              (`ConduitMcp.Client.Backoff.full_jitter/2` with `base: 1_000,
              cap: 30_000`; ST-8).
              """
            ],
            max_stdio_servers: [
              type: {:or, [:non_neg_integer, {:in, [:infinity]}]},
              default: 16,
              doc: """
              The most servers whose transport is a local process
              (`kind/0` `:stdio`, such as `ConduitMcp.Client.Transport.Stdio`)
              the hub runs at once (ST-8). More in `servers:` raises when the
              hub starts; `add_server/3` beyond it returns `{:error,
              %ConduitMcp.Client.Error{kind: :overloaded, reason:
              :max_stdio_servers}}`. `:infinity` lifts the cap.
              """
            ],
            refetch_interval: [
              type: :non_neg_integer,
              default: 1_000,
              doc: """
              The least time in milliseconds between two tool-list fetches the
              hub asks one server for (HB-4).
              """
            ],
            breaker_threshold: [
              type: :pos_integer,
              default: 3,
              doc: """
              Consecutive failed tool-list fetches after which a server's
              cached tools are no longer offered, until a fetch succeeds (HB-4).
              """
            ]
          )

  @moduledoc """
  The validated options of a `ConduitMcp.Client.Hub`.

  `ConduitMcp.Client.Hub.child_spec/1` and `ConduitMcp.Client.Hub.start_link/1`
  run `new!/1`, so a missing `:policy`, a duplicate or invalid server id, or a
  bad client option raises an `ArgumentError` naming it when the hub starts.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  alias ConduitMcp.Client.{Backoff, Config, Hooks, Naming, Policy, ToolFilter}
  alias ConduitMcp.Client.OAuth.Config, as: OAuthConfig
  alias ConduitMcp.Client.OAuth.TokenStore

  @governance_keys [
    :policy,
    :on_ask,
    :ask_timeout,
    :grant_ttl,
    :hooks,
    :hook_timeout,
    :tools,
    :validate,
    :max_result_bytes_for_llm,
    :clock,
    :telemetry
  ]

  @enforce_keys [:name, :servers, :governance, :prefix, :restart_backoff]
  defstruct [
    :name,
    :servers,
    :governance,
    :prefix,
    :restart_backoff,
    refetch_interval: 1_000,
    breaker_threshold: 3,
    max_stdio_servers: 16
  ]

  @type t :: %__MODULE__{
          name: term(),
          servers: [{String.t(), Config.t()}],
          governance: keyword(),
          prefix: String.t(),
          restart_backoff: (pos_integer() -> non_neg_integer()),
          refetch_interval: non_neg_integer(),
          breaker_threshold: pos_integer(),
          max_stdio_servers: non_neg_integer() | :infinity
        }

  @doc """
  Validates `opts`; raises `ArgumentError` naming the offending option,
  server id or client option. A `%Config{}` is returned unchanged.
  """
  @spec new!(keyword() | t()) :: t()
  def new!(%__MODULE__{} = config), do: config

  def new!(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, valid} ->
        governance = Keyword.take(valid, @governance_keys)
        _ = Naming.build([], prefix: valid[:prefix])

        config = %__MODULE__{
          name: valid[:name],
          servers: [],
          governance: governance,
          prefix: valid[:prefix],
          restart_backoff: valid[:restart_backoff] || (&default_backoff/1),
          refetch_interval: valid[:refetch_interval],
          breaker_threshold: valid[:breaker_threshold],
          max_stdio_servers: valid[:max_stdio_servers]
        }

        servers = for {id, opts} <- valid[:servers], do: {id, server_config!(config, id, opts)}
        check_stdio_cap!(config, servers)
        %{config | servers: servers}

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid ConduitMcp.Client.Hub option: " <> Exception.message(error)
    end
  end

  def new!(other) do
    raise ArgumentError,
          "ConduitMcp.Client.Hub options must be a keyword list, got: #{inspect(other)}"
  end

  defp default_backoff(attempt), do: Backoff.full_jitter(attempt, base: 1_000, cap: 30_000)

  defp check_stdio_cap!(config, servers) do
    count = Enum.count(servers, fn {_id, client_config} -> stdio?(client_config) end)

    unless within_stdio_cap?(config, count) do
      raise ArgumentError,
            "invalid ConduitMcp.Client.Hub option: :max_stdio_servers is " <>
              "#{config.max_stdio_servers} but #{count} servers use a stdio transport"
    end
  end

  @doc false
  # Whether `client_config` runs its server as a local process (its
  # transport's `kind/0` is `:stdio`): what `:max_stdio_servers` counts.
  @spec stdio?(Config.t()) :: boolean()
  def stdio?(%Config{transport: {transport, _opts}}), do: transport.kind() == :stdio

  @doc false
  # Whether `count` stdio servers are within the hub's `:max_stdio_servers`.
  @spec within_stdio_cap?(t(), non_neg_integer()) :: boolean()
  def within_stdio_cap?(%__MODULE__{max_stdio_servers: :infinity}, _count), do: true
  def within_stdio_cap?(%__MODULE__{max_stdio_servers: max}, count), do: count <= max

  @doc """
  The `ConduitMcp.Client` config of server `server_id` of the hub: the hub's
  governance options overridden by `opts` (hooks and filters combined), named
  `{:hub_server, hub, server_id}`, with the hub's token store
  (`token_store/1`) when its OAuth options name no `:store`. Raises
  `ArgumentError` on a bad option.
  """
  @spec server_config!(t(), String.t(), keyword()) :: Config.t()
  def server_config!(%__MODULE__{} = hub, server_id, opts) when is_list(opts) do
    for key <- [:name, :server_id], Keyword.has_key?(opts, key) do
      raise ArgumentError,
            "invalid options for hub server #{inspect(server_id)}: " <>
              "#{inspect(key)} is set by the hub"
    end

    merged =
      Keyword.merge(hub.governance, opts, fn
        :hooks, hub_hooks, server_hooks -> merge_hooks!(server_id, hub_hooks, server_hooks)
        :tools, hub_filter, server_filter -> merge_filter(hub_filter, server_filter)
        _key, _hub_value, server_value -> server_value
      end)

    policy =
      case Keyword.get(merged, :policy) do
        :allow_all ->
          Policy.allow_all()

        nil ->
          raise ArgumentError,
                "invalid options for hub server #{inspect(server_id)}: " <>
                  ":policy cannot be nil in a hub (R6)"

        policy ->
          policy
      end

    [name: {:hub_server, hub.name, server_id}, server_id: server_id]
    |> Kernel.++(Keyword.put(merged, :policy, policy))
    |> Config.new!()
    |> share_token_store(hub.name)
  end

  def server_config!(_hub, server_id, opts) do
    raise ArgumentError,
          "options for hub server #{inspect(server_id)} must be a keyword list, " <>
            "got: #{inspect(opts)}"
  end

  @doc """
  The in-memory `ConduitMcp.Client.OAuth.TokenStore.ETS` that hub `name`
  starts and gives every server whose OAuth options name no `:store`.
  """
  @spec token_store(term()) :: TokenStore.store()
  def token_store(name), do: {TokenStore.ETS, name: {:hub, name}}

  # The transport has already turned `auth: {:oauth | :client_credentials,
  # opts}` into `{:oauth, %OAuth.Config{}}`; with no store there, the client
  # would start its own, lost with it.
  defp share_token_store(%Config{transport: {module, opts}} = config, hub_name) do
    case opts[:auth] do
      {:oauth, %OAuthConfig{store: nil} = oauth} ->
        auth = {:oauth, %{oauth | store: token_store(hub_name)}}
        %{config | transport: {module, Keyword.put(opts, :auth, auth)}}

      _other ->
        config
    end
  end

  # Both levels as keyword lists, merged per event (hub hooks first), so the
  # default hook ids (`{event, index}`) are assigned over the combined list.
  defp merge_hooks!(server_id, hub_hooks, server_hooks)
       when is_list(hub_hooks) and is_list(server_hooks),
       do:
         Keyword.merge(hub_hooks, check_hooks!(server_id, server_hooks), fn _event, hub, server ->
           hub ++ server
         end)

  defp merge_hooks!(server_id, _hub_hooks, _server_hooks) do
    raise ArgumentError,
          "invalid options for hub server #{inspect(server_id)}: :hooks must be a " <>
            "keyword list to be combined with the hub's"
  end

  defp check_hooks!(server_id, hooks) do
    _ = Hooks.compile(hooks)
    hooks
  rescue
    error in ArgumentError ->
      reraise ArgumentError,
              "invalid options for hub server #{inspect(server_id)}: " <>
                Exception.message(error),
              __STACKTRACE__
  end

  defp merge_filter(nil, server), do: server
  defp merge_filter(hub, nil), do: hub

  defp merge_filter(hub, server) do
    hub = filter(hub)
    server = filter(server)

    %ToolFilter{
      include: if(server.include == [], do: hub.include, else: server.include),
      exclude: hub.exclude ++ server.exclude
    }
  end

  defp filter(%ToolFilter{} = filter), do: filter
  defp filter(opts), do: ToolFilter.compile(opts)

  # --- NimbleOptions validators ----------------------------------------------------

  @doc false
  @spec validate_policy(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_policy(:allow_all), do: {:ok, Policy.allow_all()}

  def validate_policy(nil),
    do: {:error, "a hub needs a policy (R6); use :allow_all to allow every call"}

  def validate_policy(policy), do: Config.validate_policy(policy)

  @doc false
  @spec validate_hooks(term()) :: {:ok, keyword()} | {:error, String.t()}
  def validate_hooks(hooks) when is_list(hooks) do
    with {:ok, _compiled} <- Config.validate_hooks(hooks), do: {:ok, hooks}
  end

  def validate_hooks(other),
    do: {:error, "expected a keyword list of hooks, got: #{inspect(other)}"}

  @doc false
  @spec validate_tool_filter(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_tool_filter(filter), do: Config.validate_tool_filter(filter)

  @doc false
  @spec validate_servers(term()) :: {:ok, [{String.t(), keyword()}]} | {:error, String.t()}
  def validate_servers(servers) when is_list(servers) do
    entries =
      Enum.map(servers, fn
        {id, opts} when is_atom(id) and id not in [nil, true, false] -> {Atom.to_string(id), opts}
        {id, opts} -> {id, opts}
        other -> throw({:invalid, other})
      end)

    Naming.validate_server_ids!(Enum.map(entries, &elem(&1, 0)))
    {:ok, entries}
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  catch
    {:invalid, entry} -> {:error, "expected {server_id, client_opts}, got: #{inspect(entry)}"}
  end

  def validate_servers(other),
    do: {:error, "expected a list of {server_id, client_opts}, got: #{inspect(other)}"}
end
