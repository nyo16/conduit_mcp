defmodule ConduitMcp.Client.Input do
  @moduledoc false

  # The safety layer around `ConduitMcp.Client.Handler` callbacks, shared by
  # both eras: a legacy server-to-client request runs it in a task under the
  # client's `Task.Supervisor` (started by the connection, see
  # `ConduitMcp.Client.Connection.ServerRequests`); a modern MRTR input
  # request runs it in the calling process. It never runs in the connection.
  #
  # Before a callback runs:
  #
  #   * the handler must implement it (else `-32601`);
  #   * the server's input budget must allow it (`:input_rate_limit`,
  #     default 10/s, burst 20; sampling is refused with the sampling
  #     rejection code, the others with `-32000`);
  #   * sampling: a request not tied to an in-flight call is refused unless
  #     `sampling: [allow_idle: true]`; `maxTokens` must be a positive
  #     integer and is clamped to `sampling: [max_tokens: _]` (4096);
  #     `includeContext` other than `"none"` becomes `"none"` unless
  #     `sampling: [context: true]`;
  #   * elicitation: the mode (default `"form"`) must be one the handler
  #     declares (else `-32602`); a form schema must be the flat primitive
  #     subset and its secret-looking fields are flagged; a URL must be
  #     absolute `https`, is never fetched, and the handler is told its host,
  #     whether it is an IDN, and whether its origin differs from the
  #     server's.
  #
  # After it: an elicitation answer must be a valid `ElicitResult` (a form
  # `accept` must fit the schema, a URL `accept` carries no content), and
  # roots are reduced to canonical `file://` URIs. A callback's
  # `{:error, %{"code" => integer, "message" => binary}}` is passed through.

  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Input.Elicitation
  alias ConduitMcp.Client.RateLimit
  alias ConduitMcp.Reflect

  @invalid_params ConduitMcp.Errors.invalid_params()
  @internal_error ConduitMcp.Errors.internal_error()
  @method_not_found ConduitMcp.Errors.method_not_found()
  @server_error ConduitMcp.Errors.server_error()

  @methods %{
    "sampling/createMessage" => {"sampling", :handle_sampling, 2},
    "elicitation/create" => {"elicitation", :handle_elicitation, 2},
    "roots/list" => {"roots", :list_roots, 1}
  }

  @actions ["accept", "decline", "cancel"]

  @typedoc "Settings shared by the connection and callers (published in the registry value)."
  @type settings :: %{
          handler: module() | nil,
          sampling: keyword(),
          elicitation: keyword(),
          limiter: RateLimit.t(),
          assigns: map()
        }

  @typedoc "Everything one answer needs."
  @type env :: %{
          required(:handler) => module() | nil,
          required(:sampling) => keyword(),
          required(:elicitation) => keyword(),
          required(:limiter) => RateLimit.t(),
          required(:assigns) => map(),
          required(:client) => term(),
          required(:server_id) => String.t(),
          required(:era) => :modern | :legacy,
          required(:related_request_id) => term(),
          required(:idle?) => boolean(),
          required(:origin) => String.t() | nil
        }

  @type rpc_error :: %{required(String.t()) => term()}

  @doc "The client capability a server-to-client input `method` needs, or `:error`."
  @spec capability(term()) :: {:ok, String.t()} | :error
  def capability(method) do
    case Map.fetch(@methods, method) do
      {:ok, {capability, _fun, _arity}} -> {:ok, capability}
      :error -> :error
    end
  end

  @doc "The handler timeout for `method` from the `:handler_timeout` option."
  @spec timeout(String.t(), keyword()) :: pos_integer()
  def timeout("sampling/createMessage", timeouts), do: Keyword.fetch!(timeouts, :sampling)
  def timeout("elicitation/create", timeouts), do: Keyword.fetch!(timeouts, :elicitation)
  def timeout("roots/list", timeouts), do: Keyword.fetch!(timeouts, :roots)

  @doc "Builds the env of one answer from the shared settings."
  @spec env(settings(), map()) :: env()
  def env(settings, fields), do: Map.merge(settings, fields)

  @doc """
  The env of a modern input request answered in the calling process, from
  the client's caller view (`ConduitMcp.Client.Request.lookup/1`).
  """
  @spec caller_env(term(), map(), map() | nil) :: env()
  def caller_env(client, view, assigns) do
    env(view.input, %{
      client: client,
      server_id: view.server_id,
      era: :modern,
      assigns: assigns || view.input.assigns,
      related_request_id: nil,
      idle?: false,
      origin: view.origin
    })
  end

  @doc """
  Checks a modern input request against the declared `capabilities` and
  answers it in the calling process. A raise, throw or exit in the callback
  is caught: the result is an `:input_handler` error either way.
  """
  @spec answer_input(String.t(), map(), map(), env()) ::
          {:ok, map()} | {:error, ConduitMcp.Client.Error.t()}
  def answer_input(key, request, capabilities, env) do
    method = if is_map(request), do: Map.get(request, "method")

    with {:ok, capability} <- capability(method),
         true <- is_map(Map.get(capabilities, capability)) do
      case answer(method, Map.get(request, "params"), env) do
        {:ok, response} -> {:ok, response}
        {:error, error} -> {:error, Error.new(:input_handler, {:handler_error, key}, error)}
      end
    else
      _undeclared ->
        {:error, Error.new(:protocol, {:undeclared_input_request, Reflect.text(method, 64)})}
    end
  catch
    kind, reason ->
      {:error,
       Error.new(:input_handler, {:raised, key}, %{
         kind: kind,
         reason: reason,
         stacktrace: __STACKTRACE__
       })}
  end

  @doc """
  Answers one input request: `{:ok, result}` to send, or `{:error, rpc_error}`
  (a JSON-RPC error object for a legacy response; the reason of an
  `:input_handler` error in MRTR). Callback exceptions are not caught here.
  """
  @spec answer(String.t(), term(), env()) :: {:ok, map()} | {:error, rpc_error()}
  def answer(method, params, env) do
    params = if is_map(params), do: params, else: %{}

    with :ok <- implemented(method, env.handler),
         :ok <- within_budget(method, env) do
      run(method, params, env)
    end
  end

  defp implemented(method, handler) do
    case Map.fetch(@methods, method) do
      {:ok, {_capability, fun, arity}} when handler != nil ->
        if function_exported?(handler, fun, arity),
          do: :ok,
          else: rpc_error(@method_not_found, "Method not found")

      _other ->
        rpc_error(@method_not_found, "Method not found")
    end
  end

  defp within_budget(method, env) do
    case RateLimit.check(env.limiter) do
      :ok ->
        :ok

      :rate_limited when method == "sampling/createMessage" ->
        sampling_rejected(env, "Sampling request rate limit exceeded")

      :rate_limited ->
        rpc_error(@server_error, "Too many requests from the server")
    end
  end

  defp run("sampling/createMessage", params, env), do: sampling(params, env)
  defp run("elicitation/create", params, env), do: elicitation(params, env)
  defp run("roots/list", _params, env), do: roots(env)

  # --- sampling ----------------------------------------------------------------

  defp sampling(params, env) do
    sampling = env.sampling

    if env.idle? and not Keyword.fetch!(sampling, :allow_idle) do
      sampling_rejected(env, "Sampling request refused: no request in flight")
    else
      with {:ok, params} <- clamp_tokens(params, Keyword.fetch!(sampling, :max_tokens)) do
        params
        |> coerce_context(Keyword.fetch!(sampling, :context))
        |> env.handler.handle_sampling(ctx(env))
        |> callback_result()
      end
    end
  end

  # --- elicitation ---------------------------------------------------------------

  defp elicitation(params, env) do
    mode = Map.get(params, "mode", "form")

    cond do
      mode not in declared_modes(env.handler) ->
        rpc_error(@invalid_params, "Elicitation mode not supported")

      mode == "form" ->
        form(params, env)

      true ->
        url(params, env)
    end
  end

  # --- roots -----------------------------------------------------------------------

  defp roots(env) do
    case env.handler.list_roots(ctx(env)) do
      {:ok, %{"roots" => roots}} when is_list(roots) ->
        {:ok,
         %{"roots" => roots |> Enum.flat_map(&canonical_root/1) |> Enum.uniq_by(& &1["uri"])}}

      {:ok, _other} ->
        rpc_error(@internal_error, "Invalid roots response")

      other ->
        callback_result(other)
    end
  end

  defp clamp_tokens(%{"maxTokens" => tokens} = params, max)
       when is_integer(tokens) and tokens > 0,
       do: {:ok, Map.put(params, "maxTokens", min(tokens, max))}

  defp clamp_tokens(_params, _max),
    do: rpc_error(@invalid_params, "maxTokens must be a positive integer")

  defp coerce_context(%{"includeContext" => context} = params, false) when context != "none",
    do: Map.put(params, "includeContext", "none")

  defp coerce_context(params, _context?), do: params

  defp sampling_rejected(env, message),
    do: rpc_error(Keyword.fetch!(env.sampling, :rejection_code), message)

  defp declared_modes(handler) do
    modes =
      if function_exported?(handler, :elicitation_modes, 0),
        do: handler.elicitation_modes(),
        else: [:form]

    Enum.map(modes, &Atom.to_string/1)
  end

  defp form(params, env) do
    schema = Map.get(params, "requestedSchema")

    case Elicitation.check_schema(schema) do
      {:ok, fields} ->
        ctx = Map.merge(ctx(env), %{mode: :form, fields: fields})

        params
        |> env.handler.handle_elicitation(ctx)
        |> elicit_result(&Elicitation.check_content(&1, schema))

      {:error, message} ->
        rpc_error(@invalid_params, message)
    end
  end

  defp url(params, env) do
    case Elicitation.check_url(Map.get(params, "url"), env.origin) do
      {:ok, facts} ->
        ctx = ctx(env) |> Map.merge(facts) |> Map.put(:mode, :url)

        params
        |> env.handler.handle_elicitation(ctx)
        |> elicit_result(&url_content/1)

      {:error, message} ->
        rpc_error(@invalid_params, message)
    end
  end

  # A URL-mode accept carries no content: the user acts out of band.
  defp url_content(nil), do: :ok
  defp url_content(_content), do: {:error, "URL mode answers carry no content"}

  defp elicit_result({:ok, %{"action" => "accept"} = result}, check_content) do
    case check_content.(Map.get(result, "content")) do
      :ok -> {:ok, result}
      {:error, message} -> rpc_error(@internal_error, "Invalid elicitation response: " <> message)
    end
  end

  defp elicit_result({:ok, %{"action" => action} = result}, _check) when action in @actions,
    do: {:ok, Map.delete(result, "content")}

  defp elicit_result({:ok, _invalid}, _check),
    do: rpc_error(@internal_error, "Invalid elicitation response")

  defp elicit_result(other, _check), do: callback_result(other)

  defp callback_result({:ok, %{} = result}) when not is_struct(result), do: {:ok, result}

  defp callback_result({:error, %{"code" => code, "message" => message} = error})
       when is_integer(code) and is_binary(message),
       do: {:error, Map.take(error, ["code", "message", "data"])}

  defp callback_result(_other), do: rpc_error(@internal_error, "Invalid handler response")

  # `file://` URIs only, with `.`/`..` segments resolved; anything else is
  # dropped rather than sent.
  defp canonical_root(%{"uri" => uri} = root) when is_binary(uri) do
    with {:ok, %URI{scheme: scheme, host: host, path: path, query: nil, fragment: nil}}
         when is_binary(scheme) and is_binary(path) <- URI.new(uri),
         "file" <- String.downcase(scheme),
         true <- host in [nil, "", "localhost"],
         "/" <> _ = decoded <- URI.decode(path),
         false <- String.contains?(decoded, <<0>>) do
      canonical = %{"uri" => "file://" <> URI.encode(Path.expand(decoded))}

      case root do
        %{"name" => name} when is_binary(name) -> [Map.put(canonical, "name", name)]
        _ -> [canonical]
      end
    else
      _ -> []
    end
  end

  defp canonical_root(_root), do: []

  defp ctx(env) do
    %{
      client: env.client,
      server_id: env.server_id,
      era: env.era,
      assigns: env.assigns,
      related_request_id: env.related_request_id
    }
  end

  defp rpc_error(code, message), do: {:error, %{"code" => code, "message" => message}}
end
