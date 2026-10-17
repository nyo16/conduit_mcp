defmodule ConduitMcp.Handler.Resources do
  @moduledoc false

  # `resources/list`, `resources/templates/list` and `resources/read`, plus the
  # uri authorization every resource route shares. Returns neutral
  # `ConduitMcp.Handler.result/0` values.

  alias ConduitMcp.Handler
  alias ConduitMcp.Handler.Common
  alias ConduitMcp.Handler.Pipeline
  alias ConduitMcp.ServerMeta

  @doc """
  `resources/list`.
  """
  @spec list(map(), module(), Plug.Conn.t()) :: Handler.result()
  def list(params, server_module, conn),
    do: Common.dispatch_list(params, server_module, conn, :handle_list_resources)

  @doc """
  `resources/templates/list`; an empty list when the server does not
  implement `handle_list_resource_templates/1`.
  """
  @spec list_templates(map(), module(), Plug.Conn.t()) :: Handler.result()
  def list_templates(_params, server_module, conn) do
    if ServerMeta.has?(server_module, :list_resource_templates) do
      Common.dispatch_callback(
        fn -> server_module.handle_list_resource_templates(conn) end,
        "handle_list_resource_templates"
      )
    else
      {:ok, %{"resourceTemplates" => []}}
    end
  end

  @doc """
  `resources/read`: authorization, dispatch, then the
  `[:conduit_mcp, :resource, :read]` event.
  """
  @spec read(map(), module(), Plug.Conn.t()) :: Handler.result()
  def read(params, server_module, conn) do
    uri = Map.get(params, "uri")
    start_time = System.monotonic_time()

    result =
      case authorize(uri, server_module, conn) do
        :ok ->
          Common.dispatch_callback(
            fn -> server_module.handle_read_resource(conn, uri) end,
            "handle_read_resource"
          )
          |> ensure_resource_uri(uri)

        {:error, :insufficient_scope, required} ->
          Common.insufficient_scope_error(required)

        {:error, :invalid_uri} ->
          Common.invalid_uri_error(uri)
      end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:conduit_mcp, :resource, :read],
      %{duration: duration},
      %{
        uri: Pipeline.telemetry_text(uri),
        server_module: server_module,
        status: Common.status(result)
      }
    )

    result
  end

  # `uri` is client input, and a templated resource's scope lookup matches it
  # with `Regex.run/2`, which raises for a non-binary. Gating on the type
  # first keeps a client mistake a -32602 rather than the request-path
  # rescue's -32603 and its error log. Used by every route that authorizes a
  # resource by uri: resources/read, subscribe and unsubscribe.
  @doc """
  Authorizes access to the resource at `uri`.
  """
  @spec authorize(term(), module(), Plug.Conn.t()) ::
          :ok | {:error, :insufficient_scope, String.t()} | {:error, :invalid_uri}
  def authorize(uri, server_module, conn) when is_binary(uri),
    do: Common.verify_scope(conn, Common.required_scope(server_module, :scope_for_resource, uri))

  def authorize(_uri, _server_module, _conn), do: {:error, :invalid_uri}

  # Ensures each item in a resource read result includes the "uri" field.
  # The MCP spec requires "uri" in every content item but resource handlers
  # often omit it since they don't know the request URI.
  defp ensure_resource_uri({:ok, %{"contents" => contents} = result}, uri)
       when is_list(contents) do
    updated = Enum.map(contents, fn item -> Map.put_new(item, "uri", uri) end)
    {:ok, %{result | "contents" => updated}}
  end

  defp ensure_resource_uri(result, _uri), do: result
end
