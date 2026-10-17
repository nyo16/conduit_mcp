defmodule ConduitMcp.Client.Connection.Data do
  @moduledoc false

  # The connection's state data, the caller view it publishes into the
  # registry, and the wrappers that thread transport state through it.

  alias ConduitMcp.Client.Config
  alias ConduitMcp.Client.Negotiation
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
    # list_changed method => :quiet | {:again, params}
    coalesce: %{},
    queued: 0,
    attempt: 0,
    reason: nil,
    log_level: nil,
    health_id: nil,
    health_misses: 0
  ]

  @type t :: %__MODULE__{}

  @spec new(Config.t(), pid(), term()) :: t()
  def new(%Config{} = config, task_sup, tstate) do
    {transport, _opts} = config.transport

    %__MODULE__{
      config: config,
      name: config.name,
      transport: transport,
      tstate: tstate,
      task_sup: task_sup,
      kind: transport.kind(),
      era_hint: if(config.prior == :legacy, do: :legacy)
    }
  end

  @doc """
  The caller view published as the registry value of `{:client, name}`:
  what `ConduitMcp.Client.Request` and the read-only `ConduitMcp.Client`
  functions need without messaging the connection.
  """
  @spec view(t(), atom()) :: map()
  def view(%__MODULE__{config: config} = data, state) do
    %{
      task_sup: data.task_sup,
      server_id: config.server_id,
      transport: data.kind,
      request_timeout: config.request_timeout,
      max_total_timeout: config.max_total_timeout,
      client_capabilities: Negotiation.client_capabilities(config.handler, era: :modern),
      state: state,
      reason: if(state == :closed, do: data.reason),
      era: data.era,
      version: data.version,
      server: if(state == :ready, do: data.server)
    }
  end

  @spec publish(t(), atom()) :: :ok
  def publish(data, state), do: Registry.put_value({:client, data.name}, view(data, state))

  @spec telemetry(t()) :: Telemetry.base()
  def telemetry(data),
    do: Telemetry.base(data.name, data.config.server_id, data.kind, data.era)

  @doc "The client capabilities for `era`."
  @spec client_capabilities(t(), :modern | :legacy) :: map()
  def client_capabilities(%__MODULE__{config: config}, :legacy) do
    # `roots.listChanged` is promised whenever roots are: the host announces
    # changes with `ConduitMcp.Client.notify_roots_changed/1`.
    Negotiation.client_capabilities(config.handler, era: :legacy, roots_list_changed: true)
  end

  def client_capabilities(%__MODULE__{config: config}, :modern),
    do: Negotiation.client_capabilities(config.handler, era: :modern)

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

    Map.merge(
      %{
        era: era,
        version: data.version,
        client_capabilities: client_capabilities(data, era),
        client_info: data.config.client_info,
        log_level: data.log_level
      },
      info
    )
  end

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

  @doc "Tells the transport the negotiated session, when it wants to know."
  @spec set_session(t()) :: t()
  def set_session(data) do
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
