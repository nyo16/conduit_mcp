defmodule ConduitMcp.Client.Hub do
  @moduledoc """
  Many MCP servers behind one tool list: a supervisor of one
  `ConduitMcp.Client` per server, plus the functions that list their tools
  under collision-free names and route a model's tool call to the right
  server through the governed call pipeline (`ConduitMcp.Client.Pipeline`).

      children = [
        {ConduitMcp.Client.Hub,
         name: MyApp.Hub,
         policy: [allow: ["github/get_*", "fs/read_*"], ask: ["github/*"], deny: ["*/delete_*"]],
         on_ask: &MyApp.Approvals.ask/2,
         hooks: [post_tool_call: [{:all, &MyApp.Audit.result/3, id: :audit}]],
         servers: [
           github: [transport: {ConduitMcp.Client.Transport.StreamableHTTP, url: "..."}],
           fs: [transport: {ConduitMcp.Client.Transport.Stdio, command: "mcp-fs"}, trusted: true]
         ]}
      ]

      {:ok, toolset} = ConduitMcp.Client.Hub.list_tools(MyApp.Hub)
      # offer the toolset to a model (ConduitMcp.Client.Adapters), then:
      {:ok, result} = ConduitMcp.Client.Hub.call_tool(MyApp.Hub, "github__get_issue", args, toolset: toolset)

  The application starts no hub; add one to your own supervision tree.
  Options are validated when the child spec is built
  (`ConduitMcp.Client.Hub.Config`), so a typo, a duplicate server id or a
  missing `:policy` fails at boot naming it.

  ## A policy is required (R6, PO-2)

  A hub hands tools to a model, so it refuses to start without `:policy`.
  To allow everything, say so: `policy: :allow_all`. Rules match the
  `{server_id, tool}` pair (`"github/create_*"`), never the exposed name
  (PO-3). With no matching rule a call is asked about when there is an
  `:on_ask` approver and denied otherwise.

  ## Servers and their options

  `servers:` is `[{server_id, client_opts}]` in the order their tools are
  listed. A `server_id` is operator configuration
  (`^[a-z][a-z0-9_]{0,31}$`, no `__`, no trailing `_`, unique), never the
  server's self-reported `serverInfo.name`, which is display only. Each
  server runs as a `ConduitMcp.Client` named `{:hub_server, hub, server_id}`
  (`client/2`), so every `ConduitMcp.Client` function (resources, prompts,
  `status/1`) works on it directly.

  The hub's governance options (`:policy`, `:on_ask`, `:ask_timeout`,
  `:grant_ttl`, `:hooks`, `:hook_timeout`, `:tools`, `:validate`,
  `:max_result_bytes_for_llm`, `:clock`) apply to every server; the same
  key in a server's `client_opts` overrides them for that server, except:

    * `:hooks` - the hub's hooks of an event run before the server's (both
      must be keyword lists);
    * `:tools` - the server's `:exclude` patterns are added to the hub's,
      and its `:include` patterns, when it has any, replace the hub's;
    * `:policy` - may be replaced (`:allow_all` included) but never removed.

  `trusted: true` is per server: it lets policy annotation rules believe
  that server's tool hints (PO-8).

  ## Supervision

  The hub is a `:rest_for_one` supervisor of the OAuth token store (see
  "OAuth"), a `Task.Supervisor` (for
  `ConduitMcp.Client.Adapters.execute_tool_calls/4` and listing fetches), a
  `DynamicSupervisor` holding the server clients, and a manager process.
  Server clients are `restart: :temporary`: when one exits (a bug, or its
  own supervisor giving up after repeated connection crashes) the manager
  starts it again after a jittered backoff (`:restart_backoff`, 1 s doubling
  to at most 30 s), so one crash-looping server never exhausts a
  supervisor's restart intensity or takes the others down. Each client is
  itself a `:one_for_all` supervisor allowing 3 restarts in 5 s: a
  connection that keeps crashing takes its client down within seconds, and
  the manager's backoff paces what follows (ST-8). Starting never
  blocks: servers are started after `start_link/1` returns, and each client
  connects in the background.

  At most `:max_stdio_servers` (16) servers run a local process (a
  transport whose `kind/0` is `:stdio`), so a configuration or a caller of
  `add_server/3` cannot fork without bound (ST-8).

  `add_server/3` and `remove_server/2` change the server set at runtime.
  **Servers added at runtime are not durable**: they survive a restart of
  the manager but not of the hub (re-add them from your own store;
  `add_server/3` is idempotent). A server removed at runtime stays removed
  until the hub restarts.

  ## OAuth (X-18)

  The hub starts one in-memory `ConduitMcp.Client.OAuth.TokenStore.ETS`
  and gives it to every server whose `auth: {:oauth, opts}` or
  `auth: {:client_credentials, opts}` names no `:store` (a server's own
  `:store` is kept). Tokens stay keyed by `{principal, issuer, resource}`,
  so each server still gets only its own (OA-5), but:

    * a client registered dynamically with an authorization server is
      reused by every server behind that issuer (one registration, not one
      per server);
    * a server client that is restarted (by the manager after a crash, or
      removed and added again) finds its tokens and needs no new
      authorization.

  The store lives as long as the hub: it is in memory, and a hub restart
  loses it. For tokens that survive restarts, name a persistent store
  (`ConduitMcp.Client.OAuth.TokenStore`) in each server's OAuth options.

  ## Tool listing (X-12, HB-1, HB-2, HB-4)

  `list_tools/2` keeps no aggregated index: it reads each server client's
  cache (`ConduitMcp.Client.Cache`) and builds a `ConduitMcp.Client.ToolSet`
  with `ConduitMcp.Client.Naming.build/2`:

    * only servers whose connection is `:ready` contribute; a failed,
      starting, reconnecting or closed server's tools are left out;
    * servers in configuration order (runtime additions after), then each
      server's tools in the order it listed them, which keeps the list
      stable for prompt caching;
    * exposed names are `server_id <> "__" <> tool` (plus the optional
      `:prefix`), sanitized and length-capped; when several tools map to one
      exposed name, **none** is offered, a warning is logged and
      `[:conduit_mcp, :client, :hub, :collision]` plus a `tool.rejected`
      per tool are emitted;
    * each server's tools first pass its filter and `:on_tools_listed`
      hooks (with the call's `:assigns` and `:principal`), exactly as
      `ConduitMcp.Client.cached_tools/2` presents them, so a hidden tool is
      never offered (PO-7).

  Building names is memoized by the listed names (not by cache version):
  the mapping is a pure function of `{prefix, [{server_id, [tool_name]}]}`,
  so a hit is always right, including with per-caller filters and across
  client restarts (whose cache versions start over). On 1 000 tools,
  `Naming.build/2` takes about 8 ms and a hit (one ETS read, then the
  toolset's maps) about 2 ms. Collisions are reported when a name list is
  first seen, not on every listing.

  A server's list is fetched by the hub only when the cache has none, when
  it is stale (a `list_changed` arrived, or the connection was lost) or past
  a positive `ttlMs`, and at most once per `:refetch_interval` (1 s) per
  server; otherwise the cached list is used as is. The client itself already
  coalesces `list_changed` bursts into at most one leading and one trailing
  refresh per 250 ms and refreshes cached lists on its own. After
  `:breaker_threshold` (3) consecutive failed fetches, a server's tools are
  left out until a fetch succeeds (HB-4).

  ## Calling (HB-2, MR-3)

  `call_tool/4` resolves the model-issued name with a table lookup in the
  toolset (pass the one the model saw as `toolset:`; otherwise the current
  one is built). An unknown name is answered with
  `{:ok, %ToolResult{is_error: true}}` saying so, and nothing is sent to any
  server. A known name runs `ConduitMcp.Client.Pipeline.run/3` on the owning
  server's client: selection, hooks, validation, policy and approval, the
  request and its multi-round-trip retries (always to that same server),
  post-hooks. A server that is not running, reconnecting or closed gives
  `{:error, %Error{kind: :unavailable}}` at once.

  Pass `taint:` (the server ids whose output is in the model's context) to
  let policy rules react to cross-server data flow (HB-3, see
  `ConduitMcp.Client.Policy.tainted/1`).

  ## Telemetry

  `[:conduit_mcp, :client, :hub, :server_failed | :server_restarted |
  :collision]` (see `ConduitMcp.Telemetry`); each server's client emits the
  usual client events with `client: {:hub_server, hub, server_id}`.
  """

  use Supervisor

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Adapters.Content
  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Hub.{Config, Manager, Table}
  alias ConduitMcp.Client.Naming
  alias ConduitMcp.Client.Pipeline
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Request
  alias ConduitMcp.Client.Task, as: ClientTask
  alias ConduitMcp.Client.Telemetry
  alias ConduitMcp.Client.{Tool, ToolCall, ToolResult, ToolSet}
  alias ConduitMcp.Reflect

  require Logger

  @typedoc "The `:name` a hub was started with."
  @type hub :: term()

  @typedoc "A server's state as `status/1` reports it."
  @type server_status :: %{
          id: String.t(),
          state:
            :starting
            | :failed
            | :connecting
            | :discovering
            | :initializing
            | :ready
            | :authorizing
            | :reconnecting
            | :closed,
          era: :modern | :legacy | nil,
          attempts: non_neg_integer(),
          reason: term()
        }

  @list_timeout 5_000
  @manager_timeout 15_000

  # --- supervision -------------------------------------------------------------

  @doc """
  The child spec for a hub. Validates the options (raising `ArgumentError`
  naming a missing `:policy`, a bad server id or a bad client option); the
  id is `{ConduitMcp.Client.Hub, name}`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    config = Config.new!(opts)

    %{
      id: {__MODULE__, config.name},
      start: {__MODULE__, :start_link, [config]},
      type: :supervisor
    }
  end

  @doc """
  Starts a hub (see `ConduitMcp.Client.Hub.Config` for the options).
  Returns once the processes exist; servers are started right after, and
  connect in the background.
  """
  @spec start_link(keyword() | Config.t()) :: Supervisor.on_start()
  def start_link(opts) do
    config = Config.new!(opts)
    Supervisor.start_link(__MODULE__, config, name: Registry.via({:hub, config.name}))
  end

  @impl Supervisor
  def init(%Config{} = config) do
    # Created here, in the supervisor (which then only idles), so the table
    # outlives a restart of the manager and dies with the hub.
    table = Table.new()
    :ok = Registry.put_value({:hub, config.name}, %{table: table, config: config})

    # The OAuth token store comes first: server clients come and go
    # (restarts, `remove_server/2`) without taking their tokens with them.
    {store, store_opts} = Config.token_store(config.name)

    children = [
      {store, store_opts},
      {Task.Supervisor, name: task_sup(config.name)},
      {DynamicSupervisor,
       name: Registry.via({:hub_servers, config.name}), strategy: :one_for_one},
      {Manager, {config, table}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # --- servers -------------------------------------------------------------------

  @doc """
  The `ConduitMcp.Client` name of server `server_id` in `hub`, for calling
  `ConduitMcp.Client` functions on it directly.

      iex> ConduitMcp.Client.Hub.client(MyApp.Hub, "github")
      {:hub_server, MyApp.Hub, "github"}
  """
  @spec client(hub(), String.t()) :: Client.client()
  def client(hub, server_id) when is_binary(server_id), do: {:hub_server, hub, server_id}

  @doc "The hub's server ids, in listing order."
  @spec servers(hub()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def servers(hub) do
    with {:ok, ref} <- __lookup__(hub),
         do: {:ok, Enum.map(Table.servers(ref.table), & &1.id)}
  end

  @doc """
  Each server's state, in listing order: `:starting`, `:failed` (waiting
  to be started again; `attempts` counts consecutive failures and `reason`
  is a tag of the last exit), or its connection's state
  (`ConduitMcp.Client.status/1`).
  """
  @spec status(hub()) :: {:ok, [server_status()]} | {:error, Error.t()}
  def status(hub) do
    with {:ok, ref} <- __lookup__(hub) do
      {:ok, Enum.map(Table.servers(ref.table), &server_status/1)}
    end
  end

  defp server_status(row) do
    base = %{id: row.id, state: row.state, era: nil, attempts: row.attempts, reason: row.reason}

    with :running <- row.state,
         {:ok, status} <- Client.status(row.config.name) do
      %{base | state: status.state, era: status.era, reason: status.reason}
    else
      :running -> %{base | state: :starting}
      _not_running -> base
    end
  end

  @doc """
  Adds and starts server `server_id` with `client_opts` (as in `servers:`).
  Idempotent: when the id is already present, nothing changes (remove it
  first to change its options). Raises `ArgumentError` on an invalid id or
  option. A stdio server beyond the hub's `:max_stdio_servers` is refused
  with `{:error, %Error{kind: :overloaded, reason: :max_stdio_servers}}`
  and nothing is started. Not durable across a hub restart.
  """
  @spec add_server(hub(), String.t() | atom(), keyword()) :: :ok | {:error, Error.t()}
  def add_server(hub, server_id, client_opts) do
    server_id = if is_atom(server_id), do: Atom.to_string(server_id), else: server_id

    case Naming.validate_server_id(server_id) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError, "invalid server_id #{inspect(server_id)}: #{reason}"
    end

    with {:ok, ref} <- __lookup__(hub) do
      config = Config.server_config!(ref.config, server_id, client_opts)
      manager_call(hub, {:add, server_id, config})
    end
  end

  @doc """
  Stops server `server_id` and forgets it (until the hub restarts, for a
  server from `servers:`). `{:error, %Error{kind: :not_found}}` when the hub
  has no such server.
  """
  @spec remove_server(hub(), String.t() | atom()) :: :ok | {:error, Error.t()}
  def remove_server(hub, server_id) do
    server_id = if is_atom(server_id), do: Atom.to_string(server_id), else: server_id
    manager_call(hub, {:remove, server_id})
  end

  defp manager_call(hub, message) do
    GenServer.call(Manager.via(hub), message, @manager_timeout)
  catch
    :exit, {:timeout, _} -> {:error, Error.new(:timeout, :hub_manager)}
    :exit, _reason -> {:error, Error.new(:unavailable, :not_started)}
  end

  # --- tools ---------------------------------------------------------------------

  @doc """
  The tools of every ready server, as a `ConduitMcp.Client.ToolSet` keyed by
  exposed name (see "Tool listing").

  ## Options

    * `:assigns`, `:principal` - passed to each server's filter functions
      and `:on_tools_listed` hooks (as for `ConduitMcp.Client.cached_tools/2`).
    * `:timeout` - milliseconds a server's list fetch may take (default
      5 000); a server that does not answer in time is left out.
    * `:refresh` - `true` fetches every ready server's list now, ignoring
      the cache and `:refetch_interval` (default `false`).
  """
  @spec list_tools(hub(), keyword()) :: {:ok, ToolSet.t()} | {:error, Error.t()}
  def list_tools(hub, opts \\ []) do
    opts = Keyword.validate!(opts, [:assigns, :principal, timeout: @list_timeout, refresh: false])

    with {:ok, ref} <- __lookup__(hub), do: {:ok, build_toolset(hub, ref, opts)}
  end

  @doc """
  Calls the tool the model knows as `exposed_name` with `args`.

  ## Options

    * `:toolset` - the `ConduitMcp.Client.ToolSet` the model was offered
      (recommended: resolve against exactly what it saw). Without it the
      current one is built with `list_tools/2` (`:assigns`, `:principal`).
    * every `ConduitMcp.Client.Pipeline.run/3` option: `:principal`,
      `:assigns`, `:taint`, `:shape`, `:meta`, `:timeout`, `:task`, progress
      options.

  Returns `{:ok, %ToolResult{is_error: true}}` for a name not in the
  toolset (nothing is sent), `{:error, %Error{kind: :unavailable}}` when the
  owning server is down, else what `ConduitMcp.Client.call_tool/4` returns.
  """
  @spec call_tool(hub(), String.t(), map(), keyword()) ::
          {:ok, ToolResult.t() | ClientTask.t()} | {:error, Error.t()}
  def call_tool(hub, exposed_name, args \\ %{}, opts \\ [])
      when is_binary(exposed_name) and is_map(args) do
    {toolset, opts} = Keyword.pop(opts, :toolset)

    with {:ok, toolset} <- toolset_for(hub, toolset, opts) do
      case ToolSet.resolve(toolset, exposed_name) do
        {:ok, tool} -> __run__(hub, {tool.name, args}, tool, opts)
        :error -> {:ok, __unknown_tool__(exposed_name)}
      end
    end
  end

  defp toolset_for(_hub, %ToolSet{} = toolset, _opts), do: {:ok, toolset}

  defp toolset_for(hub, nil, opts),
    do: list_tools(hub, Keyword.take(opts, [:assigns, :principal]))

  @doc false
  # Runs a resolved call on the owning server's client
  # (`ConduitMcp.Client.Adapters.execute_tool_calls/4` too).
  @spec __run__(hub(), ToolCall.t() | {String.t(), map()}, Tool.t(), keyword()) ::
          {:ok, ToolResult.t() | ClientTask.t()} | {:error, Error.t()}
  def __run__(hub, target, %Tool{} = tool, opts) do
    client = client(hub, tool.server_id)

    # The hub's own record first: a server that just failed may still be
    # registered for a moment while its processes exit.
    with {:ok, ref} <- __lookup__(hub),
         :ok <- running(ref, tool.server_id),
         {:ok, _pid, view} <- Request.lookup(client) do
      if view.state in [:reconnecting, :closed],
        do: {:error, Error.new(:unavailable, view.state)},
        else: Pipeline.run(client, target, Keyword.put(opts, :tool, tool))
    end
  end

  defp running(ref, server_id) do
    case Table.server(ref.table, server_id) do
      {:ok, %{state: :running}} -> :ok
      {:ok, %{state: state}} -> {:error, Error.new(:unavailable, state)}
      :error -> {:error, Error.new(:unavailable, :unknown_server)}
    end
  end

  @doc false
  # The answer to a model that named a tool it was not offered (HB-2).
  @spec __unknown_tool__(term()) :: ToolResult.t()
  def __unknown_tool__(name) do
    %ToolResult{
      is_error: true,
      content: [%{"type" => "text", "text" => Content.unknown_tool_text(name)}]
    }
  end

  @doc false
  @spec __lookup__(hub()) :: {:ok, %{table: :ets.tid(), config: Config.t()}} | {:error, Error.t()}
  def __lookup__(hub) do
    case Registry.lookup({:hub, hub}) do
      {:ok, _pid, %{table: _table, config: %Config{}} = ref} -> {:ok, ref}
      _starting_or_missing -> {:error, Error.new(:unavailable, :not_started)}
    end
  end

  @doc false
  @spec task_sup(hub()) :: GenServer.name()
  def task_sup(hub), do: Registry.via({:hub_task_sup, hub})

  # --- toolset building ------------------------------------------------------------

  defp build_toolset(hub, ref, opts) do
    now = System.monotonic_time(:millisecond)

    planned =
      for row <- Table.servers(ref.table),
          row.state == :running,
          {:ok, _pid, %{state: :ready} = view} <- [Request.lookup(row.config.name)],
          plan = plan(ref, row.id, view, now, opts[:refresh]),
          plan != :skip,
          do: {row, view, plan}

    planned
    |> fetch(hub, ref, now, opts)
    |> Enum.flat_map(fn {row, view, items} ->
      present = [assigns: opts[:assigns], principal: opts[:principal]]

      case Pipeline.present_tools(row.config.name, view, items, present, true) do
        {:ok, tools} -> [{row.id, tools, view}]
        {:error, _} -> []
      end
    end)
    |> name_tools(hub, ref)
  end

  # What to do for one ready server: use its cached list, fetch it, or
  # leave it out (HB-4). With the breaker open (too many failed fetches)
  # the cached list is not offered; each allowed attempt probes again. A
  # server whose credential cannot share private results (an `:auth`
  # function without `:credential_id`, HT-11) has no list to fall back on,
  # so every listing fetches while the breaker is closed.
  defp plan(ref, id, view, now, refresh?) do
    %{refetch_interval: interval, breaker_threshold: threshold} = ref.config
    {last, failures} = Table.fetch_state(ref.table, id, view.cache)
    allowed? = refresh? or last == nil or now - last >= interval
    open? = failures >= threshold

    case Cache.list(view.cache, :tools) do
      {:ok, entry} ->
        due? =
          refresh? or open? or entry.stale? or
            (entry.expires_at > entry.fetched_at and now >= entry.expires_at)

        cond do
          due? and allowed? -> {:fetch, entry.items}
          open? -> :skip
          true -> {:cached, entry.items}
        end

      :miss ->
        if allowed? or (not open? and not Cache.shared?(view.cache)),
          do: {:fetch, nil},
          else: :skip

      {:error, _gone} ->
        :skip
    end
  end

  defp fetch(planned, hub, ref, now, opts) do
    {fetches, cached} = Enum.split_with(planned, &match?({_row, _view, {:fetch, _}}, &1))
    fetched = run_fetches(fetches, hub, ref, now, opts)

    # Back in hub order.
    by_id =
      Map.new(
        for({row, view, {:cached, items}} <- cached, do: {row.id, {row, view, items}}) ++ fetched
      )

    for {row, _view, _plan} <- planned, Map.has_key?(by_id, row.id), do: Map.fetch!(by_id, row.id)
  end

  defp run_fetches([], _hub, _ref, _now, _opts), do: []

  defp run_fetches(fetches, hub, ref, now, opts) do
    timeout = opts[:timeout]

    Enum.each(fetches, fn {row, view, _plan} ->
      Table.fetch_started(ref.table, row.id, view.cache, now)
    end)

    results =
      try do
        hub
        |> task_sup()
        |> Task.Supervisor.async_stream_nolink(
          fetches,
          fn {row, _view, _plan} ->
            Client.__list_all__(row.config.name, :tools,
              timeout: timeout,
              refresh: opts[:refresh]
            )
          end,
          timeout: timeout + 1_000,
          on_timeout: :kill_task,
          max_concurrency: max(length(fetches), 1)
        )
        |> Enum.to_list()
      catch
        :exit, _no_task_sup -> Enum.map(fetches, fn _ -> {:exit, :no_task_sup} end)
      end

    fetches
    |> Enum.zip(results)
    |> Enum.flat_map(fn {{row, view, {:fetch, fallback}}, result} ->
      case result do
        {:ok, {:ok, items}} ->
          Table.fetch_finished(ref.table, row.id, :ok)
          [{row.id, {row, view, items}}]

        _failed ->
          failures = Table.fetch_finished(ref.table, row.id, :error)

          if failures < ref.config.breaker_threshold and fallback != nil,
            do: [{row.id, {row, view, fallback}}],
            else: []
      end
    end)
  end

  defp name_tools(lists, hub, ref) do
    prefix = ref.config.prefix
    key = {prefix, for({id, tools, _view} <- lists, do: {id, Enum.map(tools, & &1.name)})}

    pairs =
      case Table.naming(ref.table, key) do
        {:ok, pairs, _report} ->
          pairs

        :error ->
          {toolset, report} =
            Naming.build(for({id, tools, _view} <- lists, do: {id, tools}), prefix: prefix)

          pairs =
            for {name, tool} <- ToolSet.entries(toolset), do: {name, {tool.server_id, tool.name}}

          Table.put_naming(ref.table, key, pairs, report)
          report_naming(hub, report, lists)
          pairs
      end

    tools =
      Map.new(
        for {_id, tools, _view} <- lists, tool <- tools, do: {{tool.server_id, tool.name}, tool}
      )

    ToolSet.new(for {name, target} <- pairs, do: {name, Map.fetch!(tools, target)})
  end

  defp report_naming(hub, report, lists) do
    views = Map.new(lists, fn {id, _tools, view} -> {id, view} end)

    for {exposed, colliders} <- report.collisions do
      Telemetry.hub_collision(hub, exposed, colliders)

      shown =
        Enum.map_join(colliders, ", ", fn {id, tool} -> id <> "/" <> Telemetry.sanitize(tool) end)

      Logger.warning(
        "MCP hub #{Reflect.text(hub, 64)}: tools #{shown} all map to the exposed name " <>
          "#{exposed}, so none of them is offered"
      )
    end

    for {id, tool, reason} <- report.rejected do
      view = Map.fetch!(views, id)
      base = Telemetry.base(client(hub, id), id, view.transport, view.era)
      Telemetry.tool_rejected(base, Telemetry.sanitize(tool), reason)
    end

    :ok
  end
end
