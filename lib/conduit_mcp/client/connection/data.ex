defmodule ConduitMcp.Client.Connection.Data do
  @moduledoc false

  # The connection's state data, the caller view it publishes into the
  # registry, and the wrappers that thread transport state through it.

  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Config
  alias ConduitMcp.Client.Connection.Listen
  alias ConduitMcp.Client.Negotiation
  alias ConduitMcp.Client.RateLimit
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Request
  alias ConduitMcp.Client.Telemetry

  defstruct [
    :config,
    :name,
    :transport,
    :tstate,
    :task_sup,
    :kind,
    # The negotiated era and version; kept across reconnects until the next
    # handshake replaces them.
    era: nil,
    version: nil,
    # `:legacy` when the next attempt should skip the probe (a `prior:`, or
    # a server that exited on the probe). Consumed by one attempt.
    era_hint: nil,
    # Set once a modern handshake succeeded: later handshakes never fall
    # back to legacy (X-16).
    era_lock: nil,
    # %{server_info: ServerInfo.t() | nil, capabilities: map(), instructions: String.t() | nil}
    server: nil,
    # Request ids are allocated here, never reset, never reused.
    next_id: 1,
    # id => entry (see `ConduitMcp.Client.Connection.Requests`)
    pending: %{},
    # caller alias ref or caller monitor ref => id
    refs: %{},
    # The connection's own requests: id => :discover | :initialize | :health
    internal: %{},
    # The handshake in progress: %{id:, mode: :probe | :pinned, tried: [version], skipped_probe?: boolean}
    handshake: nil,
    # monitor ref => subscriber pid
    subscribers: %{},
    # list_changed method => :quiet | {:again, params}; and, per cached
    # kind, {:refetch, kind} => %{at: last list_changed refresh start
    # (monotonic ms), deferred?: held back by the once-a-second cap}
    coalesce: %{},
    queued: 0,
    attempt: 0,
    reason: nil,
    log_level: nil,
    # The health check in flight: `{request id | nil, consecutive misses}`.
    health: {nil, 0},
    # The client's `ConduitMcp.Client.Cache` table (this process writes it).
    cache: nil,
    # `ConduitMcp.Client.Input.settings()`: what handler code needs, shared
    # with callers through the registry value.
    input: nil,
    # The server's origin when the transport reported one on connect.
    origin: nil,
    # Legacy server-to-client requests running in handler tasks:
    # server request id => %{ref:, pid:, related:}
    server_requests: %{},
    # Cache refreshes running in tasks: kind => %{ref:, waiters:, again?:,
    # trigger:, started:}
    refreshes: %{},
    # Callers awaiting a task (`ConduitMcp.Client.await_task/3`): monitor
    # ref => {pid, task id}; the task is cancelled if the caller dies.
    watches: %{},
    # The process running the handler's notification callbacks, or nil
    # (`ConduitMcp.Client.Connection.Notifier`).
    notifier: nil,
    # `ConduitMcp.Client.Connection.Listen`'s state: `subs`, the resource
    # URIs the client wants updates for (kept across reconnects); modern
    # `listens`: id => %{filter:, status: :pending | :active, acked:}; the
    # `active` (acknowledged) one; `waiters`, callers awaiting a
    # subscription change: [{mref, op, uri}]; the reopen backoff `attempt`;
    # and `off?`, whether the server refused listen.
    listen: nil
  ]

  @type t :: %__MODULE__{}

  @doc """
  Which of this process's tasks `ref` belongs to: `{:server_request, id}`,
  `{:refresh, kind}`, or `:error`. (At most `:max_server_requests` plus one
  per list kind run at once.)
  """
  @spec job(t(), reference()) :: {:server_request, term()} | {:refresh, atom()} | :error
  def job(data, ref) do
    cond do
      id = find_ref(data.server_requests, ref) -> {:server_request, id}
      kind = find_ref(data.refreshes, ref) -> {:refresh, kind}
      true -> :error
    end
  end

  defp find_ref(jobs, ref), do: Enum.find_value(jobs, fn {key, job} -> job.ref == ref && key end)

  @spec new(Config.t(), pid(), term()) :: t()
  def new(%Config{} = config, task_sup, tstate) do
    {transport, _opts} = config.transport
    rate = config.input_rate_limit

    %__MODULE__{
      config: config,
      name: config.name,
      transport: transport,
      tstate: tstate,
      task_sup: task_sup,
      kind: transport.kind(),
      era_hint: if(config.prior == :legacy, do: :legacy),
      cache: Cache.new(),
      listen: Listen.new(),
      input: %{
        handler: config.handler,
        sampling: config.sampling,
        elicitation: config.elicitation,
        limiter: RateLimit.new(rate[:per_second], rate[:burst]),
        assigns: config.assigns
      }
    }
  end

  @doc """
  The caller view published once as the registry value of `{:client, name}`:
  what `ConduitMcp.Client.Request` and the read-only `ConduitMcp.Client`
  functions need without messaging the connection. The state that changes
  (`publish/2`) lives in the cache table, whose id is here.
  """
  @spec view(t()) :: map()
  def view(%__MODULE__{config: config} = data) do
    %{
      task_sup: data.task_sup,
      server_id: config.server_id,
      transport: data.kind,
      request_timeout: config.request_timeout,
      max_total_timeout: config.max_total_timeout,
      client_capabilities: capabilities(config, :modern),
      cache: data.cache,
      input: data.input
    }
  end

  @doc """
  Writes the connection's state into the cache's `:status` and `:server`
  rows, and the era into the connection's Logger metadata (it runs in the
  connection).
  """
  @spec publish(t(), atom()) :: :ok
  def publish(data, state) do
    Logger.metadata(mcp_era: data.era)

    Cache.put_status(data.cache, %{
      state: state,
      reason: if(state == :closed, do: data.reason),
      era: data.era,
      version: data.version,
      origin: data.config.elicitation[:origin] || data.origin
    })

    Cache.put_server(data.cache, if(state == :ready, do: data.server))
    :ok
  end

  @doc "Publishes the static view (once, from `init`)."
  @spec register(t()) :: :ok
  def register(data), do: Registry.put_value({:client, data.name}, view(data))

  @spec telemetry(t()) :: Telemetry.base()
  def telemetry(data),
    do: Telemetry.base(data.name, data.config.server_id, data.kind, data.era)

  @doc "The client capabilities for `era`."
  @spec client_capabilities(t(), :modern | :legacy) :: map()
  def client_capabilities(%__MODULE__{config: config}, era), do: capabilities(config, era)

  # Derived from the handler's callbacks; `roots.listChanged` (legacy only)
  # is promised when configured: the host announces changes with
  # `ConduitMcp.Client.notify_roots_changed/1`.
  defp capabilities(config, era) do
    Negotiation.client_capabilities(config.handler,
      era: era,
      sampling_tools: config.sampling[:tools],
      sampling_context: config.sampling[:context],
      roots_list_changed: config.roots[:list_changed]
    )
  end

  @doc "Takes the next request id."
  @spec take_id(t()) :: {pos_integer(), t()}
  def take_id(%__MODULE__{next_id: id} = data), do: {id, %{data | next_id: id + 1}}

  @doc """
  Builds and sends a request through the transport. `info` overrides the
  envelope fields (era, version, progress token).
  """
  @spec send_request(t(), pos_integer(), String.t(), map(), map(), reference() | nil, keyword()) ::
          {:ok, term(), t()} | {:error, term(), t()}
  def send_request(data, id, method, params, info, reply_to, wire_opts) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => Request.envelope(params, envelope_info(data, info))
    }

    case data.transport.request(data.tstate, message, reply_to, wire_opts) do
      {:ok, handle, tstate} -> {:ok, handle, %{data | tstate: tstate}}
      {:error, reason, tstate} -> {:error, reason, %{data | tstate: tstate}}
    end
  end

  defp envelope_info(data, info) do
    era = Map.get(info, :era, data.era)

    %{
      era: era,
      version: data.version,
      client_capabilities: client_capabilities(data, era),
      client_info: data.config.client_info,
      log_level: data.log_level
    }
    |> Map.merge(info)
    |> put_extensions()
  end

  # Per-request extension capabilities (the tasks extension is asked for
  # only on the requests that use it).
  defp put_extensions(%{extensions: extensions, client_capabilities: caps} = info)
       when map_size(extensions) > 0,
       do: %{info | client_capabilities: Map.put(caps, "extensions", extensions)}

  defp put_extensions(info), do: info

  @doc "Sends a notification through the transport."
  @spec notify(t(), String.t(), map()) :: {:ok, t()} | {:error, term(), t()}
  def notify(data, method, params) do
    message = %{"jsonrpc" => "2.0", "method" => method, "params" => params}

    case data.transport.notify(data.tstate, message) do
      {:ok, tstate} -> {:ok, %{data | tstate: tstate}}
      {:error, reason, tstate} -> {:error, reason, %{data | tstate: tstate}}
    end
  end

  @doc "Cancels a request through the transport."
  @spec cancel(t(), pos_integer(), term(), atom()) :: t()
  def cancel(data, id, handle, reason) do
    {:ok, tstate} = data.transport.cancel(data.tstate, id, handle, reason)
    %{data | tstate: tstate}
  end

  @doc "Sends a response to a server request, when the transport can."
  @spec respond(t(), map()) :: t()
  def respond(data, message) do
    if function_exported?(data.transport, :respond, 2) do
      case data.transport.respond(data.tstate, message) do
        {:ok, tstate} -> %{data | tstate: tstate}
        {:error, _reason, tstate} -> %{data | tstate: tstate}
      end
    else
      data
    end
  end

  @doc """
  Tells the transport the negotiated session, when it wants to know. The
  era goes into the connection's Logger metadata first, so processes the
  transport starts for the session inherit it.
  """
  @spec set_session(t()) :: t()
  def set_session(data) do
    Logger.metadata(mcp_era: data.era)

    if function_exported?(data.transport, :set_session, 2),
      do: %{data | tstate: data.transport.set_session(data.tstate, session(data))},
      else: data
  end

  defp session(data), do: %{era: data.era, version: data.version}

  @doc "Closes the transport (if open); the next attempt re-runs `init/2`."
  @spec close_transport(t(), term()) :: t()
  def close_transport(%__MODULE__{tstate: nil} = data, _reason), do: data

  def close_transport(data, reason) do
    :ok = data.transport.close(data.tstate, reason)
    %{data | tstate: nil}
  end
end
