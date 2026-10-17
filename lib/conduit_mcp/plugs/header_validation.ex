defmodule ConduitMcp.Plugs.HeaderValidation do
  @moduledoc """
  Validates the MCP request-metadata headers of a modern (`2026-07-28`)
  Streamable HTTP request against its JSON-RPC body.

  Intermediaries may route on these headers without parsing the body, so a
  header that disagrees with the body is a split-brain hazard, not a
  formatting nit. Every failure halts with HTTP 400 and a modern JSON-RPC
  error.

  Runs after `Plug.Parsers`. It uses the request's `ConduitMcp.Ctx` from
  `conn.private[:mcp_ctx]` when one is stored, and otherwise classifies the
  body with `ConduitMcp.Era.classify/2` itself (storing the result) — a
  classification failure is answered here with 400 too. Legacy requests, and
  an era-exempt `server/discover` sent without `_meta`, pass through
  untouched.

  ## Checks, in order

  1. `MCP-Protocol-Version` is present, single, and equal to the `_meta`
     protocol version — else `-32020`.
  2. That version is one this server implements — else `-32022`, with
     `data.supported` and `data.requested`. The mismatch check comes first:
     a header that disagrees with the body is `-32020` even when neither
     version is supported.
  3. `Mcp-Method` is present, single, and equal to the body `method` — else
     `-32020`.
  4. On `tools/call`, `prompts/get` and `resources/read` only: `Mcp-Name` is
     present, single, and — after decoding the `=?base64?…?=` sentinel —
     equal to `params.name` (`params.uri` for `resources/read`) — else
     `-32020`.
  5. On `tools/call`: for every parameter of the called tool annotated with
     `"x-mcp-header": "Name"`, `Mcp-Param-Name` must be present and match the
     argument (integers compare numerically, `42` equals `42.0`) when the
     argument has a non-null value, and must be absent when it does not —
     else `-32020`. A malformed sentinel is a mismatch too.

  Error messages name the header only. They never echo a header or body
  value, and nothing here logs one.

  ## Tool-schema cache

  The `x-mcp-header` annotations come from the server's own `tools/list`
  (`handle_list_tools`, following `nextCursor`), computed on the first
  `tools/call` and cached per server module in `:persistent_term`. Tools
  whose annotations are invalid (see
  `ConduitMcp.Headers.validate_x_mcp_header/1`) are ignored: conforming
  clients drop them from their tool lists.

  The tool list is read from the server module in
  `conn.private[:server_module]` (set by both transports). DSL and Endpoint
  servers have a compile-time tool list, so the cache never
  goes stale. A manual-mode server whose tool list changes at runtime must
  call `invalidate/1` after the change; the next `tools/call` rebuilds the
  entry. `:persistent_term` updates are expensive (a global GC pass), so the
  cache suits tool lists that change rarely. A tool missing from the cached
  list has no annotated parameters as far as this plug is concerned; the
  handler rejects an unknown tool on its own.
  """

  @behaviour Plug

  alias ConduitMcp.Ctx
  alias ConduitMcp.Era
  alias ConduitMcp.Errors
  alias ConduitMcp.Handler.Common
  alias ConduitMcp.Headers
  alias ConduitMcp.Protocol

  @max_list_pages 100

  # Visible ASCII plus space and tab: what RFC 9110 permits in a field value.
  # A recognized header carrying anything else is rejected before decoding.
  @field_value ~r/\A[\x20-\x7E\t]*\z/

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{body_params: request} = conn, _opts)
      when is_map(request) and not is_struct(request) do
    case context(conn, request) do
      {:ok, %Ctx{era: :modern, version: version} = ctx} when is_binary(version) ->
        conn = Ctx.put(ctx.conn, ctx)

        case validate(conn, request, ctx) do
          :ok -> conn
          {:error, code, message, data} -> reject(conn, request, {code, message, data})
        end

      {:ok, ctx} ->
        Ctx.put(ctx.conn, ctx)

      {:error, code, message, data} ->
        reject(conn, request, {code, message, data})
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  Drops the cached `x-mcp-header` annotations for `server_module`; the next
  modern `tools/call` re-reads them from `handle_list_tools`.
  """
  @spec invalidate(module()) :: :ok
  def invalidate(server_module) do
    _ = :persistent_term.erase(cache_key(server_module))
    :ok
  end

  defp context(conn, request) do
    case Ctx.from_conn(conn) do
      %Ctx{} = ctx -> {:ok, ctx}
      nil -> Era.classify(request, conn)
    end
  end

  defp validate(conn, request, ctx) do
    method = Map.get(request, "method")
    params = Map.get(request, "params")
    params = if is_map(params), do: params, else: %{}

    with :ok <- check_version_header(conn, ctx),
         :ok <- Era.check_version(ctx),
         :ok <- check_method_header(conn, method),
         :ok <- check_name_header(conn, method, params) do
      check_param_headers(conn, method, params)
    end
  end

  # --- MCP-Protocol-Version ---------------------------------------------

  defp check_version_header(conn, ctx) do
    case single_header(conn, "mcp-protocol-version", "MCP-Protocol-Version") do
      {:ok, value} when value == ctx.version -> :ok
      {:ok, _value} -> mismatch("MCP-Protocol-Version header does not match the request body")
      error -> error
    end
  end

  # --- Mcp-Method ---------------------------------------------------------

  defp check_method_header(conn, method) do
    case single_header(conn, "mcp-method", "Mcp-Method") do
      {:ok, value} when value == method -> :ok
      {:ok, _value} -> mismatch("Mcp-Method header does not match the request body")
      error -> error
    end
  end

  # --- Mcp-Name -----------------------------------------------------------

  defp check_name_header(conn, method, params) do
    case Headers.name_param(method) do
      nil -> :ok
      key -> compare_name(conn, Map.get(params, key))
    end
  end

  defp compare_name(conn, body_value) do
    with {:ok, value} <- single_header(conn, "mcp-name", "Mcp-Name"),
         {:ok, decoded} <- decode(value, "Mcp-Name") do
      if is_binary(body_value) and decoded == body_value,
        do: :ok,
        else: mismatch("Mcp-Name header does not match the request body")
    end
  end

  # --- Mcp-Param-* --------------------------------------------------------

  defp check_param_headers(conn, "tools/call", params) do
    server_module = conn.private[:server_module]
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments")
    arguments = if is_map(arguments), do: arguments, else: %{}

    if is_atom(server_module) and not is_nil(server_module) and is_binary(tool_name) do
      server_module
      |> annotated_params(conn, tool_name)
      |> Enum.reduce_while(:ok, fn param, :ok ->
        case check_param(conn, param, arguments) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      :ok
    end
  end

  defp check_param_headers(_conn, _method, _params), do: :ok

  defp check_param(conn, %{header: name, path: path}, arguments) do
    label = "Mcp-Param-" <> name
    values = Plug.Conn.get_req_header(conn, "mcp-param-" <> String.downcase(name))

    case {argument_at(arguments, path), values} do
      {nil, []} -> :ok
      {nil, _values} -> mismatch("#{label} header is present but the argument is not")
      {_value, []} -> mismatch("missing #{label} header")
      {value, [header]} -> compare_param(header, value, label)
      {_value, _values} -> mismatch("multiple #{label} headers")
    end
  end

  defp compare_param(header, value, label) do
    with {:ok, decoded} <- decode(header, label) do
      if Headers.value_matches?(decoded, value),
        do: :ok,
        else: mismatch("#{label} header does not match the request body")
    end
  end

  defp argument_at(value, []), do: value

  defp argument_at(%{} = map, [key | rest]), do: argument_at(Map.get(map, key), rest)

  defp argument_at(_value, _path), do: nil

  # --- annotation cache -----------------------------------------------------

  defp annotated_params(server_module, conn, tool_name) do
    server_module
    |> annotations(conn)
    |> Map.get(tool_name, [])
  end

  defp annotations(server_module, conn) do
    key = cache_key(server_module)

    case :persistent_term.get(key, nil) do
      nil ->
        case build_annotations(server_module, conn) do
          {:ok, annotations} ->
            :persistent_term.put(key, annotations)
            annotations

          :error ->
            %{}
        end

      annotations ->
        annotations
    end
  end

  defp build_annotations(server_module, conn) do
    if Code.ensure_loaded?(server_module) and
         (function_exported?(server_module, :handle_list_tools, 1) or
            function_exported?(server_module, :handle_list_tools, 2)) do
      collect_tools(server_module, conn, %{}, 0, %{})
    else
      {:ok, %{}}
    end
  end

  defp collect_tools(_server_module, _conn, _params, @max_list_pages, acc), do: {:ok, acc}

  defp collect_tools(server_module, conn, params, page, acc) do
    case Common.call_list_callback(server_module, :handle_list_tools, conn, params) do
      {:ok, %{"tools" => tools} = result} when is_list(tools) ->
        acc = Enum.reduce(tools, acc, &put_tool_annotations/2)

        case Map.get(result, "nextCursor") do
          cursor when is_binary(cursor) ->
            collect_tools(server_module, conn, %{"cursor" => cursor}, page + 1, acc)

          _ ->
            {:ok, acc}
        end

      _ ->
        :error
    end
  end

  defp put_tool_annotations(%{"name" => name, "inputSchema" => schema}, acc)
       when is_binary(name) and is_map(schema) do
    case Headers.validate_x_mcp_header(schema) do
      :ok ->
        case Headers.header_params(schema) do
          [] -> acc
          params -> Map.put(acc, name, params)
        end

      {:error, _reasons} ->
        acc
    end
  end

  defp put_tool_annotations(_tool, acc), do: acc

  defp cache_key(server_module), do: {__MODULE__, server_module}

  # --- helpers --------------------------------------------------------------

  defp single_header(conn, name, label) do
    case Plug.Conn.get_req_header(conn, name) do
      [value] ->
        if Regex.match?(@field_value, value),
          do: {:ok, value},
          else: mismatch("#{label} header contains invalid characters")

      [] ->
        mismatch("missing #{label} header")

      _values ->
        mismatch("multiple #{label} headers")
    end
  end

  defp decode(value, label) do
    with true <- Regex.match?(@field_value, value),
         {:ok, decoded} <- Headers.decode_value(value) do
      {:ok, decoded}
    else
      _ -> mismatch("#{label} header is malformed")
    end
  end

  defp mismatch(message),
    do: {:error, Errors.header_mismatch(), "Header mismatch: " <> message, nil}

  defp reject(conn, request, {code, message, data}) do
    body =
      Protocol.Modern.to_response(
        Map.get(request, "id"),
        Map.get(request, "method"),
        {:error, code, message, data}
      )

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(400, JSON.encode!(body))
    |> Plug.Conn.halt()
  end
end
