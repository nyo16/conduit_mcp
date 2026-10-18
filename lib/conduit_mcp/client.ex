defmodule ConduitMcp.Client do
  @moduledoc """
  An MCP client: one supervised connection to one MCP server, speaking the
  modern (`2026-07-28`) or a legacy (`2025-11-25`, `2025-06-18`) protocol
  era, whichever the server supports.

  ## Starting

  Add a client to your supervision tree. Starting never blocks on the
  server: the connection is established in the background.

      children = [
        {ConduitMcp.Client,
         name: MyApp.Docs,
         transport: {ConduitMcp.Client.Transport.InProcess, server: MyApp.DocsServer}}
      ]

  Options are validated when the child spec is built, so a typo fails at
  boot naming the key; see `ConduitMcp.Client.Config` for all of them.
  `:name` may be any term (`{MyApp.Docs, tenant_id}` works) and is how
  every function below addresses the client. The application starts no
  clients itself; it only runs the registry they register in.

  Each client is a supervisor (`:one_for_all`) of a `Task.Supervisor`, the
  owner of its governance table (grants, the approval baseline, built
  schemas; see "Governance") and a `ConduitMcp.Client.Connection`. Use
  `await_ready/2` when you need the handshake done before going on;
  requests made earlier simply wait for it (within their own timeout).

  ## Calling

  Every request function runs in the calling process and returns
  `{:ok, value}` or `{:error, %ConduitMcp.Client.Error{}}`. A tool that ran
  and reported failure is **not** an error: `call_tool/4` returns
  `{:ok, %ConduitMcp.Client.ToolResult{is_error: true}}`. Errors are for
  protocol, transport and limit failures (match on `kind`).

  Request options, accepted by every request function:

    * `:timeout` - milliseconds before the request is cancelled (default
      the client's `:request_timeout`, 60 s).
    * `:on_progress` - a one-arity function, or a pid sent
      `{:mcp_progress, name, params}`, for `notifications/progress`.
    * `:reset_timeout_on_progress` - restart `:timeout` on each progress
      notification, capped by `:max_total_timeout`.
    * `:max_total_timeout` - see above; also caps a deadline paused while
      the client's handler answers a legacy server request tied to the call.
    * `:meta` - a map merged into the request's `_meta`. Keys the protocol
      reserves (`progressToken`, `io.modelcontextprotocol/*`) are dropped.
    * `:assigns` - a map given to `ConduitMcp.Client.Handler` callbacks as
      `ctx.assigns` for input requests made on behalf of this call (default
      the client's `:assigns`).
    * `:traceparent` - the W3C trace context to send in a modern request's
      `_meta` (default: the caller's `Logger.metadata()[:traceparent]`, as
      OpenTelemetry-style integrations set it). Dropped unless well formed;
      a `traceparent` in `:meta` wins. Only `traceparent` is propagated,
      never `tracestate` or `baggage`.

  ## Eras

  With the default `protocol: :auto` the client probes `server/discover`
  and falls back to `initialize` only on legacy evidence. The era decides
  the wire format; the functions here work in both, with these
  exceptions: `ping/2` sends `server/discover` to a modern server,
  `set_log_level/2` is a request in legacy and a per-request `_meta` value
  in modern, and `notify_roots_changed/1` is legacy only.

  In the modern era `call_tool/4`, `read_resource/3` and `get_prompt/4` may
  get `resultType: "input_required"`; the client runs the
  multi-round-trip loop (`ConduitMcp.Client.Request.MRTR`) in the caller,
  answering each input request with its `ConduitMcp.Client.Handler` in the
  calling process. An input request the handler does not declare fails the
  call with `kind: :protocol` before any callback runs; a callback that
  fails or refuses fails it with `kind: :input_handler`. Legacy servers ask
  with JSON-RPC requests instead, which the connection hands to the handler
  in a supervised task (see `ConduitMcp.Client.Connection`). Both go
  through the same safety checks (`ConduitMcp.Client.Handler`).

  ## Listing and the cache

  `list_tools/2` and friends fetch one page. `list_all_tools/2` and friends
  fetch every page (capped: 100 pages, 10 000 items, a repeated or
  over-1 KiB cursor fails with `kind: :pagination_cycle`) and keep the
  result in the client's `ConduitMcp.Client.Cache`, which serves it again
  while the server's `ttlMs` hint says it is fresh. `cached_tools/2` and
  `tool/3` read the cache without asking the server. A result the server
  marks private is served only while the client sends the credentials it
  was fetched with (`set_auth/3` changes them; see "Private results" in
  `ConduitMcp.Client.Cache`).

  Every listed tool goes through intake: a tool whose name is outside the
  spec charset (`[A-Za-z0-9_.-]`, 1-128 characters), whose definition is
  malformed, whose name repeats, or (over HTTP) whose `x-mcp-header`
  annotations are invalid is dropped with a warning and
  `[:conduit_mcp, :client, :tool, :rejected]`; the others carry a
  `ConduitMcp.Client.Fingerprint`.

  ## Tasks

  `call_tool/4` with `task: :return | :await` lets a long tool call run as a
  server task (the modern tasks extension, or a legacy task-augmented
  call); see `ConduitMcp.Client.Task`, `get_task/3`, `await_task/3` and
  `cancel_task/3`.

  ## Governance

  A plain client sends what it is asked to. Configure any of `:policy`
  (`ConduitMcp.Client.Policy`, with an `:on_ask` approver and
  `ConduitMcp.Client.Grants`), `:hooks` (`ConduitMcp.Client.Hooks`),
  `:tools` (a `ConduitMcp.Client.ToolFilter`) or `:validate`
  (`ConduitMcp.Client.SchemaValidator`) and every `call_tool/4` runs
  through `ConduitMcp.Client.Pipeline`, in the caller: hidden tools vanish
  from listings, pre-hooks and validation run before policy decides on the
  final arguments, and post-hooks see the result. Hooks and approvers run
  in tasks under the client's `Task.Supervisor`, never in the connection.

  ## Notifications

  `subscribe_notifications/2` sends server notifications to a process as
  `{:mcp_notification, name, method, params}`; see
  `ConduitMcp.Client.Connection` for coalescing of `list_changed`.
  `subscribe/2` asks for updates of one resource in either era (legacy
  `resources/subscribe`, modern `subscriptions/listen`); a `list_changed`
  invalidates and refreshes the cached list it names.

  ## Transports

  `ConduitMcp.Client.Transport.Stdio` runs a local server process;
  `ConduitMcp.Client.Transport.StreamableHTTP` (needs `:finch`) talks to a
  remote one; `ConduitMcp.Client.Transport.InProcess` serves a server module
  in this VM for tests. Over HTTP, a modern `call_tool/4` sends the tool's
  `Mcp-Param-*` headers computed from the cached tool definition (see
  `list_all_tools/2`); a server rejecting them (`-32020`) makes the client
  refresh the tools and send the call once more.
  """

  use Supervisor

  alias ConduitMcp.Client.Adapters.Content
  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Cache.Fetch
  alias ConduitMcp.Client.Config
  alias ConduitMcp.Client.Connection
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Governance
  alias ConduitMcp.Client.Input
  alias ConduitMcp.Client.Pipeline
  alias ConduitMcp.Client.Prompt
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Request
  alias ConduitMcp.Client.Request.MRTR
  alias ConduitMcp.Client.Resource
  alias ConduitMcp.Client.Task, as: ClientTask
  alias ConduitMcp.Client.TaskRequestor
  alias ConduitMcp.Client.Telemetry
  alias ConduitMcp.Client.Tool
  alias ConduitMcp.Client.ToolResult

  @typedoc "The `:name` a client was started with."
  @type client :: term()

  @typedoc "A page of a list request; `next_cursor` is `nil` on the last page."
  @type page(key, item) :: %{required(key) => [item], required(:next_cursor) => String.t() | nil}

  @typedoc """
  The connection's state as `status/1` reports it. `reason` explains a
  `:closed` state and is `nil` otherwise.
  """
  @type status :: %{
          state:
            :connecting
            | :discovering
            | :initializing
            | :ready
            | :authorizing
            | :reconnecting
            | :closed,
          era: :modern | :legacy | nil,
          version: String.t() | nil,
          reason: term()
        }

  @typedoc "What the server said about itself in the handshake."
  @type server_info :: %{
          era: :modern | :legacy,
          version: String.t(),
          server_info: ConduitMcp.Client.ServerInfo.t() | nil,
          capabilities: map(),
          instructions: String.t() | nil
        }

  @request_options [
    :timeout,
    :on_progress,
    :reset_timeout_on_progress,
    :max_total_timeout,
    :assigns,
    :traceparent
  ]
  @control_timeout 5_000
  @header_mismatch ConduitMcp.Errors.header_mismatch()
  @grace_ms 100

  # --- supervision -------------------------------------------------------------

  @doc """
  The child spec for a client. Validates the options (raising
  `ArgumentError` naming a bad key); the id is `{ConduitMcp.Client, name}`,
  so one supervisor can hold many clients.

      iex> spec =
      ...>   ConduitMcp.Client.child_spec(
      ...>     name: :docs,
      ...>     transport: {ConduitMcp.Client.Transport.InProcess, server: ConduitMcp.TestServer}
      ...>   )
      iex> spec.id
      {ConduitMcp.Client, :docs}
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
  Starts a client (see `ConduitMcp.Client.Config` for the options). Returns
  once the processes exist, without waiting for the server.

      {:ok, _pid} =
        ConduitMcp.Client.start_link(
          name: :docs,
          transport: {ConduitMcp.Client.Transport.InProcess, server: MyApp.DocsServer}
        )
  """
  @spec start_link(keyword() | Config.t()) :: Supervisor.on_start()
  def start_link(opts) do
    config = Config.new!(opts)
    Supervisor.start_link(__MODULE__, config, name: Registry.via({:supervisor, config.name}))
  end

  @impl Supervisor
  def init(%Config{} = config) do
    children =
      [{Task.Supervisor, name: Registry.via({:task_sup, config.name})}] ++
        transport_children(config) ++
        [{Governance.Owner, config}, {Connection, config}]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 3, max_seconds: 5)
  end

  # A transport may need processes of its own that outlive one connection
  # attempt (the Streamable HTTP transport's Finch pool): they start before
  # the connection and stop with the client.
  defp transport_children(%Config{transport: {transport, opts}, name: name}) do
    if function_exported?(transport, :child_specs, 2),
      do: transport.child_specs(opts, name),
      else: []
  end

  # --- lifecycle -----------------------------------------------------------------

  @doc """
  Waits until the client is ready to send requests. Returns `:ok`, or
  `{:error, %Error{kind: :timeout}}` after `timeout` ms, or the `:closed`
  error at once if the connection gave up.

      :ok = ConduitMcp.Client.await_ready(:docs, 5_000)
  """
  @spec await_ready(client(), timeout()) :: :ok | {:error, Error.t()}
  def await_ready(client, timeout \\ @control_timeout),
    do: Request.call(client, :await_ready, timeout)

  @doc """
  The connection's current state, read without messaging it.

      {:ok, %{state: :ready, era: :modern}} = ConduitMcp.Client.status(:docs)
  """
  @spec status(client()) :: {:ok, status()} | {:error, Error.t()}
  def status(client) do
    with {:ok, _pid, view} <- Request.lookup(client) do
      {:ok, %{state: view.state, era: view.era, version: view.version, reason: view.reason}}
    end
  end

  @doc """
  What the server reported in the handshake: its `ServerInfo`, capabilities
  and instructions, with the negotiated era and version.
  `{:error, %Error{kind: :unavailable, reason: :not_ready}}` while the
  client is not ready.

      {:ok, %{capabilities: %{"tools" => _}}} = ConduitMcp.Client.server_info(:docs)
  """
  @spec server_info(client()) :: {:ok, server_info()} | {:error, Error.t()}
  def server_info(client) do
    with {:ok, _pid, view} <- Request.lookup(client) do
      case view.server do
        nil ->
          {:error, Error.new(:unavailable, :not_ready)}

        server ->
          {:ok, Map.merge(server, %{era: view.era, version: view.version})}
      end
    end
  end

  @doc """
  The server's `instructions` as they may be put in a model's context
  (PI-1): `{:ok, nil}` unless the client was started with
  `include_instructions: true` (they arrive with the handshake and are
  written by the server, so they are kept out of system prompts by default).
  When included they are capped at 4 KiB with invisible and
  direction-changing characters removed, and, unless the client is
  `trusted: true`, prefixed with a line naming the server they came from.
  `server_info/1` still returns them raw.

      {:ok, nil} = ConduitMcp.Client.instructions_for_llm(:docs)
  """
  @spec instructions_for_llm(client()) :: {:ok, String.t() | nil} | {:error, Error.t()}
  def instructions_for_llm(client) do
    with {:ok, %{settings: settings}} <- Governance.lookup(client),
         {:ok, info} <- server_info(client) do
      case info.instructions do
        text when is_binary(text) and settings.include_instructions ->
          text = text |> Content.strip_invisible() |> Content.cap(4_096)

          if settings.trusted,
            do: {:ok, text},
            else:
              {:ok,
               "Instructions from MCP server #{inspect(settings.server_id)} " <>
                 "(server-supplied, not from the user):\n" <> text}

        _excluded ->
          {:ok, nil}
      end
    end
  end

  @doc """
  The negotiated protocol era (`:modern` or `:legacy`), kept while the
  client reconnects. `{:error, %Error{kind: :unavailable}}` before the first
  handshake.

      {:ok, :modern} = ConduitMcp.Client.era(:docs)
  """
  @spec era(client()) :: {:ok, :modern | :legacy} | {:error, Error.t()}
  def era(client) do
    case Request.lookup(client) do
      {:ok, _pid, %{era: nil}} -> {:error, Error.new(:unavailable, :not_negotiated)}
      {:ok, _pid, %{era: era}} -> {:ok, era}
      error -> error
    end
  end

  @doc """
  Closes the connection: pending requests fail with `kind: :closed`, the
  transport is closed, and the client stays in `:closed` (answering every
  request at once) until `reconnect/1`.

      :ok = ConduitMcp.Client.close(:docs)
  """
  @spec close(client()) :: :ok | {:error, Error.t()}
  def close(client), do: Request.call(client, :close, @control_timeout)

  @doc """
  Drops the current connection (pending requests fail with
  `kind: :transport`) and connects again at once, with the reconnect count
  reset. Also revives a `:closed` client.

      :ok = ConduitMcp.Client.reconnect(:docs)
  """
  @spec reconnect(client()) :: :ok | {:error, Error.t()}
  def reconnect(client), do: Request.call(client, :reconnect, @control_timeout)

  @doc """
  Tells a client using OAuth (`auth: {:oauth, ...}`) that the host stored
  new tokens: a connection waiting for interactive authorization checks the
  token store now and resumes, instead of on its next request.
  `ConduitMcp.Client.OAuth.handle_callback/3` calls it when given
  `client:`. Returns `:ok` without waiting for the check, or
  `{:error, %Error{kind: :auth, reason: :oauth_not_configured}}`.

      :ok = ConduitMcp.Client.authorized(:docs)
  """
  @spec authorized(client()) :: :ok | {:error, Error.t()}
  def authorized(client), do: Request.call(client, :authorized, @control_timeout)

  @doc """
  Replaces the credentials the client sends with `auth`, any form the
  transport's `:auth` option takes (`ConduitMcp.Client.Transport.StreamableHTTP`:
  `nil`, `{:bearer, token}`, a one-arity function, `{:oauth, opts}`,
  `{:client_credentials, opts}`), checked like that option. Raises
  `ArgumentError` when it is invalid, or when the transport takes no
  `:auth`.

  Everything bound to the old credentials ends: the client reconnects as
  `reconnect/1` does (requests in flight fail with `kind: :transport`,
  listen streams and a legacy session close, an OAuth authorization in
  progress is abandoned). Cached results the server marked private are
  deleted before this returns when the credentials' identity changes, and
  fetched again under the new ones; public results stay (see "Private
  results" in `ConduitMcp.Client.Cache`). A `:closed` client stays closed.

  OAuth options naming no `:store` keep the client's current token store;
  change `:principal` to act for another user (tokens are stored per
  principal). The change lasts as long as the client process: a client
  restarted by its supervisor starts with its configured credentials.

      :ok = ConduitMcp.Client.set_auth(:docs, {:bearer, new_token})

  Options:

    * `:credential_id` - with an `:auth` function, any term naming whose
      tokens it returns (the transport's `:credential_id`). Without it,
      private results fetched with the function are never served from the
      cache.
  """
  @spec set_auth(client(), term(), keyword()) :: :ok | {:error, Error.t()}
  def set_auth(client, auth, opts \\ []) do
    opts = Keyword.validate!(opts, credential_id: nil)

    case Request.call(client, {:set_auth, auth, opts[:credential_id]}, @control_timeout) do
      {:error, {:invalid_auth, message}} -> raise ArgumentError, message
      other -> other
    end
  end

  # --- requests ------------------------------------------------------------------

  @doc """
  Checks the server answers: a legacy `ping`, or `server/discover` for a
  modern server (which has no `ping`).

      :ok = ConduitMcp.Client.ping(:docs, timeout: 1_000)
  """
  @spec ping(client(), keyword()) :: :ok | {:error, Error.t()}
  def ping(client, opts \\ []) do
    with {:ok, _result} <- request(client, :ping, %{}, opts), do: :ok
  end

  @doc """
  Lists one page of tools. Pass the previous page's `next_cursor` as
  `:cursor` for the next one. Tools that fail intake are left out (see
  "Listing and the cache" above); the page is never cached.

  On a governed client (see `call_tool/4`) the page holds only the tools
  the `:tools` filter shows (function patterns see `:assigns` and
  `:principal`), with a usable schema when `:validate` is on, after the
  `:on_tools_listed` hooks (`ConduitMcp.Client.Hooks`); the same applies to
  `list_all_tools/2`, `cached_tools/2` and `tool/3`.

      {:ok, %{tools: [%ConduitMcp.Client.Tool{name: "echo"} | _], next_cursor: nil}} =
        ConduitMcp.Client.list_tools(:docs)
  """
  @spec list_tools(client(), keyword()) :: {:ok, page(:tools, Tool.t())} | {:error, Error.t()}
  def list_tools(client, opts \\ []) do
    {principal, opts} = Keyword.pop(opts, :principal)

    with {:ok, %{tools: tools} = page} <- list_page(client, :tools, :tools, opts),
         {:ok, tools} <- present_tools(client, tools, opts, principal, false),
         do: {:ok, %{page | tools: tools}}
  end

  @doc """
  Lists every tool, following `nextCursor`, through the client's
  `ConduitMcp.Client.Cache`: a fresh cached list is returned without asking
  the server; otherwise the connection refreshes it (one refresh at a time,
  shared by concurrent callers) and the new list is returned and cached.

  ## Options

    * `:timeout` - per page, and the longest the caller waits (default the
      client's `:request_timeout`). A refresh the caller stopped waiting for
      still completes and fills the cache.
    * `:refresh` - `true` to ignore a fresh cached list (default `false`).
    * `:assigns`, `:principal` - for a governed client's filter and hooks.

  Pagination is capped (100 pages, 10 000 items, a repeated or over-1 KiB
  cursor): over a cap the result is `{:error, %Error{kind:
  :pagination_cycle}}` and nothing is cached.

      {:ok, [%ConduitMcp.Client.Tool{} | _]} = ConduitMcp.Client.list_all_tools(:docs)
  """
  @spec list_all_tools(client(), keyword()) :: {:ok, [Tool.t()]} | {:error, Error.t()}
  def list_all_tools(client, opts \\ []) do
    {governance, opts} = Keyword.split(opts, [:assigns, :principal])

    with {:ok, tools} <- list_all(client, :tools, opts),
         do: present_tools(client, tools, governance, governance[:principal], true)
  end

  @doc """
  The tools of the last `list_all_tools/2` (or `list_changed` refresh) as
  cached, fresh or not, without asking the server.
  `{:error, %Error{kind: :not_found, reason: :not_cached}}` before the first
  listing. Takes `:assigns` and `:principal` (see `list_tools/2`).

      {:ok, tools} = ConduitMcp.Client.cached_tools(:docs)
  """
  @spec cached_tools(client(), keyword()) :: {:ok, [Tool.t()]} | {:error, Error.t()}
  def cached_tools(client, opts \\ []) do
    opts = Keyword.validate!(opts, [:assigns, :principal])

    with {:ok, _pid, view} <- Request.lookup(client) do
      case Cache.list(view.cache, :tools) do
        {:ok, entry} -> present_tools(client, entry.items, opts, opts[:principal], true)
        :miss -> {:error, Error.new(:not_found, :not_cached)}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  The cached definition of tool `name` (one cache row; the server is not
  asked). `{:error, %Error{kind: :not_found}}` when the last listing did not
  include it, or nothing was listed yet, or (on a governed client) the tool
  is hidden. Takes `:assigns` and `:principal` (see `list_tools/2`).

      {:ok, %ConduitMcp.Client.Tool{name: "echo"}} = ConduitMcp.Client.tool(:docs, "echo")
  """
  @spec tool(client(), String.t(), keyword()) :: {:ok, Tool.t()} | {:error, Error.t()}
  def tool(client, name, opts \\ []) when is_binary(name) do
    opts = Keyword.validate!(opts, [:assigns, :principal])

    with {:ok, _pid, view} <- Request.lookup(client) do
      case Cache.lookup(view.cache, :tools, name) do
        {:ok, tool} ->
          if Pipeline.present_tool?(client, view, tool, opts),
            do: {:ok, tool},
            else: {:error, Error.new(:not_found, :unknown_tool)}

        :miss ->
          {:error, Error.new(:not_found, :unknown_tool)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp present_tools(client, tools, opts, principal, full?) do
    opts = [assigns: Keyword.get(opts, :assigns), principal: principal]

    with {:ok, _pid, view} <- Request.lookup(client),
         do: Pipeline.present_tools(client, view, tools, opts, full?)
  end

  @doc """
  Calls tool `name` with `args` (string- or atom-keyed; sent as given).

  A tool that ran and failed is `{:ok, %ToolResult{is_error: true}}`.

  ## Tasks

    * `task: :return` - if the server runs the call as a task, return
      `{:ok, %ConduitMcp.Client.Task{}}` at once (poll it with
      `get_task/3`, `await_task/3`).
    * `task: :await` - if the server runs the call as a task, poll it until
      it finishes and return its `ToolResult`. `:timeout` bounds the whole
      wait; when it passes the task is cancelled (`tasks/cancel`), as it is
      if the calling process dies.
    * `task_ttl: ms` - the legacy `task.ttl` to request.

  Modern servers decide per call whether to create a task; the client
  declares the tasks extension only when `:task` is given, so without it the
  server must answer directly. Legacy servers get a task-augmented call only
  when they declare `tasks.requests.tools.call` and the tool's
  `execution.taskSupport` allows it: `"required"` always (awaited when no
  `:task` is given), `"optional"` only with `:task`. With `:task`, a call
  made before the first handshake waits for it (within `:timeout`), since
  the era decides how the call becomes a task; without it the call is
  queued as usual and sent plain.

      {:ok, %ConduitMcp.Client.ToolResult{content: [%{"text" => "hi"}]}} =
        ConduitMcp.Client.call_tool(:docs, "echo", %{"message" => "hi"})

  ## Governance

  When the client is configured with `:policy`, `:hooks`, `:tools` or
  `:validate`, or the call passes `:shape`, the call runs through
  `ConduitMcp.Client.Pipeline` (selection, pre-hooks, validation, policy
  and approval, post-hooks); otherwise it is sent as given. Pipeline
  options:

    * `:principal` - who the call is made for (in `ctx`, and the key of
      "always allow" grants). Ignored by a plain client.
    * `:shape` - `:llm` to shape the result for a model.

  A governed call may also fail with `kind: :not_found` (hidden or unknown
  tool), `:denied` (policy, approver or hook) or `:hook` (a pre-hook
  failed).
  """
  @spec call_tool(client(), String.t(), map(), keyword()) ::
          {:ok, ToolResult.t() | ClientTask.t()} | {:error, Error.t()}
  def call_tool(client, name, args \\ %{}, opts \\ []) when is_binary(name) and is_map(args) do
    if Keyword.has_key?(opts, :shape) or governed?(client) do
      Pipeline.run(client, {name, args}, opts)
    else
      plain_call(client, name, args, Keyword.delete(opts, :principal))
    end
  end

  defp governed?(client),
    do: match?({:ok, %{settings: %{enabled?: true}}}, Governance.lookup(client))

  defp plain_call(client, name, args, opts) do
    {mode, opts} = Keyword.pop(opts, :task)
    {ttl, opts} = Keyword.pop(opts, :task_ttl)

    unless mode in [nil, :return, :await] do
      raise ArgumentError, ":task must be :return or :await, got: #{inspect(mode)}"
    end

    with {:ok, view} <- negotiated_view(client, mode, opts) do
      base = Telemetry.base(client, view.server_id, view.transport, view.era)

      Telemetry.tool_call_span(base, name, args, view.capture_payloads, fn ->
        __send_tool_call__(
          client,
          view,
          %{"name" => name, "arguments" => args},
          {mode, ttl},
          opts
        )
      end)
    end
  end

  @doc false
  # The negotiated caller view for a call (`ConduitMcp.Client.Pipeline`).
  @spec __view__(client(), :return | :await | nil, keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def __view__(client, mode, opts), do: negotiated_view(client, mode, opts)

  @doc false
  # Sends a `tools/call` with `params` (and its MRTR rounds, or the task it
  # becomes) and returns `{result, rounds}`; `ConduitMcp.Client.Pipeline`
  # step 9. `opts` are request options plus `:meta`; `tool` is the resolved
  # definition (its `Mcp-Param-*` headers), `nil` to look it up in the cache.
  @spec __send_tool_call__(
          client(),
          map(),
          map(),
          {atom() | nil, term()},
          keyword(),
          Tool.t() | nil
        ) ::
          {{:ok, ToolResult.t() | ClientTask.t()} | {:error, Error.t()}, non_neg_integer()}
  def __send_tool_call__(client, view, params, {mode, ttl}, opts, tool \\ nil) do
    if view.era == :modern,
      do: modern_call(client, view, params, mode, opts, tool),
      else: legacy_call(client, view, params, {mode, ttl}, opts)
  end

  # The era decides how a call becomes a task, so a task call waits for the
  # first handshake (the era survives reconnects). Other calls are queued by
  # the connection as usual.
  defp negotiated_view(client, mode, opts) do
    with {:ok, _pid, view} <- Request.lookup(client) do
      if view.era == nil and mode != nil do
        with :ok <- await_ready(client, Keyword.get(opts, :timeout, view.request_timeout)),
             {:ok, _pid, view} <- Request.lookup(client),
             do: {:ok, view}
      else
        {:ok, view}
      end
    end
  end

  defp modern_call(client, view, params, mode, opts, tool) do
    case modern_send(client, view, params, mode, opts, tool) do
      # `-32020`: the `Mcp-Param-*` headers came from a stale (or missing)
      # tool definition; refresh the tools and send once more (CS §6.3)
      # with the definition just listed (a private list fetched with an
      # unshared credential is not cached, HT-11).
      {:error, %Error{reason: {:jsonrpc, @header_mismatch}}} when view.transport == :http ->
        tool = listed_tool(client, params["name"])

        modern_send(client, view, params, mode, opts, tool)
        |> modern_result(client, view, mode, opts)

      outcome ->
        modern_result(outcome, client, view, mode, opts)
    end
  end

  defp listed_tool(client, name) do
    case list_all(client, :tools, refresh: true) do
      {:ok, tools} -> Enum.find(tools, &(&1.name == name))
      {:error, _} -> nil
    end
  end

  defp modern_send(client, view, params, mode, opts, tool) do
    result_types = if mode == nil, do: [], else: ["task"]

    mrtr(client, "tools/call", params, view, opts,
      extensions: TaskRequestor.extensions(mode),
      result_types: result_types,
      headers: param_headers(view, params, tool)
    )
  end

  defp modern_result(outcome, client, view, mode, opts) do
    case outcome do
      {:ok, %{"resultType" => "task"} = result, %{rounds: rounds}} ->
        {TaskRequestor.created(client, view, :modern, result, mode, opts), rounds}

      {:ok, result, %{rounds: rounds}} ->
        {ToolResult.from_wire(result), rounds}

      {:error, _} = error ->
        {error, 0}
    end
  end

  # The `Mcp-Param-*` headers of a modern HTTP call, from the tool
  # definition (the resolved one, else the cached one) and the final
  # arguments (sent as given, so atom keys are normalised the way the JSON
  # body will carry them).
  defp param_headers(
         %{transport: :http, cache: cache},
         %{"name" => name, "arguments" => args},
         tool
       ) do
    with {:ok, tool} <- definition(tool, cache, name),
         [_ | _] <- ConduitMcp.Headers.header_params(tool.input_schema),
         {:ok, args} <- normalise(args) do
      ConduitMcp.Headers.param_headers(tool.input_schema, args)
    else
      _ -> []
    end
  end

  defp param_headers(_view, _params, _tool), do: []

  defp definition(%Tool{name: name} = tool, _cache, name), do: {:ok, tool}
  defp definition(_tool, cache, name), do: Cache.lookup(cache, :tools, name)

  defp normalise(args) do
    JSON.decode(JSON.encode!(args))
  rescue
    _error in [Protocol.UndefinedError, ArgumentError] -> :error
  end

  defp legacy_call(client, view, params, {mode, ttl}, opts) do
    case TaskRequestor.legacy_plan(client, view, params["name"], mode, opts) do
      {:augment, mode} ->
        task = if is_integer(ttl), do: %{"ttl" => ttl}, else: %{}

        case request(client, "tools/call", Map.put(params, "task", task), opts) do
          {:ok, %{"task" => %{} = raw}} ->
            {TaskRequestor.created(client, view, :legacy, raw, mode, opts), 1}

          {:ok, result} ->
            {ToolResult.from_wire(result), 1}

          {:error, _} = error ->
            {error, 1}
        end

      :plain ->
        case mrtr(client, "tools/call", params, view, opts) do
          {:ok, result, %{rounds: rounds}} -> {ToolResult.from_wire(result), rounds}
          {:error, _} = error -> {error, 0}
        end
    end
  end

  @doc """
  Reads the current state of a server task (`tasks/get`).

      {:ok, %ConduitMcp.Client.Task{status: :working}} = ConduitMcp.Client.get_task(:docs, task)
  """
  @spec get_task(client(), ClientTask.t() | String.t(), keyword()) ::
          {:ok, ClientTask.t()} | {:error, Error.t()}
  def get_task(client, task, opts \\ []), do: TaskRequestor.get(client, task, timeout_opts(opts))

  @doc """
  Waits for a server task to finish and returns its tool result, polling at
  the task's `pollIntervalMs` and answering its input requests with the
  client's handler (modern) or reading `tasks/result` (legacy). `:timeout`
  bounds the whole wait (default the client's `:request_timeout`); when it
  passes the task is cancelled and `{:error, %Error{kind: :timeout}}`
  returned. `:assigns` is passed to the handler.

      {:ok, %ConduitMcp.Client.ToolResult{}} = ConduitMcp.Client.await_task(:docs, task)
  """
  @spec await_task(client(), ClientTask.t() | String.t(), keyword()) ::
          {:ok, ToolResult.t()} | {:error, Error.t()}
  def await_task(client, task, opts \\ []),
    do: TaskRequestor.await(client, task, Keyword.validate!(opts, [:timeout, :assigns]))

  @doc """
  Asks the server to cancel a task (`tasks/cancel`). Cancellation is
  cooperative: the task may still finish.

      :ok = ConduitMcp.Client.cancel_task(:docs, task)
  """
  @spec cancel_task(client(), ClientTask.t() | String.t(), keyword()) :: :ok | {:error, Error.t()}
  def cancel_task(client, task, opts \\ []),
    do: TaskRequestor.cancel(client, task, timeout_opts(opts))

  defp timeout_opts(opts), do: Keyword.validate!(opts, [:timeout])

  @doc """
  `call_tool/4` in a task under the client's `Task.Supervisor`
  (`Task.Supervisor.async_nolink/2`): await it with `Task.await/2` or
  `Task.yield/2`. A crash in the task does not take the caller down.
  Exits with `:noproc` if the client is not running.

      task = ConduitMcp.Client.async_call_tool(:docs, "echo", %{"message" => "hi"})
      {:ok, %ConduitMcp.Client.ToolResult{}} = Task.await(task)
  """
  @spec async_call_tool(client(), String.t(), map(), keyword()) :: Task.t()
  def async_call_tool(client, name, args \\ %{}, opts \\ []) do
    Task.Supervisor.async_nolink(Registry.via({:task_sup, client}), fn ->
      call_tool(client, name, args, opts)
    end)
  end

  @doc """
  Lists one page of resources (`:cursor` as in `list_tools/2`).

      {:ok, %{resources: [%ConduitMcp.Client.Resource{} | _]}} =
        ConduitMcp.Client.list_resources(:docs)
  """
  @spec list_resources(client(), keyword()) ::
          {:ok, page(:resources, Resource.t())} | {:error, Error.t()}
  def list_resources(client, opts \\ []), do: list_page(client, :resources, :resources, opts)

  @doc """
  Lists every resource through the cache, as `list_all_tools/2` does for
  tools.

      {:ok, [%ConduitMcp.Client.Resource{} | _]} = ConduitMcp.Client.list_all_resources(:docs)
  """
  @spec list_all_resources(client(), keyword()) :: {:ok, [Resource.t()]} | {:error, Error.t()}
  def list_all_resources(client, opts \\ []), do: list_all(client, :resources, opts)

  @doc """
  Lists one page of resource templates, as the server's string-keyed
  `ResourceTemplate` maps (`:cursor` as in `list_tools/2`).

      {:ok, %{resource_templates: [%{"uriTemplate" => "item://{id}"} | _]}} =
        ConduitMcp.Client.list_resource_templates(:docs)
  """
  @spec list_resource_templates(client(), keyword()) ::
          {:ok, page(:resource_templates, map())} | {:error, Error.t()}
  def list_resource_templates(client, opts \\ []),
    do: list_page(client, :resource_templates, :resource_templates, opts)

  @doc """
  Lists every resource template through the cache, as `list_all_tools/2`
  does for tools.

      {:ok, [%{"uriTemplate" => _} | _]} = ConduitMcp.Client.list_all_resource_templates(:docs)
  """
  @spec list_all_resource_templates(client(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_all_resource_templates(client, opts \\ []),
    do: list_all(client, :resource_templates, opts)

  @doc """
  Reads the resource at `uri`; returns the server's string-keyed
  `ReadResourceResult` (`"contents"`).

  On a governed client the `:on_resource_read` hooks run first, then the
  policy's resource rules when its `:scope` includes `:resources` (an ask
  rule denies: reads have no approver); `:principal` is passed to them.

      {:ok, %{"contents" => [%{"text" => _} | _]}} =
        ConduitMcp.Client.read_resource(:docs, "test://resource1")
  """
  @spec read_resource(client(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def read_resource(client, uri, opts \\ []) when is_binary(uri) do
    {principal, opts} = Keyword.pop(opts, :principal)
    governance = [assigns: Keyword.get(opts, :assigns), principal: principal]

    with {:ok, _pid, view} <- Request.lookup(client),
         :ok <- Pipeline.authorize_resource(client, view, uri, governance),
         {:ok, result, _rounds} <- mrtr(client, "resources/read", %{"uri" => uri}, view, opts),
         do: {:ok, result}
  end

  @doc """
  Subscribes to updates of the resource at `uri`, whichever era the server
  speaks. Updates arrive as `{:mcp_notification, name,
  "notifications/resources/updated", %{"uri" => uri}}` to the processes
  subscribed with `subscribe_notifications/2`.

    * Legacy: sends `resources/subscribe` (the server must declare
      `resources.subscribe`, else `kind: :protocol`, reason
      `:subscriptions_not_supported`) and answers with the server's answer.
    * Modern: adds `uri` to the `subscriptions/listen` filter (a new listen
      replaces the old one once the server acknowledges it) and answers
      `:ok` when the acknowledgment honours `uri`, else `kind: :protocol`,
      reason `:subscription_not_acknowledged`.

  The subscription is kept across reconnects and session renewals (sent
  again each time the connection becomes ready). A call made before the
  connection is ready waits for it, up to `:timeout` (default the client's
  `:request_timeout`).

      :ok = ConduitMcp.Client.subscribe(:docs, "file:///notes.md")
  """
  @spec subscribe(client(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def subscribe(client, uri, opts \\ []) when is_binary(uri),
    do: resource_subscription(client, :subscribe, uri, opts)

  @doc """
  Ends a `subscribe/2` subscription to `uri` (legacy
  `resources/unsubscribe`; modern: a listen without `uri`).

      :ok = ConduitMcp.Client.unsubscribe(:docs, "file:///notes.md")
  """
  @spec unsubscribe(client(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def unsubscribe(client, uri, opts \\ []) when is_binary(uri),
    do: resource_subscription(client, :unsubscribe, uri, opts)

  defp resource_subscription(client, op, uri, opts) do
    opts = Keyword.validate!(opts, [:timeout])

    with {:ok, _pid, view} <- Request.lookup(client) do
      timeout = Keyword.get(opts, :timeout, view.request_timeout)
      Request.call(client, {:resource_subscription, op, uri}, timeout)
    end
  end

  @doc """
  Lists one page of prompts (`:cursor` as in `list_tools/2`).

      {:ok, %{prompts: [%ConduitMcp.Client.Prompt{name: "greeting"} | _]}} =
        ConduitMcp.Client.list_prompts(:docs)
  """
  @spec list_prompts(client(), keyword()) ::
          {:ok, page(:prompts, Prompt.t())} | {:error, Error.t()}
  def list_prompts(client, opts \\ []), do: list_page(client, :prompts, :prompts, opts)

  @doc """
  Lists every prompt through the cache, as `list_all_tools/2` does for
  tools.

      {:ok, [%ConduitMcp.Client.Prompt{} | _]} = ConduitMcp.Client.list_all_prompts(:docs)
  """
  @spec list_all_prompts(client(), keyword()) :: {:ok, [Prompt.t()]} | {:error, Error.t()}
  def list_all_prompts(client, opts \\ []), do: list_all(client, :prompts, opts)

  @doc """
  Gets prompt `name` with `args`. Prompt arguments are strings on the wire,
  so keys and values are converted: atoms, numbers and booleans with
  `to_string/1`, other non-strings as JSON. `nil` values are dropped.
  Returns the server's string-keyed `GetPromptResult` (`"messages"`).

  On a governed client the `:on_prompt_get` hooks (which may rewrite
  `args`) and the policy's prompt rules run first, as for
  `read_resource/3`.

      {:ok, %{"messages" => [_ | _]}} =
        ConduitMcp.Client.get_prompt(:docs, "greeting", %{name: "Ada"})
  """
  @spec get_prompt(client(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_prompt(client, name, args \\ %{}, opts \\ []) when is_binary(name) and is_map(args) do
    {principal, opts} = Keyword.pop(opts, :principal)
    governance = [assigns: Keyword.get(opts, :assigns), principal: principal]

    with {:ok, _pid, view} <- Request.lookup(client),
         {:ok, args} <- Pipeline.authorize_prompt(client, view, name, args, governance),
         params = %{"name" => name, "arguments" => stringify_args(args)},
         {:ok, result, _rounds} <- mrtr(client, "prompts/get", params, view, opts),
         do: {:ok, result}
  end

  @doc """
  Asks for completions of `argument` of `ref`. Returns the server's
  string-keyed `CompleteResult` (`"completion"`).

  `ref` is `{:prompt, name}`, `{:resource, uri_template}` or a wire
  reference map; `argument` is `{name, value}` or a wire map.

  ## Options

  The request options, plus `:context` - already-resolved arguments,
  `%{"arguments" => %{...}}`.

      {:ok, %{"completion" => %{"values" => _}}} =
        ConduitMcp.Client.complete(:docs, {:prompt, "greeting"}, {"name", "A"})
  """
  @spec complete(
          client(),
          {:prompt | :resource, String.t()} | map(),
          {String.t(), String.t()} | map(),
          keyword()
        ) ::
          {:ok, map()} | {:error, Error.t()}
  def complete(client, ref, argument, opts \\ []) do
    {context, opts} = Keyword.pop(opts, :context)

    params =
      %{"ref" => completion_ref(ref), "argument" => completion_argument(argument)}
      |> put_present("context", context)

    request(client, "completion/complete", params, opts)
  end

  @doc """
  Sets the server's log level (`"debug"` … `"emergency"`, string or atom).
  Legacy: sends `logging/setLevel`. Modern: the level is sent in the
  `_meta` of every later request; a modern server sends no log
  notifications for requests without one.

      :ok = ConduitMcp.Client.set_log_level(:docs, :warning)
  """
  @spec set_log_level(client(), String.t() | atom()) :: :ok | {:error, Error.t()}
  def set_log_level(client, level) when is_atom(level),
    do: set_log_level(client, Atom.to_string(level))

  def set_log_level(client, level) when is_binary(level) do
    unless level in ConduitMcp.Ctx.log_levels() do
      raise ArgumentError,
            "log level must be one of #{Enum.join(ConduitMcp.Ctx.log_levels(), ", ")}, " <>
              "got: #{inspect(level)}"
    end

    with {:ok, _result} <- request(client, {:set_log_level, level}, %{}, []), do: :ok
  end

  @doc """
  Sends `notifications/roots/list_changed` (legacy only; the client
  declares `roots.listChanged` when its handler implements `list_roots/1`).
  In the modern era, or without a roots handler, returns
  `{:error, %Error{kind: :protocol}}`.

      :ok = ConduitMcp.Client.notify_roots_changed(:docs)
  """
  @spec notify_roots_changed(client()) :: :ok | {:error, Error.t()}
  def notify_roots_changed(client) do
    with {:ok, _result} <- request(client, :roots_list_changed, %{}, []), do: :ok
  end

  @doc """
  Sends server notifications to `pid` (default: the caller) as
  `{:mcp_notification, name, method, params}`. Idempotent; the subscription
  ends when `pid` exits or `unsubscribe_notifications/2` is called.
  `notifications/progress` goes to the request's caller instead.

      :ok = ConduitMcp.Client.subscribe_notifications(:docs)

      receive do
        {:mcp_notification, :docs, "notifications/tools/list_changed", _params} -> :refresh
      end
  """
  @spec subscribe_notifications(client(), pid()) :: :ok | {:error, Error.t()}
  def subscribe_notifications(client, pid \\ self()) when is_pid(pid),
    do: Request.call(client, {:subscribe, pid}, @control_timeout)

  @doc """
  Stops sending server notifications to `pid` (default: the caller).

      :ok = ConduitMcp.Client.unsubscribe_notifications(:docs)
  """
  @spec unsubscribe_notifications(client(), pid()) :: :ok | {:error, Error.t()}
  def unsubscribe_notifications(client, pid \\ self()) when is_pid(pid),
    do: Request.call(client, {:unsubscribe, pid}, @control_timeout)

  # --- helpers ---------------------------------------------------------------------

  defp request(client, op, params, opts) do
    {meta, opts} = Keyword.pop(opts, :meta)
    Request.run(client, op, put_meta(params, meta), request_opts(opts))
  end

  defp request_opts(opts), do: Keyword.validate!(opts, @request_options)

  defp put_meta(params, nil), do: params
  defp put_meta(params, meta) when is_map(meta), do: Map.put(params, "_meta", meta)

  defp list_page(client, kind, page_key, opts) do
    {cursor, opts} = Keyword.pop(opts, :cursor)
    {meta, opts} = Keyword.pop(opts, :meta)
    opts = request_opts(opts)
    opts = if meta == nil, do: opts, else: Keyword.put(opts, :meta, meta)

    with {:ok, _pid, view} <- Request.lookup(client),
         {:ok, page} <- Fetch.page(client, kind, cursor, opts, Fetch.context(client, view)) do
      {:ok, %{page_key => page.items, :next_cursor => page.next_cursor}}
    end
  end

  @doc false
  # The raw cached listing (no governance), for `ConduitMcp.Client.Pipeline`.
  @spec __list_all__(client(), Cache.kind(), keyword()) :: {:ok, [term()]} | {:error, Error.t()}
  def __list_all__(client, kind, opts), do: list_all(client, kind, opts)

  defp list_all(client, kind, opts) do
    opts = Keyword.validate!(opts, [:timeout, refresh: false])

    with {:ok, _pid, view} <- Request.lookup(client) do
      now = System.monotonic_time(:millisecond)

      case Cache.list(view.cache, kind) do
        {:ok, entry} ->
          if not opts[:refresh] and Cache.fresh?(entry, now),
            do: {:ok, entry.items},
            else: refresh(client, kind, view, opts)

        :miss ->
          refresh(client, kind, view, opts)

        {:error, _} = error ->
          error
      end
    end
  end

  # The connection runs the refresh (single flight) and answers when the
  # list is written.
  defp refresh(client, kind, view, opts) do
    timeout = Keyword.get(opts, :timeout, view.request_timeout)
    Request.call(client, {:refresh, kind, [timeout: timeout]}, timeout + @grace_ms)
  end

  # tools/call, resources/read and prompts/get may answer `input_required`;
  # each round is its own request (a fresh id from the connection), and
  # input requests are answered here, in the caller.
  defp mrtr(client, method, params, view, opts, extra \\ []) do
    {meta, opts} = Keyword.pop(opts, :meta)
    opts = request_opts(opts)
    extensions = Keyword.get(extra, :extensions, %{})
    run_opts = if extensions == %{}, do: opts, else: Keyword.put(opts, :extensions, extensions)

    run_opts =
      case Keyword.get(extra, :headers, []) do
        [] -> run_opts
        headers -> Keyword.put(run_opts, :headers, headers)
      end

    env = Input.caller_env(client, view, Keyword.get(opts, :assigns))

    MRTR.run(method, put_meta(params, meta),
      send: fn _id, method, params -> Request.run(client, method, params, run_opts) end,
      next_id: fn -> nil end,
      handle_input: fn _key, request ->
        Input.answer(request["method"], Map.get(request, "params"), env)
      end,
      capabilities: view.client_capabilities,
      result_types: Keyword.get(extra, :result_types, [])
    )
  end

  defp stringify_args(args) do
    for {key, value} <- args, value != nil, into: %{} do
      {to_text(key), to_text(value)}
    end
  end

  defp to_text(value) when is_binary(value), do: value

  defp to_text(value) when is_atom(value) or is_number(value),
    do: to_string(value)

  defp to_text(value), do: JSON.encode!(value)

  defp completion_ref({:prompt, name}) when is_binary(name),
    do: %{"type" => "ref/prompt", "name" => name}

  defp completion_ref({:resource, uri}) when is_binary(uri),
    do: %{"type" => "ref/resource", "uri" => uri}

  defp completion_ref(%{} = ref), do: ref

  defp completion_argument({name, value}) when is_binary(name) and is_binary(value),
    do: %{"name" => name, "value" => value}

  defp completion_argument(%{} = argument), do: argument

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
