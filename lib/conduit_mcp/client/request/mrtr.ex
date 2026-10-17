defmodule ConduitMcp.Client.Request.MRTR do
  @moduledoc """
  The client side of modern (`2026-07-28`) multi round-trip requests.

  A `tools/call`, `resources/read` or `prompts/get` may come back with
  `resultType: "input_required"`: the server needs answers (elicitation,
  sampling, roots) before it can finish. `run/3` drives that loop. It does no
  I/O itself: sending a request, allocating ids and answering input requests
  are injected functions, so it runs in the caller and is testable without a
  server.

  ## One round

    1. Take a fresh JSON-RPC id from `:next_id` (ids are never reused) and
       call `:send` with the method and params.
    2. A result with no `resultType`, or `"complete"`, ends the loop. So does a
       type listed in `:result_types` (for example `"task"` when the tasks
       extension is in use). Any other value is invalid: a `:protocol` error.
    3. For `"input_required"`: check every input request first (method known
       and declared in `:capabilities`; an undeclared one is a `:protocol`
       error and **no** handler runs), then call `:handle_input` for each,
       in key order, and retry with the **same method and params** plus
       `inputResponses` and the `requestState` echoed byte-exact. A missing
       `requestState` is omitted on the retry, never sent empty; a missing
       `inputRequests` means retry at once with `requestState` alone.

  Only the original params are reused: `inputResponses` and `requestState`
  from a previous round never leak into the next. `requestState` is held as
  a `ConduitMcp.Client.Secret` between rounds and is never put in an error.

  ## Limits (MR-4)

  All three give `%ConduitMcp.Client.Error{kind: :mrtr_round_limit}`, with the
  cap that tripped as the reason:

    * `:max_rounds` (default 8) - requests sent, retries included; an
      `input_required` answer to the last allowed round is the error.
    * `:max_input_requests` (default 16) - input requests in one round.
    * `:max_request_state_bytes` (default 65_536) - size of `requestState`.

  ## Handler failures

  `:handle_input` returning `{:error, reason}` or a non-map, raising,
  throwing or exiting aborts the loop with `kind: :input_handler`; the reason
  is `{:handler_error, key}`, `{:invalid_response, key}` or `{:raised, key}`.
  """

  alias ConduitMcp.Client.{Error, Secret}

  @mrtr_methods ["tools/call", "resources/read", "prompts/get"]
  @input_methods %{
    "elicitation/create" => "elicitation",
    "sampling/createMessage" => "sampling",
    "roots/list" => "roots"
  }

  @defaults [max_rounds: 8, max_input_requests: 16, max_request_state_bytes: 65_536]

  @typedoc "Sends one request: `(id, method, params)`."
  @type send_fun :: (term(), String.t(), map() -> {:ok, term()} | {:error, Error.t()})

  @typedoc ~s|Answers one input request: `(key, %{"method" => _, "params" => _})`.|
  @type input_fun :: (String.t(), map() -> {:ok, map()} | {:error, term()})

  @type option ::
          {:send, send_fun()}
          | {:next_id, (-> term())}
          | {:handle_input, input_fun()}
          | {:capabilities, map()}
          | {:result_types, [String.t()]}
          | {:max_rounds, pos_integer()}
          | {:max_input_requests, pos_integer()}
          | {:max_request_state_bytes, pos_integer()}

  @doc """
  Runs `method` with `params` to completion.

  Returns `{:ok, result, %{rounds: n}}` with the final string-keyed result
  map and the number of requests sent, or `{:error, %Error{}}`; an error from
  `:send` is returned unchanged.

  ## Options

    * `:send` (required) - `t:send_fun/0`.
    * `:next_id` (required) - zero-arity function returning a fresh id.
    * `:handle_input` (required) - `t:input_fun/0`.
    * `:capabilities` - the `clientCapabilities` this request declared
      (default `%{}`, which refuses every input request).
    * `:result_types` - extra `resultType` values to accept as final
      (default `[]`).
    * `:max_rounds`, `:max_input_requests`, `:max_request_state_bytes` -
      see the moduledoc.
  """
  @spec run(String.t(), map(), [option()]) ::
          {:ok, term(), %{rounds: pos_integer()}} | {:error, Error.t()}
  def run(method, params, opts) when is_binary(method) and is_map(params) do
    config = config!(opts)
    base = Map.drop(params, ["inputResponses", "requestState"])
    round(config, method, base, 1, nil, nil)
  end

  defp config!(opts) do
    opts = Keyword.merge(@defaults, opts)

    for key <- [:max_rounds, :max_input_requests, :max_request_state_bytes] do
      value = Keyword.fetch!(opts, key)

      unless is_integer(value) and value > 0 do
        raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
      end
    end

    %{
      send: fun!(opts, :send, 3),
      next_id: fun!(opts, :next_id, 0),
      handle_input: fun!(opts, :handle_input, 2),
      capabilities: Keyword.get(opts, :capabilities, %{}),
      result_types: Keyword.get(opts, :result_types, []),
      max_rounds: opts[:max_rounds],
      max_input_requests: opts[:max_input_requests],
      max_request_state_bytes: opts[:max_request_state_bytes]
    }
  end

  defp fun!(opts, key, arity) do
    case Keyword.fetch(opts, key) do
      {:ok, fun} when is_function(fun, arity) ->
        fun

      _ ->
        raise ArgumentError, "#{inspect(key)} must be a function of arity #{arity}"
    end
  end

  defp round(config, method, base, round, responses, state) do
    params = retry_params(base, responses, state)

    case config.send.(config.next_id.(), method, params) do
      {:ok, result} -> handle_result(config, method, base, round, result)
      {:error, %Error{}} = error -> error
    end
  end

  defp retry_params(base, responses, state) do
    base
    |> put_present("inputResponses", responses)
    |> put_present("requestState", state && Secret.expose(state))
  end

  defp put_present(params, _key, nil), do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  defp handle_result(config, method, base, round, %{} = result) do
    case Map.get(result, "resultType", "complete") do
      "complete" ->
        {:ok, result, %{rounds: round}}

      "input_required" ->
        continue(config, method, base, round, result)

      type when is_binary(type) ->
        if type in config.result_types,
          do: {:ok, result, %{rounds: round}},
          else: protocol({:unknown_result_type, type})

      _other ->
        protocol(:invalid_result_type)
    end
  end

  defp handle_result(_config, _method, _base, _round, _result), do: protocol(:invalid_result)

  defp continue(config, method, base, round, result) do
    with :ok <- check_method(method),
         :ok <- check_round(config, round),
         {:ok, requests, state} <- parse_input_required(config, result),
         :ok <- check_declared(config, requests),
         {:ok, responses} <- answer_all(config, requests) do
      round(config, method, base, round + 1, responses, state)
    end
  end

  defp check_method(method) when method in @mrtr_methods, do: :ok
  defp check_method(method), do: protocol({:input_required_not_allowed, method})

  defp check_round(%{max_rounds: max}, round) when round >= max, do: limit(:max_rounds, max)
  defp check_round(_config, _round), do: :ok

  defp parse_input_required(config, result) do
    requests = Map.get(result, "inputRequests")
    state = Map.get(result, "requestState")

    cond do
      requests == nil and state == nil ->
        protocol(:empty_input_required)

      not (requests == nil or is_map(requests)) or not (state == nil or is_binary(state)) ->
        protocol(:invalid_input_required)

      map_size(requests || %{}) > config.max_input_requests ->
        limit(:max_input_requests, config.max_input_requests)

      state != nil and byte_size(state) > config.max_request_state_bytes ->
        limit(:max_request_state_bytes, config.max_request_state_bytes)

      true ->
        {:ok, requests && Enum.sort(requests), state && Secret.new(state)}
    end
  end

  # Every input request is checked before any handler runs.
  defp check_declared(_config, nil), do: :ok

  defp check_declared(config, requests) do
    Enum.reduce_while(requests, :ok, fn {_key, request}, :ok ->
      case declared(config.capabilities, request) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp declared(caps, %{"method" => method} = request) when is_binary(method) do
    capability = Map.get(@input_methods, method)

    cond do
      capability == nil -> protocol({:unknown_input_method, method})
      not is_map(Map.get(caps, capability)) -> protocol({:undeclared_input_request, method})
      method == "elicitation/create" -> elicitation_mode_declared(caps, request)
      true -> :ok
    end
  end

  defp declared(_caps, _request), do: protocol(:invalid_input_request)

  # An empty `elicitation` capability means form mode (backwards compatible).
  defp elicitation_mode_declared(%{"elicitation" => elicitation}, request) do
    mode =
      case request do
        %{"params" => %{"mode" => mode}} -> mode
        _ -> "form"
      end

    cond do
      mode == "form" and (elicitation == %{} or Map.has_key?(elicitation, "form")) -> :ok
      mode == "url" and Map.has_key?(elicitation, "url") -> :ok
      true -> protocol({:undeclared_elicitation_mode, mode})
    end
  end

  defp answer_all(_config, nil), do: {:ok, nil}

  defp answer_all(config, requests) do
    Enum.reduce_while(requests, {:ok, %{}}, fn {key, request}, {:ok, acc} ->
      case answer(config.handle_input, key, request) do
        {:ok, response} -> {:cont, {:ok, Map.put(acc, key, response)}}
        error -> {:halt, error}
      end
    end)
  end

  defp answer(handle_input, key, request) do
    case invoke(handle_input, key, request) do
      {:ok, %{} = response} when not is_struct(response) ->
        {:ok, response}

      {:ok, _not_a_map} ->
        input_error({:invalid_response, key}, nil)

      {:error, reason} ->
        input_error({:handler_error, key}, reason)

      {:caught, kind, reason, stacktrace} ->
        input_error({:raised, key}, %{kind: kind, reason: reason, stacktrace: stacktrace})

      _other ->
        input_error({:invalid_response, key}, nil)
    end
  end

  # The handler is user code running in the caller: any raise, throw or exit
  # becomes a typed error instead of crashing the caller mid-loop.
  defp invoke(handle_input, key, request) do
    handle_input.(key, request)
  catch
    kind, reason -> {:caught, kind, reason, __STACKTRACE__}
  end

  defp protocol(reason), do: {:error, Error.new(:protocol, reason)}
  defp limit(cap, max), do: {:error, Error.new(:mrtr_round_limit, cap, %{limit: max})}
  defp input_error(reason, data), do: {:error, Error.new(:input_handler, reason, data)}
end
