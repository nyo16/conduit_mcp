defmodule ConduitMcp.Handler.Common do
  @moduledoc false

  # Helpers shared by the method modules: callback dispatch into neutral
  # results, scope lookup/verification, and the error results more than one
  # method produces. Nothing here builds a JSON-RPC map; that is the era's
  # response shaper's job (e.g. `ConduitMcp.Protocol.Legacy`).

  require Logger

  alias ConduitMcp.Errors
  alias ConduitMcp.Handler
  alias ConduitMcp.ServerMeta

  @doc """
  Runs a server callback and normalizes its return into a neutral result.

  Only the three MRTR callbacks may return `{:input_required, ...}`, and
  `ConduitMcp.Handler.MRTR.dispatch/6` matches it before delegating here;
  from any other callback it is logged and becomes `-32603`, like every
  other unexpected shape.
  """
  @spec dispatch_callback((-> term()), String.t()) :: Handler.result()
  def dispatch_callback(callback_fn, callback_name) do
    case callback_fn.() do
      {:ok, result} when is_map(result) ->
        {:ok, result}

      {:input_required, _input_requests, _state} ->
        Logger.error(
          "#{callback_name} returned {:input_required, ...}; only handle_call_tool/3, " <>
            "handle_read_resource/2 and handle_get_prompt/3 may"
        )

        {:error, Errors.internal_error(), "Internal server error", nil}

      {:error, error} ->
        {:error, error["code"] || Errors.server_error(),
         error["message"] || "#{callback_name} failed", nil}

      other ->
        Logger.error("Unexpected result from #{callback_name}: #{inspect(other)}")
        {:error, Errors.internal_error(), "Internal server error", nil}
    end
  end

  @doc """
  Dispatches a `handle_list_*` callback through `dispatch_callback/2`.
  """
  @spec dispatch_list(map(), module(), Plug.Conn.t(), atom()) :: Handler.result()
  def dispatch_list(params, server_module, conn, callback_name) do
    dispatch_callback(
      fn -> call_list_callback(server_module, callback_name, conn, params) end,
      Atom.to_string(callback_name)
    )
  end

  # Calls a list callback, preferring the arity-2 variant (with params for pagination).
  # Falls back to arity-1 if arity-2 is not implemented.
  @doc """
  Calls `callback_name` on `server_module`, with `params` when it exports the
  arity-2 variant.
  """
  @spec call_list_callback(module(), atom(), Plug.Conn.t(), map()) :: term()
  def call_list_callback(server_module, callback_name, conn, params) do
    meta_key =
      case callback_name do
        :handle_list_tools -> :list_tools_2
        :handle_list_resources -> :list_resources_2
        :handle_list_prompts -> :list_prompts_2
      end

    if ServerMeta.has?(server_module, meta_key) do
      apply(server_module, callback_name, [conn, params])
    else
      apply(server_module, callback_name, [conn])
    end
  end

  # Every scoped surface — tools, resources and prompts — is authorized the
  # same way: look up the declared scope, then check it against the principal's
  # granted scopes. An unauthenticated request has no scopes, so a scoped
  # surface fails closed.
  @doc """
  Returns the scope `server_module` declares for `key`, or `nil`.
  """
  @spec required_scope(
          module(),
          :scope_for_tool | :scope_for_prompt | :scope_for_resource,
          term()
        ) ::
          String.t() | nil
  def required_scope(server_module, capability, key) do
    if ServerMeta.has?(server_module, capability) do
      apply_scope_lookup(server_module, capability, key)
    else
      nil
    end
  end

  defp apply_scope_lookup(server_module, :scope_for_tool, key),
    do: server_module.__scope_for_tool__(key)

  defp apply_scope_lookup(server_module, :scope_for_prompt, key),
    do: server_module.__scope_for_prompt__(key)

  defp apply_scope_lookup(server_module, :scope_for_resource, key),
    do: server_module.__scope_for_resource__(key)

  @doc """
  Checks `required_scope` against the scopes granted to the request's principal.
  """
  @spec verify_scope(Plug.Conn.t(), String.t() | nil) ::
          :ok | {:error, :insufficient_scope, String.t()}
  def verify_scope(_conn, nil), do: :ok

  def verify_scope(conn, required_scope) do
    token_scopes = ConduitMcp.Principal.scopes(conn)
    required = String.split(required_scope, " ", trim: true)

    if Enum.all?(required, &(&1 in token_scopes)) do
      :ok
    else
      {:error, :insufficient_scope, required_scope}
    end
  end

  # One source of "you asked for something that doesn't exist" for tools and
  # prompts, so the three authoring modes cannot disagree. `-32602` is what the
  # MCP specification prescribes ("Unknown tool: invalid_tool_name"); the name
  # is echoed through `ConduitMcp.Reflect` because it is client input.
  @doc """
  The error for an unknown tool or prompt (`kind` is `"tool"` or `"prompt"`).
  """
  @spec unknown_target_error(String.t(), term()) :: Handler.result()
  def unknown_target_error(kind, name) do
    {:error, Errors.invalid_params(), "Unknown #{kind}: #{ConduitMcp.Reflect.text(name)}", nil}
  end

  # Insufficient scope is the one method error that a transport must also
  # surface at the HTTP layer: MCP authorization (RFC 6750 §3.1) answers it
  # with 403 and `WWW-Authenticate: Bearer error="insufficient_scope",
  # scope="..."`, which is what lets an OAuth client step up. The signal
  # stays inside the neutral result rather than widening `Handler.result()`:
  # the error's `data` carries the RFC 6750 challenge parameters, and
  # `insufficient_scope/1` recognises the shaped JSON-RPC error by its code
  # plus that `data` — never by message text. Any era's response shaper that
  # keeps `data` (as `ConduitMcp.Protocol.Legacy` does) carries it through,
  # so a caller of `ConduitMcp.Handler.handle_request/3` that is not a
  # transport still gets an ordinary JSON-RPC error, and a later era's
  # transport reuses `insufficient_scope/1` unchanged.
  @server_error Errors.server_error()

  @doc """
  The error for a principal lacking `required_scope`.

  `data` is `%{"error" => "insufficient_scope", "scope" => required_scope}`;
  see `insufficient_scope/1`.
  """
  @spec insufficient_scope_error(String.t()) :: Handler.result()
  def insufficient_scope_error(required_scope) do
    {:error, @server_error, "Insufficient scope. Required: #{required_scope}",
     %{"error" => "insufficient_scope", "scope" => required_scope}}
  end

  @doc """
  Recognises a JSON-RPC response built from `insufficient_scope_error/1` and
  returns the scopes it requires, for the transport's 403 challenge.
  """
  @spec insufficient_scope(map()) :: {:ok, [String.t()]} | :error
  def insufficient_scope(%{
        "error" => %{
          "code" => @server_error,
          "data" => %{"error" => "insufficient_scope", "scope" => scope}
        }
      })
      when is_binary(scope),
      do: {:ok, String.split(scope, " ", trim: true)}

  def insufficient_scope(_response), do: :error

  @doc """
  The error for a missing or non-string resource `uri`.
  """
  @spec invalid_uri_error(term()) :: Handler.result()
  def invalid_uri_error(nil), do: {:error, Errors.invalid_params(), "Missing uri", nil}

  def invalid_uri_error(uri) do
    {:error, Errors.invalid_params(),
     "uri must be a string, got: #{ConduitMcp.Reflect.text(uri, 40)}", nil}
  end

  @doc """
  The per-method telemetry `status` of a neutral result.

  An `input_required` round is `:ok`: the callback did not fail, it asked
  for input (counted by `[:conduit_mcp, :mrtr, :input_required]`).
  """
  @spec status(Handler.result()) :: :ok | :error
  def status({:ok, _result}), do: :ok
  def status({:input_required, _input_requests, _request_state}), do: :ok
  def status({:error, _code, _message, _data}), do: :error
end
