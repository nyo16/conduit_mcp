defmodule ConduitMcp.Client.Request do
  @moduledoc """
  The caller side of a client request, and the request envelope.

  `ConduitMcp.Client` functions call `run/4` **in the calling process**. It
  never uses `GenServer.call`: it monitors the connection with an alias,

      mref = :erlang.monitor(:process, connection, [{:alias, :demonitor}])

  sends `{:"$mcp_request", mref, self(), method, params, wire_opts}`, and
  waits in one `receive` for messages tagged with `mref`:

    * `{:accepted, id}` - the connection sent the request with JSON-RPC id
      `id`.
    * `{:progress, params}` - a `notifications/progress` for it; passed to
      `:on_progress`.
    * `{:result, map}` - the connection completed the request itself (for
      example a modern `set_log_level`, which sends nothing).
    * `{:deadline, ms}` - the deadline moved: a legacy server request tied
      to this one is running in the client's handler (the deadline is
      paused, bounded by `:max_total_timeout`), or ended.
    * `{:error, %ConduitMcp.Client.Error{}}` - the connection refused or
      failed it.
    * `{:DOWN, mref, ...}` - the connection exited (`kind:
      :connection_down`).

  The connection owns the deadline: when it passes, the connection cancels
  the request on the wire and answers `kind: :timeout`. The caller's own
  `after` (the deadline plus a short grace) is only a safety net for a
  wedged connection; it sends `{:"$mcp_cancel", mref, :caller_timeout}`.
  `:erlang.demonitor(mref, [:flush])` deactivates the alias when `run/4`
  returns, so a response racing the timeout is dropped by the runtime and
  never reaches the caller's mailbox.

  If the caller dies, the connection sees it through its own monitor and
  cancels the request (`ConduitMcp.Client.Transport` "Cancellation").

  A JSON-RPC error answer `-32022` (the server no longer accepts the
  negotiated version) is retried once: the connection re-negotiates before
  it sends the retry.

  ## Telemetry

  Each request sent is one `[:conduit_mcp, :client, :request, :start |
  :stop | :exception]` span, emitted in the caller (see
  `ConduitMcp.Telemetry`).
  """

  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Telemetry

  @grace_ms 100
  @unsupported_protocol_version ConduitMcp.Errors.unsupported_protocol_version()

  @protocol_version "io.modelcontextprotocol/protocolVersion"
  @client_capabilities "io.modelcontextprotocol/clientCapabilities"
  @client_info "io.modelcontextprotocol/clientInfo"
  @log_level "io.modelcontextprotocol/logLevel"

  @run_options [
    :timeout,
    :on_progress,
    :reset_timeout_on_progress,
    :max_total_timeout,
    :assigns,
    :extensions,
    :headers,
    :traceparent
  ]

  @typedoc """
  What to send: a JSON-RPC method, or an operation whose wire form depends on
  the negotiated era (resolved by the connection when it sends):

    * `:ping` - legacy `ping`, modern `server/discover`.
    * `{:set_log_level, level}` - legacy `logging/setLevel`; modern stores
      the level for the `logLevel` `_meta` of later requests.
    * `:roots_list_changed` - legacy `notifications/roots/list_changed`;
      refused in the modern era.
  """
  @type op :: String.t() | :ping | {:set_log_level, String.t()} | :roots_list_changed

  @typedoc "`fun.(params)`, or a pid receiving `{:mcp_progress, client, params}`."
  @type on_progress :: (map() -> any()) | pid() | nil

  @typedoc "What `envelope/2` needs from the negotiated connection."
  @type envelope_info :: %{
          required(:era) => :modern | :legacy,
          required(:version) => String.t(),
          required(:client_capabilities) => map(),
          required(:client_info) => map(),
          optional(:log_level) => String.t() | nil,
          optional(:progress_token) => term(),
          optional(:traceparent) => String.t() | nil
        }

  @doc """
  Sends `op` with `params` through `client` and waits for the answer.

  Returns the JSON-RPC `result` map, or `{:error, %ConduitMcp.Client.Error{}}`
  (a JSON-RPC error answer becomes `kind: :protocol` with reason
  `{:jsonrpc, code}` via `ConduitMcp.Client.Error.from_rpc_error/1`).

  `params` may carry a user `"_meta"` map; the connection merges the era's
  reserved keys over it (`envelope/2`).

  ## Options

    * `:timeout` - milliseconds before the request is cancelled (default
      the client's `:request_timeout`).
    * `:on_progress` - a one-arity function called with each
      `notifications/progress` params, or a pid sent
      `{:mcp_progress, client, params}`. Setting it asks the server for
      progress (a `progressToken` equal to the request id).
    * `:reset_timeout_on_progress` - each progress notification restarts
      the `:timeout` (default `false`), never past `:max_total_timeout`.
    * `:max_total_timeout` - the cap for the above (default the client's
      `:max_total_timeout`), and for a deadline paused while a legacy
      server request tied to this one runs in the client's handler.
    * `:assigns` - a map passed to `ConduitMcp.Client.Handler` callbacks as
      `ctx.assigns` for legacy server requests tied to this request (default
      the client's `:assigns`).
    * `:extensions` - extension capabilities to declare in this request's
      modern `clientCapabilities` (for example
      `%{"io.modelcontextprotocol/tasks" => %{}}`).
    * `:headers` - extra HTTP headers for a modern request over an `:http`
      transport, as lowercase `{name, value}` string pairs (the
      `Mcp-Param-*` headers of `ConduitMcp.Headers.param_headers/2`);
      ignored by other transports.
    * `:traceparent` - the W3C trace context to propagate (default: the
      caller's `Logger.metadata()[:traceparent]`). Sent in a modern
      request's `_meta` when it is well formed (`ConduitMcp.Era.traceparent/1`),
      unless the caller's `"_meta"` already has one; `tracestate` and
      `baggage` are never added.

  ## Example

      {:ok, %{"tools" => _}} = ConduitMcp.Client.Request.run(MyApp.Docs, "tools/list", %{})
  """
  @spec run(term(), op(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(client, op, params \\ %{}, opts \\ []) when is_map(params) do
    opts = Keyword.validate!(opts, @run_options)

    case send_traced(client, op, params, opts) do
      {:error, %Error{reason: {:jsonrpc, @unsupported_protocol_version}}} ->
        send_traced(client, op, params, opts)

      result ->
        result
    end
  end

  defp send_traced(client, op, params, opts) do
    with {:ok, pid, view} <- lookup(client) do
      settings = settings(view, opts)
      base = Telemetry.base(client, view.server_id, view.transport, view.era)

      Telemetry.request_span(base, method_name(op), fn ->
        attempt(client, pid, op, params, settings)
      end)
    end
  end

  @doc """
  Resolves `client` to its connection pid and its caller view: the value the
  connection registers under `{:client, name}` (see
  `ConduitMcp.Client.Registry`) merged with its current status from
  `ConduitMcp.Client.Cache` (`state`, `era`, `version`, `reason`, `origin`,
  `server`).
  """
  @spec lookup(term()) :: {:ok, pid(), map()} | {:error, Error.t()}
  def lookup(client) do
    case Registry.lookup({:client, client}) do
      {:ok, pid, %{cache: cache} = view} ->
        with {:ok, status} <- Cache.status(cache), do: {:ok, pid, Map.merge(view, status)}

      {:ok, _pid, :starting} ->
        {:error, Error.new(:unavailable, :starting)}

      :error ->
        {:error, Error.new(:unavailable, :not_started)}
    end
  end

  @doc """
  Sends a control `op` to `client`'s connection and returns its reply, or
  `{:error, %Error{}}` on timeout or when the connection is gone.
  """
  @spec call(term(), term(), timeout()) :: term()
  def call(client, op, timeout) do
    case Registry.lookup({:client, client}) do
      {:ok, pid, _value} ->
        mref = :erlang.monitor(:process, pid, [{:alias, :demonitor}])
        send(pid, {:"$mcp_call", mref, op})

        try do
          receive do
            {^mref, reply} -> reply
            {:DOWN, ^mref, :process, _pid, reason} -> {:error, connection_down(reason)}
          after
            timeout -> {:error, Error.new(:timeout)}
          end
        after
          :erlang.demonitor(mref, [:flush])
        end

      :error ->
        {:error, Error.new(:unavailable, :not_started)}
    end
  end

  @doc """
  The wire `params` of a request: `params` with the era's reserved `_meta`
  keys merged over the caller's `"_meta"`.

    * Modern: `io.modelcontextprotocol/protocolVersion`, `clientCapabilities`,
      `clientInfo`, `logLevel` when one is set, and `traceparent` (unless the
      caller's `_meta` has one) when `info.traceparent` is set.
    * Both eras: `progressToken` when `info.progress_token` is set.

  Reserved keys always win: any caller key named `progressToken`, or whose
  prefix (before `/`) has a `modelcontextprotocol` or `mcp` label, is
  dropped. An empty `_meta` is omitted.

      iex> ConduitMcp.Client.Request.envelope(
      ...>   %{"name" => "echo", "_meta" => %{"progressToken" => "x", "trace" => "t"}},
      ...>   %{era: :legacy, version: "2025-11-25", client_capabilities: %{},
      ...>     client_info: %{}, progress_token: 7}
      ...> )
      %{"name" => "echo", "_meta" => %{"progressToken" => 7, "trace" => "t"}}
  """
  @spec envelope(map(), envelope_info()) :: map()
  def envelope(params, info) when is_map(params) do
    user_meta =
      case params do
        %{"_meta" => meta} when is_map(meta) -> meta
        _ -> %{}
      end

    meta =
      user_meta
      |> Map.reject(fn {key, _value} -> reserved_key?(key) end)
      |> Map.merge(reserved_meta(info))
      |> put_traceparent(info)

    if meta == %{}, do: Map.delete(params, "_meta"), else: Map.put(params, "_meta", meta)
  end

  defp put_traceparent(meta, %{era: :modern, traceparent: traceparent})
       when is_binary(traceparent),
       do: Map.put_new(meta, "traceparent", traceparent)

  defp put_traceparent(meta, _info), do: meta

  defp reserved_meta(%{era: :modern} = info) do
    %{
      @protocol_version => info.version,
      @client_capabilities => info.client_capabilities,
      @client_info => info.client_info
    }
    |> put_present(@log_level, Map.get(info, :log_level))
    |> put_present("progressToken", Map.get(info, :progress_token))
  end

  defp reserved_meta(%{era: :legacy} = info),
    do: put_present(%{}, "progressToken", Map.get(info, :progress_token))

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp reserved_key?("progressToken"), do: true

  defp reserved_key?(key) when is_binary(key) do
    case String.split(key, "/", parts: 2) do
      [prefix, _name] ->
        prefix |> String.split(".") |> Enum.any?(&(&1 in ["modelcontextprotocol", "mcp"]))

      [_no_prefix] ->
        false
    end
  end

  defp reserved_key?(_key), do: false

  @doc false
  # The telemetry `method` of an op.
  @spec method_name(op()) :: String.t()
  def method_name(method) when is_binary(method), do: method
  def method_name(:ping), do: "ping"
  def method_name({:set_log_level, _level}), do: "logging/setLevel"
  def method_name(:roots_list_changed), do: "notifications/roots/list_changed"

  # --- one attempt ---------------------------------------------------------

  defp settings(view, opts) do
    now = now_ms()
    timeout = Keyword.get(opts, :timeout, view.request_timeout)
    max_total = Keyword.get(opts, :max_total_timeout, view.max_total_timeout)
    on_progress = Keyword.get(opts, :on_progress)
    reset? = Keyword.get(opts, :reset_timeout_on_progress, false)
    assigns = Keyword.get(opts, :assigns)
    extensions = Keyword.get(opts, :extensions, %{})
    headers = Keyword.get(opts, :headers, [])
    traceparent = Keyword.get_lazy(opts, :traceparent, fn -> Logger.metadata()[:traceparent] end)

    for {key, value} <- [timeout: timeout, max_total_timeout: max_total],
        not (is_integer(value) and value > 0) do
      raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
    end

    unless on_progress == nil or is_pid(on_progress) or is_function(on_progress, 1) do
      raise ArgumentError,
            ":on_progress must be a one-arity function or a pid, got: #{inspect(on_progress)}"
    end

    unless assigns == nil or is_map(assigns) do
      raise ArgumentError, ":assigns must be a map, got: #{inspect(assigns)}"
    end

    unless is_map(extensions) do
      raise ArgumentError, ":extensions must be a map, got: #{inspect(extensions)}"
    end

    unless is_list(headers) and
             Enum.all?(
               headers,
               &match?({name, value} when is_binary(name) and is_binary(value), &1)
             ) do
      raise ArgumentError, ":headers must be a list of {name, value} strings"
    end

    %{
      timeout: timeout,
      deadline: now + timeout,
      max_deadline: now + max(timeout, max_total),
      reset?: reset? == true,
      on_progress: on_progress,
      assigns: assigns,
      extensions: extensions,
      headers: headers,
      traceparent: ConduitMcp.Era.traceparent(traceparent)
    }
  end

  defp wire_opts(settings) do
    [
      deadline: settings.deadline,
      max_deadline: settings.max_deadline,
      timeout: settings.timeout,
      reset_on_progress: settings.reset?,
      progress: settings.on_progress != nil or settings.reset?,
      assigns: settings.assigns,
      extensions: settings.extensions,
      headers: settings.headers,
      traceparent: settings.traceparent
    ]
  end

  defp attempt(client, pid, op, params, settings) do
    mref = :erlang.monitor(:process, pid, [{:alias, :demonitor}])
    send(pid, {:"$mcp_request", mref, self(), op, params, wire_opts(settings)})

    try do
      await(%{client: client, pid: pid, mref: mref, id: nil}, settings)
    after
      :erlang.demonitor(mref, [:flush])
    end
  end

  defp await(%{mref: mref} = req, settings) do
    receive do
      {^mref, {:accepted, id}} ->
        await(%{req | id: id}, settings)

      {^mref, {:progress, params}} ->
        progress(settings.on_progress, req.client, params)
        await(req, extend(settings))

      {^mref, {:deadline, deadline}} ->
        await(req, %{settings | deadline: deadline})

      {^mref, {:response, message}} ->
        {decode(message), %{request_id: req.id}}

      {^mref, {:result, result}} ->
        {{:ok, result}, %{request_id: req.id}}

      {^mref, {:error, %Error{} = error}} ->
        {{:error, error}, %{request_id: req.id}}

      {:DOWN, ^mref, :process, _pid, reason} ->
        {{:error, connection_down(reason)}, %{request_id: req.id}}
    after
      max(settings.deadline - now_ms(), 0) + @grace_ms ->
        send(req.pid, {:"$mcp_cancel", mref, :caller_timeout})
        {{:error, Error.new(:timeout)}, %{request_id: req.id}}
    end
  end

  defp progress(nil, _client, _params), do: :ok

  defp progress(pid, client, params) when is_pid(pid),
    do: send(pid, {:mcp_progress, client, params})

  defp progress(fun, _client, params), do: fun.(params)

  # Mirrors the connection's re-arm (`Connection.Requests`), so the safety
  # net never fires before the real deadline; it never moves the deadline
  # back, since a paused deadline already sits at the maximum.
  defp extend(%{reset?: true} = settings) do
    deadline = min(now_ms() + settings.timeout, settings.max_deadline)
    %{settings | deadline: max(settings.deadline, deadline)}
  end

  defp extend(settings), do: settings

  defp decode(%{"result" => result}) when is_map(result), do: {:ok, result}
  defp decode(%{"error" => error}), do: {:error, Error.from_rpc_error(error)}
  defp decode(_message), do: {:error, Error.new(:protocol, :invalid_response)}

  # Only the exit's tag: the reason of a crashed connection can carry its
  # state, which is not the caller's to see.
  defp connection_down(reason), do: Error.new(:connection_down, Telemetry.reason_tag(reason))

  defp now_ms, do: System.monotonic_time(:millisecond)
end
