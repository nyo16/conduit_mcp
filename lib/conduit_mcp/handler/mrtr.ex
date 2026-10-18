defmodule ConduitMcp.Handler.MRTR do
  @moduledoc false

  # Runs the server callback of the three methods on which MCP `2026-07-28`
  # permits an `InputRequiredResult` - `tools/call`, `resources/read`,
  # `prompts/get` - and owns everything Multi Round-Trip Requests add around
  # it. The method modules call `dispatch/6` where they used to call
  # `ConduitMcp.Handler.Common.dispatch_callback/2` directly.
  #
  # Modern era:
  #
  #   1. A `params["requestState"]` is opened with `ConduitMcp.MRTR.State.open/3`
  #      before the callback runs, bound to the request's version, method,
  #      params and `ConduitMcp.Principal.id/1`. Any failure is the one flat
  #      -32602 of `invalid_state_error/0`; the token is never logged.
  #   2. The restored term and `params["inputResponses"]` reach the callback
  #      as `conn.assigns[:mcp_input]` (absent on a first round).
  #   3. A `{:input_required, input_requests, state}` return is checked
  #      (malformed ⇒ -32603), gated against the client's declared
  #      capabilities (`ConduitMcp.MRTR.missing_capabilities/2` ⇒ -32021),
  #      sealed with `ConduitMcp.MRTR.State.seal/3` (unsealable ⇒ -32603 and an
  #      operator log line) and reported as
  #      `[:conduit_mcp, :mrtr, :input_required]`. The result handed back is
  #      `{:input_required, input_requests, token}`, which
  #      `ConduitMcp.Protocol.Modern.to_response/4` shapes.
  #
  # Legacy era: the callback runs as before; `{:input_required, ...}` is
  # logged and answered with -32603, because the legacy protocol has no
  # `InputRequiredResult`.
  #
  # `{:task, attrs}` (the `ConduitMcp.Ext.Tasks` extension) is matched here
  # too: on a modern `tools/call` it goes to `ConduitMcp.Handler.ExtTasks`;
  # from `resources/read`/`prompts/get`, or on the legacy era, it is logged
  # and answered with -32603.
  #
  # The sealed payload wraps the callback's term as `%{"r" => round, "s" =>
  # state}` so the telemetry event can report which round of an exchange
  # this is without trusting the client.

  require Logger

  alias ConduitMcp.Ctx
  alias ConduitMcp.Errors
  alias ConduitMcp.Handler
  alias ConduitMcp.Handler.Common
  alias ConduitMcp.MRTR.State

  @input_methods ["elicitation/create", "sampling/createMessage", "roots/list"]

  @legacy_message "MRTR input requests require protocol 2026-07-28"
  @legacy_task_message "Task results require protocol 2026-07-28 (io.modelcontextprotocol/tasks)"

  @doc """
  Runs `callback` (given the request's conn, possibly carrying
  `conn.assigns[:mcp_input]`) for `method` and returns its neutral result.
  """
  @spec dispatch(
          Plug.Conn.t(),
          String.t(),
          map(),
          module(),
          (Plug.Conn.t() -> term()),
          String.t()
        ) :: Handler.result()
  def dispatch(conn, method, params, server_module, callback, callback_name) do
    case Ctx.from_conn(conn) do
      %Ctx{era: :modern} = ctx ->
        modern(conn, ctx, method, params, server_module, callback, callback_name)

      _legacy ->
        legacy(conn, callback, callback_name)
    end
  end

  defp legacy(conn, callback, callback_name) do
    case run(conn, callback, callback_name) do
      {:input_required, _input_requests, _state} ->
        Logger.error(
          "#{callback_name} returned {:input_required, ...} for a legacy-era request; " <>
            @legacy_message
        )

        {:error, Errors.internal_error(), @legacy_message, nil}

      {:task, _attrs} ->
        Logger.error(
          "#{callback_name} returned {:task, ...} for a legacy-era request; " <>
            @legacy_task_message
        )

        {:error, Errors.internal_error(), @legacy_task_message, nil}

      result ->
        result
    end
  end

  defp modern(conn, ctx, method, params, server_module, callback, callback_name) do
    binding = binding(ctx, conn, method, params, server_module)

    case restore(conn, binding, params) do
      {:ok, conn, previous_round} ->
        conn
        |> run(callback, callback_name)
        |> suspend(ctx, binding, server_module, previous_round + 1, callback_name)
        |> start_task(conn, ctx, method, callback_name)

      {:error, _code, _message, _data} = error ->
        error
    end
  end

  # `{:input_required, ...}` and `{:task, ...}` are matched here, before
  # `Common.dispatch_callback/2`, which rejects them from every other callback.
  defp run(conn, callback, callback_name) do
    case callback.(conn) do
      {:input_required, _input_requests, _state} = input_required -> input_required
      {:task, _attrs} = task -> task
      other -> Common.dispatch_callback(fn -> other end, callback_name)
    end
  end

  defp start_task({:task, attrs}, conn, ctx, "tools/call", callback_name),
    do: ConduitMcp.Handler.ExtTasks.start(conn, ctx, attrs, callback_name)

  defp start_task({:task, _attrs}, _conn, _ctx, _method, callback_name) do
    Logger.error("#{callback_name} returned {:task, ...}; only tools/call may return a task")
    {:error, Errors.internal_error(), "Internal server error", nil}
  end

  defp start_task(result, _conn, _ctx, _method, _callback_name), do: result

  defp binding(ctx, conn, method, params, server_module) do
    %{
      version: ctx.version,
      method: method,
      params: params,
      principal: ConduitMcp.Principal.id(conn),
      server: server_module
    }
  end

  # A first round carries no requestState; a retry's token must open.
  defp restore(conn, binding, params) do
    case Map.fetch(params, "requestState") do
      :error ->
        {:ok, conn, 0}

      {:ok, token} ->
        with {:ok, %{"r" => round, "s" => state}} when is_integer(round) and round > 0 <-
               State.open(token, binding),
             {:ok, responses} <- input_responses(params) do
          {:ok, Plug.Conn.assign(conn, :mcp_input, %{state: state, responses: responses}), round}
        else
          {:error, _code, _message, _data} = error -> error
          _ -> invalid_state_error()
        end
    end
  end

  defp input_responses(params) do
    case Map.get(params, "inputResponses") do
      nil ->
        {:ok, %{}}

      responses when is_map(responses) ->
        {:ok, responses}

      _other ->
        {:error, Errors.invalid_params(), "inputResponses must be an object", nil}
    end
  end

  # Identical for every way a token can fail, so a client learns nothing
  # about which check rejected it.
  defp invalid_state_error, do: {:error, Errors.invalid_params(), "Invalid requestState", nil}

  defp suspend({:input_required, input_requests, state}, ctx, binding, server_module, round, name) do
    with :ok <- check_input_requests(input_requests, name),
         :ok <- gate(input_requests, ctx.client_capabilities),
         {:ok, token} <- seal(state, binding, round) do
      :telemetry.execute(
        [:conduit_mcp, :mrtr, :input_required],
        %{count: map_size(input_requests)},
        %{method: binding.method, server_module: server_module, round: round}
      )

      {:input_required, input_requests, token}
    end
  end

  defp suspend(result, _ctx, _binding, _server_module, _round, _name), do: result

  defp check_input_requests(input_requests, callback_name) do
    if valid_input_requests?(input_requests) do
      :ok
    else
      Logger.error(
        "#{callback_name} returned malformed input requests: expected a map of string keys to " <>
          "maps built by ConduitMcp.MRTR (methods #{Enum.join(@input_methods, ", ")})"
      )

      {:error, Errors.internal_error(), "Internal server error", nil}
    end
  end

  @doc false
  # Shared with `ConduitMcp.Ext.Tasks.require_input/3`, whose input requests
  # reach the client through `tasks/get` instead of an `InputRequiredResult`.
  @spec valid_input_requests?(term()) :: boolean()
  def valid_input_requests?(input_requests),
    do: is_map(input_requests) and Enum.all?(input_requests, &valid_input_request?/1)

  defp valid_input_request?({key, %{"method" => method}})
       when is_binary(key) and method in @input_methods,
       do: true

  defp valid_input_request?(_entry), do: false

  defp gate(input_requests, client_capabilities) do
    missing = ConduitMcp.MRTR.missing_capabilities(input_requests, client_capabilities)

    if missing == %{} do
      :ok
    else
      {:error, Errors.missing_required_client_capability(), "Missing required client capability",
       %{"requiredCapabilities" => missing}}
    end
  end

  # `State.seal/3` raises `ArgumentError` when `:mrtr_keys` is not configured
  # or the state is not JSON-encodable. Both are operator or server-author
  # errors: the message (which never contains key bytes or state values) is
  # logged, and the client sees a plain -32603.
  defp seal(state, binding, round) do
    {:ok, State.seal(%{"r" => round, "s" => state}, binding)}
  rescue
    error in ArgumentError ->
      Logger.error(
        "Could not seal MRTR requestState for #{binding.method}: #{Exception.message(error)}"
      )

      {:error, Errors.internal_error(), "Internal server error", nil}
  end
end
