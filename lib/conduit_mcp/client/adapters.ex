defmodule ConduitMcp.Client.Adapters do
  @moduledoc """
  The agent-loop side of the LLM adapters: list a hub's (or one client's)
  tools in a provider's format, then run the tool calls a model made and
  answer them in the same format.

      {:ok, listing} = ConduitMcp.Client.Adapters.tools(MyApp.Hub, :anthropic)
      request = %{"model" => model, "messages" => messages, "tools" => listing.tools}

      # ... the response stops with "tool_use" ...
      case ConduitMcp.Client.Adapters.execute_tool_calls(MyApp.Hub, :anthropic, response,
             toolset: listing.toolset, principal: user_id) do
        {:ok, results} -> continue_with(%{"role" => "user", "content" => results})
        {:halt, results} -> stop_the_loop(results)
      end

  The provider modules (`ConduitMcp.Client.Adapters.Anthropic`, `OpenAI`,
  `Gemini`) stay pure; this module adds what needs processes: listing,
  running calls concurrently through `ConduitMcp.Client.Pipeline`, and
  telemetry.

  ## Hub or client

  `hub_or_client` is a `ConduitMcp.Client.Hub` name (tools are named
  `server__tool`, see `ConduitMcp.Client.Hub`) or a `ConduitMcp.Client`
  name (tools keep their own, sanitized names: a `namespace: false`
  toolset). A name registered as both is treated as the hub.

  Both are governed: a hub always has a policy (R6). A client without
  `:policy`, `:hooks`, `:tools` or `:validate` has no policy, so model
  calls through it are sent as asked; configure a policy on clients you
  hand to a model.

  ## Results

  `execute_tool_calls/4` answers every call in the model's order, each in
  the provider's result shape keyed by the call's id (`call.call_id`; for
  Gemini also the exposed name, via `ConduitMcp.Client.ToolSet.exposed_name/3`):

    * a call to a name the toolset does not hold, or with non-object
      arguments, gets the provider adapter's error answer and sends
      nothing (HB-2);
    * a call that completes gets its `ConduitMcp.Client.ToolResult`
      (`is_error` results included), shaped for a model (`shape: :llm`,
      PI-2) unless `shape: nil` is given;
    * a call that fails (denied, timed out, server unavailable, ...) gets
      an error answer with the `ConduitMcp.Client.Error` message.

  When an approver answered `{:deny, reason, :halt}` for any call, the
  return is `{:halt, results}`: answer the model if you like, but stop the
  agent loop. Otherwise it is `{:ok, results}`.

  ## Taint (HB-3)

  The calls of one turn run concurrently and see the same `:taint`. Once
  their results are in the model's context, add their servers
  (`call.server_id`) to the next turn's `taint:` so
  `ConduitMcp.Client.Policy.tainted/1` rules can react.
  """

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Adapters.{Anthropic, Gemini, OpenAI}
  alias ConduitMcp.Client.{Error, Hub, Naming, Registry, Request, Telemetry}
  alias ConduitMcp.Client.{ToolCall, ToolResult, ToolSet}

  @type provider :: :anthropic | :openai | :gemini

  @typedoc """
  What `tools/3` returns: the provider's tool definitions, the toolset they
  were built from (pass it to `execute_tool_calls/4` as `:toolset`) and,
  for OpenAI strict mode, the `null_paths` to pass as `:null_paths`.
  """
  @type listing :: %{
          tools: [map()],
          toolset: ToolSet.t(),
          null_paths: %{optional(String.t()) => [OpenAI.null_path()]}
        }

  @providers [:anthropic, :openai, :gemini]
  @listing_options [:assigns, :principal, :timeout, :refresh, :prefix]
  @adapter_options [
    :toolset,
    :null_paths,
    :api,
    :strict,
    :structured,
    :error_prefix,
    :cache_control,
    :max_concurrency,
    :call_timeout,
    :prefix,
    :refresh
  ]
  @default_call_timeout 300_000

  @doc """
  The toolset of `hub_or_client` for a model: `ConduitMcp.Client.Hub.list_tools/2`
  for a hub; for a client, its presented cached tools
  (`ConduitMcp.Client.cached_tools/2`, listing them first when nothing is
  cached) under their own names (`namespace: false`).

  ## Options

  `:assigns`, `:principal`, `:timeout`, `:refresh` (hub only) and `:prefix`
  (client only; a hub uses its own `:prefix`).
  """
  @spec toolset(term(), keyword()) :: {:ok, ToolSet.t()} | {:error, Error.t()}
  def toolset(hub_or_client, opts \\ []) do
    opts = Keyword.validate!(opts, @listing_options)

    if hub?(hub_or_client),
      do:
        Hub.list_tools(
          hub_or_client,
          Keyword.take(opts, [:assigns, :principal, :timeout, :refresh])
        ),
      else: client_toolset(hub_or_client, opts)
  end

  defp client_toolset(client, opts) do
    present = Keyword.take(opts, [:assigns, :principal])

    tools =
      case Client.cached_tools(client, present) do
        {:error, %Error{reason: :not_cached}} ->
          Client.list_all_tools(client, present ++ Keyword.take(opts, [:timeout]))

        other ->
          other
      end

    with {:ok, tools} <- tools,
         {:ok, _pid, view} <- Request.lookup(client) do
      {toolset, report} =
        Naming.build([{view.server_id, tools}],
          namespace: false,
          prefix: Keyword.get(opts, :prefix, "")
        )

      base = Telemetry.base(client, view.server_id, view.transport, view.era)

      for {_server_id, tool, reason} <- report.rejected,
          do: Telemetry.tool_rejected(base, Telemetry.sanitize(tool), reason)

      {:ok, toolset}
    end
  end

  @doc """
  Lists `hub_or_client`'s tools (`toolset/2`) in `provider`'s format.

  Returns `{:ok, %{tools: definitions, toolset: toolset, null_paths: map}}`:

    * `:anthropic` - `ConduitMcp.Client.Adapters.Anthropic.tools/2`
      (`:cache_control`);
    * `:openai` - `ConduitMcp.Client.Adapters.OpenAI.tools/2` (`:api`
      required, `:strict`); each tool sent non-strict under `strict: :auto`
      emits `[:conduit_mcp, :client, :adapter, :strict_fallback]`;
    * `:gemini` - `ConduitMcp.Client.Adapters.Gemini.function_declarations/1`
      (wrap them in `%{"functionDeclarations" => tools}`).

  Only tools in the toolset are emitted, so filtered, colliding and down
  servers' tools never reach the model (PO-7). Takes the `toolset/2`
  options too.
  """
  @spec tools(term(), provider(), keyword()) :: {:ok, listing()} | {:error, Error.t()}
  def tools(hub_or_client, provider, opts \\ []) when provider in @providers do
    with {:ok, toolset} <- toolset(hub_or_client, Keyword.take(opts, @listing_options)) do
      {:ok, encode(hub_or_client, provider, toolset, opts)}
    end
  end

  defp encode(_target, :anthropic, toolset, opts),
    do: listing(Anthropic.tools(toolset, Keyword.take(opts, [:cache_control])), toolset, %{})

  defp encode(_target, :gemini, toolset, _opts),
    do: listing(Gemini.function_declarations(toolset), toolset, %{})

  defp encode(target, :openai, toolset, opts) do
    {tools, report} = OpenAI.tools(toolset, Keyword.take(opts, [:api, :strict]))
    api = Keyword.fetch!(opts, :api)

    for {name, error} <- report.fallbacks,
        do: Telemetry.strict_fallback(target, api, name, error)

    listing(tools, toolset, report.null_paths)
  end

  defp listing(tools, toolset, null_paths),
    do: %{tools: tools, toolset: toolset, null_paths: null_paths}

  @doc """
  Runs the tool calls in a model response through the governed pipeline and
  returns the provider-shaped answers in the model's order (see
  "Results").

  `calls_or_response` is what the provider adapter parses (a response,
  message, content/part list or output item list), or a list of
  `ConduitMcp.Client.ToolCall`s for tools in the toolset.

  ## Options

    * `:toolset` - the toolset the model was offered (from `tools/3`);
      built with `toolset/2` when absent. Calls resolve against it only.
    * `:api` - `:chat | :responses`, required for `:openai`.
    * `:null_paths` - OpenAI strict-mode null paths (from `tools/3`).
    * `:max_concurrency` - calls run at once (default
      `System.schedulers_online/0`).
    * `:call_timeout` - milliseconds one call may take in all, approval and
      hooks included (default 300 000); a call over it is killed and
      answered with a `:timeout` error.
    * `:structured`, `:error_prefix` - passed to the provider's result
      builder.
    * `:shape` - `:llm` (default) or `nil`.
    * every other option goes to `ConduitMcp.Client.Pipeline.run/3`
      (`:principal`, `:assigns`, `:taint`, `:timeout`, `:meta`, progress
      options). `:task` is not supported.
  """
  @spec execute_tool_calls(term(), provider(), term(), keyword()) ::
          {:ok, [map()]} | {:halt, [map()]} | {:error, Error.t()}
  def execute_tool_calls(hub_or_client, provider, calls_or_response, opts \\ [])
      when provider in @providers do
    if Keyword.has_key?(opts, :task),
      do: raise(ArgumentError, "execute_tool_calls/4 does not take :task")

    if provider == :openai, do: api!(opts)

    hub? = hub?(hub_or_client)

    with {:ok, toolset} <- given_toolset(hub_or_client, opts) do
      parsed = parse(provider, calls_or_response, toolset, opts)
      outcomes = run_all(hub_or_client, hub?, parsed, toolset, opts)

      results =
        Enum.map(Enum.zip(parsed, outcomes), fn
          {{:rejected, answer}, :rejected} -> answer
          {{:call, call}, outcome} -> answer(provider, toolset, call, outcome, opts)
        end)

      if Enum.any?(outcomes, &halt?/1), do: {:halt, results}, else: {:ok, results}
    end
  end

  defp given_toolset(target, opts) do
    case Keyword.get(opts, :toolset) do
      %ToolSet{} = toolset -> {:ok, toolset}
      nil -> toolset(target, Keyword.take(opts, [:assigns, :principal, :timeout, :prefix]))
    end
  end

  # --- parsing -----------------------------------------------------------------------

  # Calls not in the toolset are kept: `run_one/5` answers them as unknown.
  defp parse(_provider, [%ToolCall{} | _] = calls, _toolset, _opts),
    do: Enum.map(calls, fn %ToolCall{} = call -> {:call, call} end)

  defp parse(:anthropic, response, toolset, _opts),
    do: Anthropic.__tool_calls__(response, toolset)

  defp parse(:gemini, response, toolset, _opts), do: Gemini.__function_calls__(response, toolset)

  defp parse(:openai, response, toolset, opts),
    do: OpenAI.__tool_calls__(response, toolset, Keyword.get(opts, :null_paths, %{}))

  # --- running -------------------------------------------------------------------------

  # One outcome per parsed entry, in order; a rejected entry runs nothing.
  defp run_all(target, hub?, parsed, toolset, opts) do
    pipeline_opts =
      opts
      |> Keyword.drop(@adapter_options)
      |> Keyword.put_new(:shape, :llm)

    jobs = for {{:call, call}, index} <- Enum.with_index(parsed), do: {index, call}
    done = jobs |> run_jobs(target, hub?, toolset, pipeline_opts, opts) |> Map.new()

    parsed
    |> Enum.with_index()
    |> Enum.map(fn
      {{:rejected, _answer}, _index} -> :rejected
      {{:call, _call}, index} -> Map.fetch!(done, index)
    end)
  end

  defp run_jobs([], _target, _hub?, _toolset, _pipeline_opts, _opts), do: []

  defp run_jobs(jobs, target, hub?, toolset, pipeline_opts, opts) do
    task_sup = if hub?, do: Hub.task_sup(target), else: Registry.via({:task_sup, target})

    task_sup
    |> Task.Supervisor.async_stream_nolink(
      jobs,
      fn {_index, call} -> run_one(target, hub?, toolset, call, pipeline_opts) end,
      max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online()),
      timeout: Keyword.get(opts, :call_timeout, @default_call_timeout),
      on_timeout: :kill_task
    )
    |> Enum.zip(jobs)
    |> Enum.map(fn
      {{:ok, outcome}, {index, _call}} ->
        {index, outcome}

      {{:exit, :timeout}, {index, _call}} ->
        {index, {:error, Error.new(:timeout, :call_timeout)}}

      {{:exit, _reason}, {index, _call}} ->
        {index, {:error, Error.new(:unavailable, :call_exited)}}
    end)
  catch
    :exit, _no_task_sup ->
      for {index, _call} <- jobs, do: {index, {:error, Error.new(:unavailable, :not_started)}}
  end

  defp run_one(target, hub?, toolset, %ToolCall{} = call, pipeline_opts) do
    with {:ok, exposed} <- ToolSet.exposed_name(toolset, call.server_id, call.name),
         {:ok, tool} <- ToolSet.resolve(toolset, exposed) do
      if hub?,
        do: Hub.__run__(target, call, tool, pipeline_opts),
        else: Client.Pipeline.run(target, call, Keyword.put(pipeline_opts, :tool, tool))
    else
      :error -> {:ok, Hub.__unknown_tool__(call.name)}
    end
  end

  defp halt?({:error, %Error{kind: :denied, reason: :ask_halt}}), do: true
  defp halt?(_outcome), do: false

  # --- answers ----------------------------------------------------------------------------

  defp answer(provider, toolset, call, outcome, opts) do
    result =
      case outcome do
        {:ok, %ToolResult{} = result} -> result
        {:ok, _task} -> Error.new(:protocol, :unexpected_task)
        {:error, %Error{} = error} -> error
      end

    render(provider, toolset, call, result, opts)
  end

  defp render(:anthropic, _toolset, call, result, opts),
    do: Anthropic.tool_result(call.call_id, result, Keyword.take(opts, [:structured]))

  defp render(:openai, _toolset, call, result, opts),
    do:
      OpenAI.tool_output(
        call.call_id,
        result,
        Keyword.take(opts, [:api, :structured, :error_prefix])
      )

  defp render(:gemini, toolset, call, result, opts) do
    name =
      case ToolSet.exposed_name(toolset, call.server_id, call.name) do
        {:ok, name} -> name
        :error -> call.name
      end

    Gemini.function_response(
      name,
      result,
      [id: call.call_id] ++ Keyword.take(opts, [:structured])
    )
  end

  defp api!(opts) do
    unless Keyword.get(opts, :api) in [:chat, :responses],
      do: raise(ArgumentError, "the :api option is required for :openai (:chat or :responses)")

    :ok
  end

  defp hub?(target), do: match?({:ok, _ref}, Hub.__lookup__(target))
end
