defmodule ConduitMcp.Client do
  @moduledoc """
  An MCP client: one supervised connection to one MCP server, speaking the
  modern (`2026-07-28`) or a legacy (`2025-11-25`, `2025-06-18`) protocol
  era, whichever the server supports.

  ## Starting

  Add a client to your supervision tree. Starting never blocks on the
  server: the connection is established in the background.

      children = [
        {ConduitMcp.Client,
         name: MyApp.Docs,
         transport: {ConduitMcp.Client.Transport.InProcess, server: MyApp.DocsServer}}
      ]

  Options are validated when the child spec is built, so a typo fails at
  boot naming the key; see `ConduitMcp.Client.Config` for all of them.
  `:name` may be any term (`{MyApp.Docs, tenant_id}` works) and is how
  every function below addresses the client. The application starts no
  clients itself; it only runs the registry they register in.

  Each client is a supervisor (`:one_for_all`) of a `Task.Supervisor` and a
  `ConduitMcp.Client.Connection`. Use `await_ready/2` when you need the
  handshake done before going on; requests made earlier simply wait for it
  (within their own timeout).

  ## Calling

  Every request function runs in the calling process and returns
  `{:ok, value}` or `{:error, %ConduitMcp.Client.Error{}}`. A tool that ran
  and reported failure is **not** an error: `call_tool/4` returns
  `{:ok, %ConduitMcp.Client.ToolResult{is_error: true}}`. Errors are for
  protocol, transport and limit failures (match on `kind`).

  Request options, accepted by every request function:

    * `:timeout` - milliseconds before the request is cancelled (default
      the client's `:request_timeout`, 60 s).
    * `:on_progress` - a one-arity function, or a pid sent
      `{:mcp_progress, name, params}`, for `notifications/progress`.
    * `:reset_timeout_on_progress` - restart `:timeout` on each progress
      notification, capped by `:max_total_timeout`.
    * `:max_total_timeout` - see above.
    * `:meta` - a map merged into the request's `_meta`. Keys the protocol
      reserves (`progressToken`, `io.modelcontextprotocol/*`) are dropped.

  ## Eras

  With the default `protocol: :auto` the client probes `server/discover`
  and falls back to `initialize` only on legacy evidence. The era decides
  the wire format; the functions here work in both, with these
  exceptions: `ping/2` sends `server/discover` to a modern server,
  `set_log_level/2` is a request in legacy and a per-request `_meta` value
  in modern, and `notify_roots_changed/1` is legacy only.

  In the modern era `call_tool/4`, `read_resource/3` and `get_prompt/4` may
  get `resultType: "input_required"`; the client runs the
  multi-round-trip loop (`ConduitMcp.Client.Request.MRTR`) in the caller.
  This client does not answer input requests yet: one that its handler
  does not declare fails with `kind: :protocol`, and one it declares fails
  with `kind: :input_handler`.

  ## Notifications

  `subscribe_notifications/2` sends server notifications to a process as
  `{:mcp_notification, name, method, params}`; see
  `ConduitMcp.Client.Connection` for coalescing of `list_changed`.
  """

  use Supervisor

  alias ConduitMcp.Client.Config
  alias ConduitMcp.Client.Connection
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Prompt
  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Request
  alias ConduitMcp.Client.Request.MRTR
  alias ConduitMcp.Client.Resource
  alias ConduitMcp.Client.Telemetry
  alias ConduitMcp.Client.Tool
  alias ConduitMcp.Client.ToolResult

  @typedoc "The `:name` a client was started with."
  @type client :: term()

  @typedoc "A page of a list request; `next_cursor` is `nil` on the last page."
  @type page(key, item) :: %{required(key) => [item], required(:next_cursor) => String.t() | nil}

  @typedoc """
  The connection's state as `status/1` reports it. `reason` explains a
  `:closed` state and is `nil` otherwise.
  """
  @type status :: %{
          state: :connecting | :discovering | :initializing | :ready | :reconnecting | :closed,
          era: :modern | :legacy | nil,
          version: String.t() | nil,
          reason: term()
        }

  @typedoc "What the server said about itself in the handshake."
  @type server_info :: %{
          era: :modern | :legacy,
          version: String.t(),
          server_info: ConduitMcp.Client.ServerInfo.t() | nil,
          capabilities: map(),
          instructions: String.t() | nil
        }

  @request_options [:timeout, :on_progress, :reset_timeout_on_progress, :max_total_timeout]
  @control_timeout 5_000

  # --- supervision -------------------------------------------------------------

  @doc """
  The child spec for a client. Validates the options (raising
  `ArgumentError` naming a bad key); the id is `{ConduitMcp.Client, name}`,
  so one supervisor can hold many clients.

      iex> spec =
      ...>   ConduitMcp.Client.child_spec(
      ...>     name: :docs,
      ...>     transport: {ConduitMcp.Client.Transport.InProcess, server: ConduitMcp.TestServer}
      ...>   )
      iex> spec.id
      {ConduitMcp.Client, :docs}
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    config = Config.new!(opts)

    %{
      id: {__MODULE__, config.name},
      start: {__MODULE__, :start_link, [config]},
      type: :supervisor
    }
  end

  @doc """
  Starts a client (see `ConduitMcp.Client.Config` for the options). Returns
  once the processes exist, without waiting for the server.

      {:ok, _pid} =
        ConduitMcp.Client.start_link(
          name: :docs,
          transport: {ConduitMcp.Client.Transport.InProcess, server: MyApp.DocsServer}
        )
  """
  @spec start_link(keyword() | Config.t()) :: Supervisor.on_start()
  def start_link(opts) do
    config = Config.new!(opts)
    Supervisor.start_link(__MODULE__, config, name: Registry.via({:supervisor, config.name}))
  end

  @impl Supervisor
  def init(%Config{} = config) do
    children = [
      {Task.Supervisor, name: Registry.via({:task_sup, config.name})},
      {Connection, config}
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 3, max_seconds: 5)
  end

  # --- lifecycle -----------------------------------------------------------------

  @doc """
  Waits until the client is ready to send requests. Returns `:ok`, or
  `{:error, %Error{kind: :timeout}}` after `timeout` ms, or the `:closed`
  error at once if the connection gave up.

      :ok = ConduitMcp.Client.await_ready(:docs, 5_000)
  """
  @spec await_ready(client(), timeout()) :: :ok | {:error, Error.t()}
  def await_ready(client, timeout \\ @control_timeout),
    do: Request.call(client, :await_ready, timeout)

  @doc """
  The connection's current state, read without messaging it.

      {:ok, %{state: :ready, era: :modern}} = ConduitMcp.Client.status(:docs)
  """
  @spec status(client()) :: {:ok, status()} | {:error, Error.t()}
  def status(client) do
    with {:ok, _pid, view} <- Request.lookup(client) do
      {:ok, %{state: view.state, era: view.era, version: view.version, reason: view.reason}}
    end
  end

  @doc """
  What the server reported in the handshake: its `ServerInfo`, capabilities
  and instructions, with the negotiated era and version.
  `{:error, %Error{kind: :unavailable, reason: :not_ready}}` while the
  client is not ready.

      {:ok, %{capabilities: %{"tools" => _}}} = ConduitMcp.Client.server_info(:docs)
  """
  @spec server_info(client()) :: {:ok, server_info()} | {:error, Error.t()}
  def server_info(client) do
    with {:ok, _pid, view} <- Request.lookup(client) do
      case view.server do
        nil ->
          {:error, Error.new(:unavailable, :not_ready)}

        server ->
          {:ok, Map.merge(server, %{era: view.era, version: view.version})}
      end
    end
  end

  @doc """
  The negotiated protocol era (`:modern` or `:legacy`), kept while the
  client reconnects. `{:error, %Error{kind: :unavailable}}` before the first
  handshake.

      {:ok, :modern} = ConduitMcp.Client.era(:docs)
  """
  @spec era(client()) :: {:ok, :modern | :legacy} | {:error, Error.t()}
  def era(client) do
    case Request.lookup(client) do
      {:ok, _pid, %{era: nil}} -> {:error, Error.new(:unavailable, :not_negotiated)}
      {:ok, _pid, %{era: era}} -> {:ok, era}
      error -> error
    end
  end

  @doc """
  Closes the connection: pending requests fail with `kind: :closed`, the
  transport is closed, and the client stays in `:closed` (answering every
  request at once) until `reconnect/1`.

      :ok = ConduitMcp.Client.close(:docs)
  """
  @spec close(client()) :: :ok | {:error, Error.t()}
  def close(client), do: Request.call(client, :close, @control_timeout)

  @doc """
  Drops the current connection (pending requests fail with
  `kind: :transport`) and connects again at once, with the reconnect count
  reset. Also revives a `:closed` client.

      :ok = ConduitMcp.Client.reconnect(:docs)
  """
  @spec reconnect(client()) :: :ok | {:error, Error.t()}
  def reconnect(client), do: Request.call(client, :reconnect, @control_timeout)

  # --- requests ------------------------------------------------------------------

  @doc """
  Checks the server answers: a legacy `ping`, or `server/discover` for a
  modern server (which has no `ping`).

      :ok = ConduitMcp.Client.ping(:docs, timeout: 1_000)
  """
  @spec ping(client(), keyword()) :: :ok | {:error, Error.t()}
  def ping(client, opts \\ []) do
    with {:ok, _result} <- request(client, :ping, %{}, opts), do: :ok
  end

  @doc """
  Lists one page of tools. Pass the previous page's `next_cursor` as
  `:cursor` for the next one.

      {:ok, %{tools: [%ConduitMcp.Client.Tool{name: "echo"} | _], next_cursor: nil}} =
        ConduitMcp.Client.list_tools(:docs)
  """
  @spec list_tools(client(), keyword()) :: {:ok, page(:tools, Tool.t())} | {:error, Error.t()}
  def list_tools(client, opts \\ []),
    do: list_page(client, "tools/list", "tools", :tools, &Tool.from_wire/2, opts)

  @doc """
  Calls tool `name` with `args` (string- or atom-keyed; sent as given).

  A tool that ran and failed is `{:ok, %ToolResult{is_error: true}}`.

      {:ok, %ConduitMcp.Client.ToolResult{content: [%{"text" => "hi"}]}} =
        ConduitMcp.Client.call_tool(:docs, "echo", %{"message" => "hi"})
  """
  @spec call_tool(client(), String.t(), map(), keyword()) ::
          {:ok, ToolResult.t()} | {:error, Error.t()}
  def call_tool(client, name, args \\ %{}, opts \\ []) when is_binary(name) and is_map(args) do
    with {:ok, _pid, view} <- Request.lookup(client) do
      base = Telemetry.base(client, view.server_id, view.transport, view.era)

      Telemetry.tool_call_span(base, name, fn ->
        params = %{"name" => name, "arguments" => args}

        case mrtr(client, "tools/call", params, view, opts) do
          {:ok, result, %{rounds: rounds}} -> {ToolResult.from_wire(result), rounds}
          {:error, _} = error -> {error, 0}
        end
      end)
    end
  end

  @doc """
  `call_tool/4` in a task under the client's `Task.Supervisor`
  (`Task.Supervisor.async_nolink/2`): await it with `Task.await/2` or
  `Task.yield/2`. A crash in the task does not take the caller down.
  Exits with `:noproc` if the client is not running.

      task = ConduitMcp.Client.async_call_tool(:docs, "echo", %{"message" => "hi"})
      {:ok, %ConduitMcp.Client.ToolResult{}} = Task.await(task)
  """
  @spec async_call_tool(client(), String.t(), map(), keyword()) :: Task.t()
  def async_call_tool(client, name, args \\ %{}, opts \\ []) do
    Task.Supervisor.async_nolink(Registry.via({:task_sup, client}), fn ->
      call_tool(client, name, args, opts)
    end)
  end

  @doc """
  Lists one page of resources (`:cursor` as in `list_tools/2`).

      {:ok, %{resources: [%ConduitMcp.Client.Resource{} | _]}} =
        ConduitMcp.Client.list_resources(:docs)
  """
  @spec list_resources(client(), keyword()) ::
          {:ok, page(:resources, Resource.t())} | {:error, Error.t()}
  def list_resources(client, opts \\ []),
    do: list_page(client, "resources/list", "resources", :resources, &Resource.from_wire/2, opts)

  @doc """
  Lists one page of resource templates, as the server's string-keyed
  `ResourceTemplate` maps (`:cursor` as in `list_tools/2`).

      {:ok, %{resource_templates: [%{"uriTemplate" => "item://{id}"} | _]}} =
        ConduitMcp.Client.list_resource_templates(:docs)
  """
  @spec list_resource_templates(client(), keyword()) ::
          {:ok, page(:resource_templates, map())} | {:error, Error.t()}
  def list_resource_templates(client, opts \\ []) do
    list_page(
      client,
      "resources/templates/list",
      "resourceTemplates",
      :resource_templates,
      &raw_object/2,
      opts
    )
  end

  @doc """
  Reads the resource at `uri`; returns the server's string-keyed
  `ReadResourceResult` (`"contents"`).

      {:ok, %{"contents" => [%{"text" => _} | _]}} =
        ConduitMcp.Client.read_resource(:docs, "test://resource1")
  """
  @spec read_resource(client(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def read_resource(client, uri, opts \\ []) when is_binary(uri) do
    with {:ok, _pid, view} <- Request.lookup(client),
         {:ok, result, _rounds} <- mrtr(client, "resources/read", %{"uri" => uri}, view, opts),
         do: {:ok, result}
  end

  @doc """
  Lists one page of prompts (`:cursor` as in `list_tools/2`).

      {:ok, %{prompts: [%ConduitMcp.Client.Prompt{name: "greeting"} | _]}} =
        ConduitMcp.Client.list_prompts(:docs)
  """
  @spec list_prompts(client(), keyword()) ::
          {:ok, page(:prompts, Prompt.t())} | {:error, Error.t()}
  def list_prompts(client, opts \\ []),
    do: list_page(client, "prompts/list", "prompts", :prompts, &Prompt.from_wire/2, opts)

  @doc """
  Gets prompt `name` with `args`. Prompt arguments are strings on the wire,
  so keys and values are converted: atoms, numbers and booleans with
  `to_string/1`, other non-strings as JSON. `nil` values are dropped.
  Returns the server's string-keyed `GetPromptResult` (`"messages"`).

      {:ok, %{"messages" => [_ | _]}} =
        ConduitMcp.Client.get_prompt(:docs, "greeting", %{name: "Ada"})
  """
  @spec get_prompt(client(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_prompt(client, name, args \\ %{}, opts \\ []) when is_binary(name) and is_map(args) do
    params = %{"name" => name, "arguments" => stringify_args(args)}

    with {:ok, _pid, view} <- Request.lookup(client),
         {:ok, result, _rounds} <- mrtr(client, "prompts/get", params, view, opts),
         do: {:ok, result}
  end

  @doc """
  Asks for completions of `argument` of `ref`. Returns the server's
  string-keyed `CompleteResult` (`"completion"`).

  `ref` is `{:prompt, name}`, `{:resource, uri_template}` or a wire
  reference map; `argument` is `{name, value}` or a wire map.

  ## Options

  The request options, plus `:context` - already-resolved arguments,
  `%{"arguments" => %{...}}`.

      {:ok, %{"completion" => %{"values" => _}}} =
        ConduitMcp.Client.complete(:docs, {:prompt, "greeting"}, {"name", "A"})
  """
  @spec complete(
          client(),
          {:prompt | :resource, String.t()} | map(),
          {String.t(), String.t()} | map(),
          keyword()
        ) ::
          {:ok, map()} | {:error, Error.t()}
  def complete(client, ref, argument, opts \\ []) do
    {context, opts} = Keyword.pop(opts, :context)

    params =
      %{"ref" => completion_ref(ref), "argument" => completion_argument(argument)}
      |> put_present("context", context)

    request(client, "completion/complete", params, opts)
  end

  @doc """
  Sets the server's log level (`"debug"` … `"emergency"`, string or atom).
  Legacy: sends `logging/setLevel`. Modern: the level is sent in the
  `_meta` of every later request; a modern server sends no log
  notifications for requests without one.

      :ok = ConduitMcp.Client.set_log_level(:docs, :warning)
  """
  @spec set_log_level(client(), String.t() | atom()) :: :ok | {:error, Error.t()}
  def set_log_level(client, level) when is_atom(level),
    do: set_log_level(client, Atom.to_string(level))

  def set_log_level(client, level) when is_binary(level) do
    unless level in ConduitMcp.Ctx.log_levels() do
      raise ArgumentError,
            "log level must be one of #{Enum.join(ConduitMcp.Ctx.log_levels(), ", ")}, " <>
              "got: #{inspect(level)}"
    end

    with {:ok, _result} <- request(client, {:set_log_level, level}, %{}, []), do: :ok
  end

  @doc """
  Sends `notifications/roots/list_changed` (legacy only; the client
  declares `roots.listChanged` when its handler implements `list_roots/1`).
  In the modern era, or without a roots handler, returns
  `{:error, %Error{kind: :protocol}}`.

      :ok = ConduitMcp.Client.notify_roots_changed(:docs)
  """
  @spec notify_roots_changed(client()) :: :ok | {:error, Error.t()}
  def notify_roots_changed(client) do
    with {:ok, _result} <- request(client, :roots_list_changed, %{}, []), do: :ok
  end

  @doc """
  Sends server notifications to `pid` (default: the caller) as
  `{:mcp_notification, name, method, params}`. Idempotent; the subscription
  ends when `pid` exits or `unsubscribe_notifications/2` is called.
  `notifications/progress` goes to the request's caller instead.

      :ok = ConduitMcp.Client.subscribe_notifications(:docs)

      receive do
        {:mcp_notification, :docs, "notifications/tools/list_changed", _params} -> :refresh
      end
  """
  @spec subscribe_notifications(client(), pid()) :: :ok | {:error, Error.t()}
  def subscribe_notifications(client, pid \\ self()) when is_pid(pid),
    do: Request.call(client, {:subscribe, pid}, @control_timeout)

  @doc """
  Stops sending server notifications to `pid` (default: the caller).

      :ok = ConduitMcp.Client.unsubscribe_notifications(:docs)
  """
  @spec unsubscribe_notifications(client(), pid()) :: :ok | {:error, Error.t()}
  def unsubscribe_notifications(client, pid \\ self()) when is_pid(pid),
    do: Request.call(client, {:unsubscribe, pid}, @control_timeout)

  # --- helpers ---------------------------------------------------------------------

  defp request(client, op, params, opts) do
    {meta, opts} = Keyword.pop(opts, :meta)
    Request.run(client, op, put_meta(params, meta), request_opts(opts))
  end

  defp request_opts(opts), do: Keyword.validate!(opts, @request_options)

  defp put_meta(params, nil), do: params
  defp put_meta(params, meta) when is_map(meta), do: Map.put(params, "_meta", meta)

  defp list_page(client, method, key, page_key, decode, opts) do
    {cursor, opts} = Keyword.pop(opts, :cursor)

    with {:ok, _pid, view} <- Request.lookup(client),
         {:ok, result} <- request(client, method, put_present(%{}, "cursor", cursor), opts),
         {:ok, items} <- decode_items(Map.get(result, key, []), view.server_id, decode) do
      {:ok, %{page_key => items, :next_cursor => next_cursor(result)}}
    end
  end

  defp decode_items(items, server_id, decode) when is_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case decode.(server_id, item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp decode_items(other, _server_id, _decode),
    do: {:error, Error.new(:protocol, :invalid_list_result, other)}

  defp raw_object(_server_id, %{} = map) when not is_struct(map), do: {:ok, map}
  defp raw_object(_server_id, other), do: {:error, Error.new(:protocol, :invalid_item, other)}

  defp next_cursor(%{"nextCursor" => cursor}) when is_binary(cursor), do: cursor
  defp next_cursor(_result), do: nil

  # tools/call, resources/read and prompts/get may answer `input_required`;
  # each round is its own request (a fresh id from the connection).
  defp mrtr(client, method, params, view, opts) do
    {meta, opts} = Keyword.pop(opts, :meta)
    opts = request_opts(opts)

    MRTR.run(method, put_meta(params, meta),
      send: fn _id, method, params -> Request.run(client, method, params, opts) end,
      next_id: fn -> nil end,
      handle_input: fn _key, _request -> {:error, :no_input_handler} end,
      capabilities: view.client_capabilities
    )
  end

  defp stringify_args(args) do
    for {key, value} <- args, value != nil, into: %{} do
      {to_text(key), to_text(value)}
    end
  end

  defp to_text(value) when is_binary(value), do: value

  defp to_text(value) when is_atom(value) or is_number(value),
    do: to_string(value)

  defp to_text(value), do: JSON.encode!(value)

  defp completion_ref({:prompt, name}) when is_binary(name),
    do: %{"type" => "ref/prompt", "name" => name}

  defp completion_ref({:resource, uri}) when is_binary(uri),
    do: %{"type" => "ref/resource", "uri" => uri}

  defp completion_ref(%{} = ref), do: ref

  defp completion_argument({name, value}) when is_binary(name) and is_binary(value),
    do: %{"name" => name, "value" => value}

  defp completion_argument(%{} = argument), do: argument

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
