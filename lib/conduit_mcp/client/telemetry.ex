defmodule ConduitMcp.Client.Telemetry do
  @moduledoc false

  # Every `[:conduit_mcp, :client, ...]` event, emitted with literal event
  # names (documented in `ConduitMcp.Telemetry`). Metadata is built here from
  # an allowlist only (TL-1): client name, server id, method, sanitized tool
  # name, era, transport kind, closed-set atoms and request ids. Never
  # `_meta`, tokens or raw error data, and never arguments or results except
  # through the opt-in, host-redacted, size-capped `:capture_payloads` of the
  # `tool_call` span (TL-2; `payload/2`). No digest of a payload is emitted
  # either: low-entropy arguments are brute-forceable from one.
  #
  # Spans (`request`, `tool_call`, modern `input_request`) run in the
  # caller, and `tool.rejected` in the process that fetched the list (a
  # caller, or a cache refresh task); the rest run inside the connection
  # process.
  #
  # Logger metadata (`mcp_client`, `mcp_server`, `mcp_transport`,
  # `mcp_era`) is set only in processes the client spawns: the connection,
  # its transport processes and its tasks. A caller's Logger metadata is
  # never touched.

  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.ToolResult
  alias ConduitMcp.Reflect

  @logger_keys [:mcp_client, :mcp_server, :mcp_transport, :mcp_era]

  # `transport.mailbox` sampling: every this many transport messages, and
  # emitted above this queue length.
  @mailbox_every 64
  @mailbox_limit 1_000

  # The `input_request` span's `:method` is one of these or `nil`: a closed
  # set, so it may be a metric tag.
  @input_methods ["sampling/createMessage", "elicitation/create", "roots/list"]

  @type base :: %{
          client: term(),
          server_id: String.t(),
          transport: atom(),
          era: :modern | :legacy | nil
        }

  @doc "The allowlisted base metadata."
  @spec base(term(), String.t(), atom(), :modern | :legacy | nil) :: base()
  def base(client, server_id, transport, era),
    do: %{client: client, server_id: server_id, transport: transport, era: era}

  @doc "The Logger metadata of a process working for the client `base` describes."
  @spec logger_metadata(base()) :: keyword()
  def logger_metadata(%{client: client, server_id: server_id, transport: transport, era: era}) do
    [
      mcp_client: Reflect.text(client, 64),
      mcp_server: server_id,
      mcp_transport: transport,
      mcp_era: era
    ]
  end

  @doc """
  The client Logger metadata of the current process (a client process), to
  hand to a process it spawns: `Logger.metadata(md)` there.
  """
  @spec inherited_logger_metadata() :: keyword()
  def inherited_logger_metadata, do: Keyword.take(Logger.metadata(), @logger_keys)

  @doc """
  Runs `fun` inside a `[:conduit_mcp, :client, :input_request, ...]` span.
  `fun` returns `{:ok, _}` or `{:error, _}`.
  """
  @spec input_request_span(base(), term(), (-> result)) :: result when result: term()
  def input_request_span(base, method, fun) do
    meta = Map.put(base, :method, if(method in @input_methods, do: method))
    start = System.monotonic_time()

    :telemetry.execute(
      [:conduit_mcp, :client, :input_request, :start],
      %{monotonic_time: start, system_time: System.system_time()},
      meta
    )

    try do
      result = fun.()

      :telemetry.execute(
        [:conduit_mcp, :client, :input_request, :stop],
        stop_measurements(start, %{}),
        Map.put(meta, :status, if(match?({:ok, _}, result), do: :ok, else: :error))
      )

      result
    catch
      kind, reason ->
        :telemetry.execute(
          [:conduit_mcp, :client, :input_request, :exception],
          stop_measurements(start, %{}),
          Map.put(meta, :kind, kind)
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  Counts one transport message in the calling (connection) process; true
  every #{@mailbox_every}th, when `mailbox/1` should sample the queue. The
  count is an observability side channel, so it lives in the process
  dictionary rather than the connection's state.
  """
  @spec mailbox_due?() :: boolean()
  def mailbox_due? do
    count = Process.get(:conduit_mcp_inbound, 0) + 1

    if count >= @mailbox_every do
      Process.put(:conduit_mcp_inbound, 0)
      true
    else
      Process.put(:conduit_mcp_inbound, count)
      false
    end
  end

  @doc """
  Emits `transport.mailbox` when the calling (connection) process holds
  more than #{@mailbox_limit} messages.
  """
  @spec mailbox(base()) :: :ok
  def mailbox(base) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, queued} when queued > @mailbox_limit ->
        :telemetry.execute(
          [:conduit_mcp, :client, :transport, :mailbox],
          %{message_queue_len: queued},
          base
        )

      _other ->
        :ok
    end
  end

  @doc """
  Runs `fun` inside a `[:conduit_mcp, :client, :request, ...]` span. `fun`
  returns `{result, extra_stop_metadata}`.
  """
  @spec request_span(base(), String.t(), (-> {result, map()})) :: result when result: term()
  def request_span(base, method, fun) do
    meta = Map.put(base, :method, method)
    start = System.monotonic_time()

    :telemetry.execute(
      [:conduit_mcp, :client, :request, :start],
      %{monotonic_time: start, system_time: System.system_time()},
      meta
    )

    try do
      {result, extra} = fun.()

      :telemetry.execute(
        [:conduit_mcp, :client, :request, :stop],
        stop_measurements(start, %{}),
        meta |> Map.merge(status(result)) |> Map.merge(extra)
      )

      result
    catch
      kind, reason ->
        :telemetry.execute(
          [:conduit_mcp, :client, :request, :exception],
          stop_measurements(start, %{}),
          Map.put(meta, :kind, kind)
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @typedoc "`false`, or the validated `:telemetry` `:capture_payloads` (TL-2)."
  @type capture :: false | %{redact: (term() -> term()), max_bytes: pos_integer()}

  @doc """
  Runs `fun` inside a `[:conduit_mcp, :client, :tool_call, ...]` span. `fun`
  returns `{result, rounds}`.

  With `capture` enabled, `:start` carries `:arguments` (`args` through
  `payload/2`) and `:stop` carries `:result` (the tool result's wire map
  through `payload/2`, `nil` for an error or a task); both are computed
  here, in the caller. With `capture` `false` neither key is present.
  """
  @spec tool_call_span(base(), String.t(), map(), capture(), (-> {result, non_neg_integer()})) ::
          result
        when result: term()
  def tool_call_span(base, tool_name, args, capture, fun) do
    meta = Map.put(base, :tool_name, Reflect.text(tool_name, 128))
    start = System.monotonic_time()

    :telemetry.execute(
      [:conduit_mcp, :client, :tool_call, :start],
      %{monotonic_time: start, system_time: System.system_time()},
      captured(meta, capture, :arguments, args)
    )

    try do
      {result, rounds} = fun.()

      stop_meta =
        meta
        |> Map.merge(status(result))
        |> Map.put(:is_error, error_flag(result))
        |> captured(capture, :result, result_wire(result))

      :telemetry.execute(
        [:conduit_mcp, :client, :tool_call, :stop],
        stop_measurements(start, %{rounds: rounds}),
        stop_meta
      )

      result
    catch
      kind, reason ->
        :telemetry.execute(
          [:conduit_mcp, :client, :tool_call, :exception],
          stop_measurements(start, %{}),
          Map.put(meta, :kind, kind)
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp captured(meta, %{} = _capture, key, nil), do: Map.put(meta, key, nil)
  defp captured(meta, %{} = capture, key, value), do: Map.put(meta, key, payload(capture, value))
  defp captured(meta, _off, _key, _value), do: meta

  # What the server sent, minus `_meta` (the transport's and the server's
  # side channel, never a payload). Errors and tasks carry no result.
  defp result_wire({:ok, %ToolResult{} = result}) do
    wire = %{"content" => result.content, "isError" => result.is_error}

    if result.structured == nil,
      do: wire,
      else: Map.put(wire, "structuredContent", result.structured)
  end

  defp result_wire(_other), do: nil

  @doc """
  One captured payload (TL-2): `redact.(value)` when it JSON-encodes within
  `max_bytes`; `{:truncated, byte_size}` when it encodes larger (never a
  partial value); `:redaction_failed` when `redact` raises, throws or exits,
  or returns something that cannot be JSON-encoded - a
  `ConduitMcp.Client.Secret` included, whose encoder raises - so the raw
  value never gets through.
  """
  @spec payload(%{redact: (term() -> term()), max_bytes: pos_integer()}, term()) ::
          term() | {:truncated, pos_integer()} | :redaction_failed
  def payload(%{redact: redact, max_bytes: max_bytes}, value) do
    redacted = redact.(value)
    size = redacted |> JSON.encode_to_iodata!() |> IO.iodata_length()

    if size > max_bytes, do: {:truncated, size}, else: redacted
  catch
    _kind, _reason -> :redaction_failed
  end

  @doc """
  A policy decision for one call, read or get. `decision` is a
  `ConduitMcp.Client.Policy.Decision` (or a map with its keys); `approval`
  says how an `:ask` was settled (`nil` otherwise). `extra` carries the
  allowlisted target keys (`:target`, and `:tool_name` for a tool) and
  `:principal` when the host supplied one.
  """
  @spec policy_decision(base(), map(), atom() | nil, map()) :: :ok
  def policy_decision(base, decision, approval, extra) do
    :telemetry.execute(
      [:conduit_mcp, :client, :policy, :decision],
      %{count: 1},
      base
      |> Map.merge(extra)
      |> Map.merge(Map.take(decision, [:decision, :source, :rule_id, :reason]))
      |> Map.put(:approval, approval)
    )
  end

  @doc "A hook returned within its contract. `start` is native monotonic time."
  @spec hook_stop(map(), term(), atom(), integer(), atom()) :: :ok
  def hook_stop(base, hook_id, kind, start, status) do
    :telemetry.execute(
      [:conduit_mcp, :client, :hook, :stop],
      stop_measurements(start, %{}),
      Map.merge(base, %{hook_id: hook_id, kind: kind, status: status})
    )
  end

  @doc "A hook failed (raise, exit, timeout or a bad return)."
  @spec hook_exception(map(), term(), atom(), integer(), atom()) :: :ok
  def hook_exception(base, hook_id, kind, start, reason) do
    :telemetry.execute(
      [:conduit_mcp, :client, :hook, :exception],
      stop_measurements(start, %{}),
      Map.merge(base, %{hook_id: hook_id, kind: kind, reason: reason})
    )
  end

  @doc "A tool name as it may appear in metadata (sanitized, capped)."
  @spec tool_name(String.t()) :: String.t()
  def tool_name(name), do: Reflect.text(name, 128)

  @doc "A connection state change."
  @spec transition(base(), atom() | nil, atom(), term(), non_neg_integer()) :: :ok
  def transition(base, from, to, reason, attempt) do
    :telemetry.execute(
      [:conduit_mcp, :client, :connection, :transition],
      %{system_time: System.system_time()},
      Map.merge(base, %{from: from, to: to, reason: reason_tag(reason), attempt: attempt})
    )
  end

  @doc "The connection cancelled an in-flight request."
  @spec cancel(base(), String.t(), term(), atom()) :: :ok
  def cancel(base, method, request_id, reason) do
    :telemetry.execute(
      [:conduit_mcp, :client, :request, :cancel],
      %{count: 1},
      Map.merge(base, %{method: method, request_id: request_id, reason: reason})
    )
  end

  @doc "A response for an unknown or no longer pending id was dropped."
  @spec dropped(base(), term()) :: :ok
  def dropped(base, request_id) do
    :telemetry.execute(
      [:conduit_mcp, :client, :response, :dropped],
      %{count: 1},
      Map.put(base, :request_id, if(is_integer(request_id), do: request_id))
    )
  end

  @doc "A server notification reached the connection."
  @spec notification(base(), term()) :: :ok
  def notification(base, method) do
    :telemetry.execute(
      [:conduit_mcp, :client, :notification],
      %{count: 1},
      Map.put(base, :method, Reflect.text(method, 64))
    )
  end

  @doc "A `notifications/message` over the connection's `:log_rate_limit` was dropped."
  @spec log_dropped(base()) :: :ok
  def log_dropped(base),
    do: :telemetry.execute([:conduit_mcp, :client, :log, :dropped], %{count: 1}, base)

  @doc """
  A listed tool was excluded at intake. `tool_name` is already sanitized
  (or `nil` when the server sent no string name).
  """
  @spec tool_rejected(base(), String.t() | nil, atom()) :: :ok
  def tool_rejected(base, tool_name, reason) do
    :telemetry.execute(
      [:conduit_mcp, :client, :tool, :rejected],
      %{count: 1},
      Map.merge(base, %{tool_name: tool_name, reason: reason})
    )
  end

  @doc "A known tool's fingerprint changed on a refresh."
  @spec definition_changed(base(), String.t()) :: :ok
  def definition_changed(base, tool_name) do
    :telemetry.execute(
      [:conduit_mcp, :client, :tool, :definition_changed],
      %{count: 1},
      Map.put(base, :tool_name, Reflect.text(tool_name, 128))
    )
  end

  @doc "The connection started refreshing the cached `kind` list."
  @spec cache_refresh_start(base(), atom(), :demand | :list_changed) :: :ok
  def cache_refresh_start(base, kind, trigger) do
    :telemetry.execute(
      [:conduit_mcp, :client, :cache, :refresh, :start],
      %{monotonic_time: System.monotonic_time(), system_time: System.system_time()},
      Map.merge(base, %{kind: kind, trigger: trigger})
    )
  end

  @doc "A cache refresh started at `started` (native monotonic time) finished."
  @spec cache_refresh_stop(base(), atom(), :demand | :list_changed, integer(), term()) :: :ok
  def cache_refresh_stop(base, kind, trigger, started, result) do
    {counts, outcome} =
      case result do
        {:ok, %{items: items, pages: pages, rejected: rejected}} ->
          {%{count: length(items), pages: pages, rejected: rejected}, status(:ok)}

        other ->
          {%{count: 0, pages: 0, rejected: 0}, status(other)}
      end

    :telemetry.execute(
      [:conduit_mcp, :client, :cache, :refresh, :stop],
      stop_measurements(started, counts),
      base |> Map.merge(%{kind: kind, trigger: trigger}) |> Map.merge(outcome)
    )
  end

  # --- hub and adapters (metadata keyed by the hub or the source, not a client) ---

  @doc "A hub server's client exited; the hub retries in `delay_ms`."
  @spec hub_server_failed(term(), String.t(), pos_integer(), term(), non_neg_integer()) :: :ok
  def hub_server_failed(hub, server_id, attempt, reason, delay_ms) do
    :telemetry.execute(
      [:conduit_mcp, :client, :hub, :server_failed],
      %{count: 1, delay: delay_ms},
      %{hub: hub, server_id: server_id, attempt: attempt, reason: reason_tag(reason)}
    )
  end

  @doc "A hub server's client was started again after `attempt` failures."
  @spec hub_server_restarted(term(), String.t(), pos_integer()) :: :ok
  def hub_server_restarted(hub, server_id, attempt) do
    :telemetry.execute(
      [:conduit_mcp, :client, :hub, :server_restarted],
      %{count: 1},
      %{hub: hub, server_id: server_id, attempt: attempt}
    )
  end

  @doc """
  Tools of a hub mangled to one exposed name and were all left out.
  `colliders` are `{server_id, tool_name}`; tool names are sanitized here.
  """
  @spec hub_collision(term(), String.t(), [{String.t(), String.t()}]) :: :ok
  def hub_collision(hub, exposed_name, colliders) do
    :telemetry.execute(
      [:conduit_mcp, :client, :hub, :collision],
      %{count: length(colliders)},
      %{
        hub: hub,
        exposed_name: exposed_name,
        colliders: for({server_id, tool} <- colliders, do: {server_id, sanitize(tool)})
      }
    )
  end

  @doc """
  An OpenAI tool could not be converted to strict mode and was sent with
  `"strict": false`. `client` is the hub's or client's name; `reason` is
  the limit hit, or `:unsupported_keyword`.
  """
  @spec strict_fallback(term(), :chat | :responses, String.t(), term()) :: :ok
  def strict_fallback(client, api, exposed_name, error) do
    reason =
      case error do
        {:unsupported, _path, limit} when is_atom(limit) -> limit
        _keyword -> :unsupported_keyword
      end

    :telemetry.execute(
      [:conduit_mcp, :client, :adapter, :strict_fallback],
      %{count: 1},
      %{client: client, provider: :openai, api: api, tool_name: exposed_name, reason: reason}
    )
  end

  @doc "A tool name with every character outside `[A-Za-z0-9_-]` replaced by `_`, at most 128 bytes."
  @spec sanitize(String.t()) :: String.t()
  def sanitize(name), do: name |> ConduitMcp.Client.Naming.sanitize() |> binary_part_max(128)

  defp binary_part_max(text, max) when byte_size(text) <= max, do: text
  defp binary_part_max(text, max), do: binary_part(text, 0, max)

  @doc """
  A closed-set atom for a state-change reason: atoms pass through, a tagged
  tuple gives its tag, an `Error` its reason atom (else its kind).
  """
  @spec reason_tag(term()) :: atom()
  def reason_tag(reason) when is_atom(reason), do: reason
  def reason_tag(%Error{reason: reason}) when is_atom(reason) and reason != nil, do: reason
  def reason_tag(%Error{kind: kind}), do: kind
  def reason_tag(reason) when is_tuple(reason) and is_atom(elem(reason, 0)), do: elem(reason, 0)
  def reason_tag(_reason), do: :other

  defp stop_measurements(start, extra) do
    now = System.monotonic_time()
    Map.merge(%{duration: now - start, monotonic_time: now}, extra)
  end

  defp status({:error, %Error{kind: kind}}), do: %{status: :error, error_kind: kind}
  defp status(:ok), do: %{status: :ok, error_kind: nil}
  defp status({:ok, _}), do: %{status: :ok, error_kind: nil}
  defp status(_other), do: %{status: :error, error_kind: nil}

  defp error_flag({:ok, %{is_error: is_error}}), do: is_error
  defp error_flag(_result), do: nil
end
