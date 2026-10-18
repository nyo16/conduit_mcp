defmodule ConduitMcp.Client.Pipeline do
  @moduledoc """
  The governed tool call: selection, hooks, schema validation, policy and
  approval around one `tools/call`, run **in the calling process**.

  `ConduitMcp.Client.call_tool/4` goes through the pipeline when the client
  is configured with any of `:policy`, `:hooks`, `:tools` (a filter) or
  `:validate`, or when the call asks for `shape: :llm`; otherwise it sends
  the call as given (a plain client has no policy, R6). `run/3` is the
  entry point for code that already holds a `ConduitMcp.Client.ToolCall` or
  a resolved `ConduitMcp.Client.Tool` (a hub, an LLM adapter loop).

  ## Steps (R4)

  Every step runs once per logical call, in this order:

   1. **Resolve** the tool in the client's cache (listing the tools first if
      the cache has none). An unknown tool is
      `{:error, %Error{kind: :not_found, reason: :unknown_tool}}`.
   2. **Select**: a tool hidden by the `:tools` filter
      (`ConduitMcp.Client.ToolFilter.visible?/3`) fails exactly like an
      unknown one (PO-7), so its name cannot be probed.
   3. **Fingerprint**: the approved fingerprints are gathered (see
      "Approvals") for the policy's pin.
   4. **Pre-hooks** (`ConduitMcp.Client.Hooks`), which may rewrite the
      arguments, deny, halt with a synthetic result, or fail closed.
   5. **Input-schema validation** (`validate: [arguments: true]`): invalid
      arguments are never sent.
   6. **Policy** (`ConduitMcp.Client.Policy.evaluate/4`) on the final
      arguments: deny > pin > ask > allow > default. A deny is
      `{:error, %Error{kind: :denied, reason: decision.reason, data:
      %Policy.Decision{}}}` (`reason: :no_rule` when nothing matched and
      there is no approver).
   7. **Ask**: an `:ask` decision is settled by a live grant
      (`ConduitMcp.Client.Grants`) or by the `:on_ask` approver.
   8. **Encode**: the arguments' digest must still be the one policy and
      the approver saw (otherwise `{:error, %Error{kind: :hook, reason:
      :args_changed}}`); `meta` becomes the request's `_meta`, the
      protocol's reserved keys winning.
   9. **Send**, including the modern multi-round-trip loop: each input
      request goes through capability gating, the sampling/elicitation
      safety checks and the `ConduitMcp.Client.Handler`, in the caller;
      nothing above runs again per round.
  10. **Output-schema validation** (`validate: [structured_content:
      true]`).
  11. **Post-hooks** on a result (including `is_error` results), or
      **failure hooks** on an error from step 3 on.
  12. **Shaping** for a model, with `shape: :llm` (below).
  13. The `[:conduit_mcp, :client, :tool_call, :stop]` event.

  ## Approvals

  `:on_ask` is `fun.(%ToolCall{}, ctx)` or `{Module, :function}`, called
  in a task under `:ask_timeout` (default 60 s) with the exact arguments
  that will be sent and their `args_digest` (PO-11). It must return:

    * `{:allow, :once}` - send this call;
    * `{:allow, :always}` - send it and record a grant (see
      `ConduitMcp.Client.Grants`) for the call's `:principal`, this tool and
      its current fingerprint, for `:grant_ttl` (default 24 h);
    * `{:deny, reason}` - `{:error, %Error{kind: :denied, reason:
      :ask_denied, data: reason}}`;
    * `{:deny, reason, :halt}` - the same with `reason: :ask_halt`, telling
      an agent loop to stop.

  Anything else, a raise, an exit or a timeout is a deny with
  `reason: {:ask_failed, :bad_return | :raise | :exit | :timeout}`. The
  approver cannot change the arguments: rewriting belongs in pre-hooks.

  The fingerprints policy pins to (`ctx.approved_fingerprints`, PO-6) come
  from the client's `:approved_fingerprints` option: `:first_listing`
  (default) records the fingerprints of the first full tool list a client
  with a policy reads (with `ConduitMcp.Client.list_all_tools/2`,
  `ConduitMcp.Client.cached_tools/2`, or its first call), so a later change
  to a tool's definition asks again, and a tool first listed later is new
  (`allow_new_tools`); a map of tool name to fingerprint pins exactly
  those. A live grant for the call's principal adds the granted
  fingerprint. The baseline lives as long as the client's processes; it is
  recorded again after a restart.

  ## Context

  Hooks, the approver, filter functions and policy predicates get `ctx`:
  `:client`, `:server_id` (the call's provenance: the server the call goes
  to), `:era`, `:assigns` (the call's, else the client's), `:principal`
  (the call's `:principal` option, else `nil`), `:taint` (the call's
  `:taint` option as a `MapSet`, see "Taint"), `:has_approver?` and, from
  step 3, `:approved_fingerprints` (the entry for the called tool, when it
  has one).

  ## Taint (HB-3)

  A model that read one server's output may be steered by it into calling
  another server's tool (cross-server exfiltration). The library cannot
  see the model's context, so the host says which servers' output entered
  the current turn with `taint: ["web", "mail"]`, and policy rules decide
  what that means, for example asking before any open-world tool once
  untrusted output is in context:

      ask: [{:all, [{:annotation, :open_world, true}, ConduitMcp.Client.Policy.tainted()]}]

  `ConduitMcp.Client.Policy.tainted/1` matches when the taint set holds a
  server other than the called tool's own (minus an `:ignore` list); any
  function rule can read `ctx.taint` directly.

  ## Shaping for a model (PI-2)

  With `shape: :llm` a `ToolResult` is rewritten for an LLM's context:

    * `provenance: %{server_id:, truncated:, flags:}` says where it came
      from and what was changed;
    * text (including embedded resource text, link names and
      `structuredContent` strings) loses invisible and direction-changing
      characters (bidi controls, zero-width characters, Unicode tag
      characters), flagged `:bidi`, `:zero_width`, `:tag_chars`;
    * images other than JPEG, PNG, GIF and WebP (notably SVG), audio other
      than WAV, MP3, Ogg, WebM and FLAC, and non-image blobs are replaced by
      a text placeholder (`:media_dropped`); unknown block types too
      (`:unsupported_content`);
    * `resource_link` URIs are kept as text and never fetched, and nothing
      else (icons, embedded URIs) is fetched either;
    * `_meta` (of the result and of each block) and unknown keys are
      dropped;
    * the whole result is capped at the client's `:max_result_bytes_for_llm`
      (default 100 KiB): the block that crosses it is cut on a character
      boundary, later blocks and an over-size `structuredContent` are
      dropped, and a final text block says so
      (`"[truncated by the MCP client: ...]"`).

  Server `instructions` are not part of a tool result; see
  `ConduitMcp.Client.instructions_for_llm/1`.

  ## Telemetry

  `[:conduit_mcp, :client, :policy, :decision]` per policy evaluation and
  `[:conduit_mcp, :client, :hook, :stop | :exception]` per hook run (see
  `ConduitMcp.Telemetry`); neither carries arguments or results. With the
  client's `telemetry: [capture_payloads: ...]`, the `tool_call` span's
  `:arguments` are the arguments given to `run/3` (the span opens before
  the pre-hooks, and a denied call sends nothing) and its `:result` is
  what `run/3` returns (after post-hooks and shaping).
  """

  alias ConduitMcp.Client
  alias ConduitMcp.Client.Cache
  alias ConduitMcp.Client.Canonical
  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Governance
  alias ConduitMcp.Client.Governance.Exec
  alias ConduitMcp.Client.Grants
  alias ConduitMcp.Client.Hooks
  alias ConduitMcp.Client.Pattern
  alias ConduitMcp.Client.Pipeline.Shaping
  alias ConduitMcp.Client.Policy
  alias ConduitMcp.Client.Task, as: ClientTask
  alias ConduitMcp.Client.Telemetry
  alias ConduitMcp.Client.Tool
  alias ConduitMcp.Client.ToolCall
  alias ConduitMcp.Client.ToolFilter
  alias ConduitMcp.Client.ToolResult

  @own_options [:principal, :shape, :tool, :task, :task_ttl, :taint]

  @doc """
  Runs a governed tool call on `client`.

  `target` is `{name, args}` (the server's tool name and the arguments) or
  a `ConduitMcp.Client.ToolCall` for this client's `server_id` (its `meta`
  and `call_id` are kept).

  ## Options

  Every `ConduitMcp.Client.call_tool/4` option (`:task`, `:task_ttl`,
  `:timeout`, `:meta`, `:assigns`, progress options), plus:

    * `:principal` - who the call is made for: passed in `ctx`, and the key
      grants are recorded and looked up under (default `nil`).
    * `:shape` - `:llm` to shape the result for a model (see the
      moduledoc).
    * `:taint` - the server ids (strings) whose output entered the current
      turn, as a list or `MapSet` (default none); see "Taint".
    * `:tool` - an already resolved `ConduitMcp.Client.Tool` for the same
      `{server_id, name}`, skipping the cache lookup.

  Returns what `call_tool/4` returns.
  """
  @spec run(Client.client(), ToolCall.t() | {String.t(), map()}, keyword()) ::
          {:ok, ToolResult.t() | ClientTask.t()} | {:error, Error.t()}
  def run(client, target, opts \\ []) do
    {own, opts} = Keyword.split(opts, @own_options)
    {meta, opts} = Keyword.pop(opts, :meta)
    mode = own[:task]

    unless mode in [nil, :return, :await] do
      raise ArgumentError, ":task must be :return or :await, got: #{inspect(mode)}"
    end

    unless own[:shape] in [nil, :llm] do
      raise ArgumentError, ":shape must be :llm, got: #{inspect(own[:shape])}"
    end

    with {:ok, view} <- Client.__view__(client, mode, opts),
         {:ok, gov} <- Governance.lookup(client) do
      call = initial_call(view.server_id, target, meta)
      base = Telemetry.base(client, view.server_id, view.transport, view.era)

      Telemetry.tool_call_span(base, call.name, call.args, view.capture_payloads, fn ->
        execute(state(client, view, gov, call, base, own, opts))
      end)
    end
  end

  defp initial_call(server_id, {name, args}, meta) when is_binary(name) and is_map(args),
    do: ToolCall.new(server_id, name, args, meta: meta || %{})

  defp initial_call(server_id, %ToolCall{server_id: server_id} = call, meta),
    do: %{call | meta: Map.merge(call.meta, meta || %{})}

  defp initial_call(server_id, %ToolCall{server_id: other}, _meta) do
    raise ArgumentError,
          "the call targets server #{inspect(other)} but the client's server_id is " <>
            inspect(server_id)
  end

  defp state(client, view, gov, call, base, own, opts) do
    settings = gov.settings

    ctx = %{
      client: client,
      server_id: view.server_id,
      era: view.era,
      assigns: Keyword.get(opts, :assigns) || view.input.assigns,
      principal: own[:principal],
      taint: taint!(own[:taint]),
      has_approver?: settings.on_ask != nil
    }

    %{
      client: client,
      view: view,
      gov: gov,
      settings: settings,
      call: call,
      tool: own[:tool],
      ctx: ctx,
      mode: {own[:task], own[:task_ttl]},
      shape: own[:shape],
      opts: opts,
      subject: nil,
      listed: nil,
      digest: nil,
      env: %{
        task_sup: view.task_sup,
        hook_timeout: settings.hook_timeout,
        telemetry: Map.put(base, :tool_name, Telemetry.tool_name(call.name))
      }
    }
  end

  defp taint!(nil), do: MapSet.new()
  defp taint!(%MapSet{} = taint), do: taint!(MapSet.to_list(taint))

  defp taint!(ids) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1),
      do: MapSet.new(ids),
      else: raise(ArgumentError, ":taint must list server ids (strings), got: #{inspect(ids)}")
  end

  defp taint!(other),
    do: raise(ArgumentError, ":taint must be a list of server ids, got: #{inspect(other)}")

  # --- steps -----------------------------------------------------------------------

  defp execute(s) do
    with {:ok, tool, listed} <- resolve(s),
         s = %{s | tool: tool, listed: listed, subject: subject(tool, s.ctx)},
         :ok <- select(s) do
      {outcome, rounds} = governed(s)
      {finish(s, outcome), rounds}
    else
      {:error, _} = error -> {error, 0}
    end
  end

  # 1. Resolve. `listed` is the full list when one was fetched here: a
  # private list fetched with an unshared credential is not cached (HT-11),
  # so the tool and the baseline come from it, not from the cache.
  defp resolve(%{tool: %Tool{server_id: server_id, name: name} = tool, call: call})
       when server_id == call.server_id and name == call.name,
       do: {:ok, tool, nil}

  defp resolve(%{tool: %Tool{} = tool, call: call}) do
    raise ArgumentError,
          "the :tool option is #{inspect({tool.server_id, tool.name})} " <>
            "but the call targets #{inspect({call.server_id, call.name})}"
  end

  defp resolve(%{view: view, call: call} = s) do
    case Cache.lookup(view.cache, :tools, call.name) do
      {:ok, tool} ->
        {:ok, tool, nil}

      :miss ->
        # Never listed, listed before a `list_changed`, or not cached for
        # this credential: list once more.
        if relist?(view.cache) do
          with {:ok, tools} <- Client.__list_all__(s.client, :tools, list_opts(s.opts)) do
            case Enum.find(tools, &(&1.name == call.name)) do
              %Tool{} = tool -> {:ok, tool, tools}
              nil -> unknown()
            end
          end
        else
          unknown()
        end

      {:error, _} = error ->
        error
    end
  end

  defp relist?(cache) do
    case Cache.list(cache, :tools) do
      :miss -> true
      {:ok, entry} -> entry.stale?
      {:error, _} -> false
    end
  end

  defp list_opts(opts), do: Keyword.take(opts, [:timeout])

  defp unknown, do: {:error, Error.new(:not_found, :unknown_tool)}

  # 2. Select.
  defp select(%{settings: %{filter: nil}}), do: :ok

  defp select(%{settings: %{filter: filter}, tool: tool, ctx: ctx}) do
    if ToolFilter.visible?(filter, tool, ctx), do: :ok, else: unknown()
  end

  defp governed(s) do
    with {:ok, s} <- fingerprints(s),
         {:ok, s} <- pre_hooks(s),
         :ok <- validate_arguments(s),
         {:ok, s} <- authorize(%{s | digest: s.call.args_digest}),
         {:ok, params} <- encode(s) do
      send_call(s, params)
    else
      {:halt, result} -> {{:halted, result}, 0}
      {:error, _} = error -> {error, 0}
    end
  end

  # 3. Fingerprint: the approved baseline plus the principal's grant.
  defp fingerprints(%{settings: %{policy: nil}} = s), do: {:ok, s}

  defp fingerprints(%{gov: gov, tool: tool, ctx: ctx} = s) do
    # The first governed call before any full listing records the baseline
    # (the list was just fetched by `resolve/1`).
    if Governance.needs_baseline?(gov) do
      case s.listed || cached_list(s.view.cache) do
        nil -> :ok
        tools -> Governance.record_baseline(gov, tools)
      end
    end

    fingerprint = Governance.fingerprint(tool)
    key = {tool.server_id, tool.name}
    approved = Governance.approved(gov, key)

    approved =
      if Grants.granted?(gov, grant_key(s, fingerprint), Governance.now(gov.settings)),
        do: Map.put(approved, key, fingerprint),
        else: approved

    {:ok, %{s | ctx: Map.put(ctx, :approved_fingerprints, approved)}}
  end

  defp grant_key(%{ctx: ctx, tool: tool}, fingerprint),
    do: {ctx.principal, tool.server_id, tool.name, fingerprint}

  defp cached_list(cache) do
    case Cache.list(cache, :tools) do
      {:ok, entry} -> entry.items
      _none -> nil
    end
  end

  # 4. Pre-hooks.
  defp pre_hooks(s) do
    case Hooks.run_pre(s.settings.hooks, s.call, s.subject, s.ctx, s.env) do
      {:ok, call} -> {:ok, %{s | call: call}}
      other -> other
    end
  end

  # 5. Input-schema validation.
  defp validate_arguments(%{settings: %{validate: %{arguments: true}}} = s),
    do: validate_schema(s, :input, json(s.call.args), :invalid_arguments)

  defp validate_arguments(_s), do: :ok

  defp validate_schema(s, direction, data, invalid) do
    case Governance.schema(s.gov, s.tool, direction) do
      {:ok, :none} ->
        :ok

      {:ok, built} ->
        case run_validator(s.settings.validate.validator, built, data) do
          :ok -> :ok
          {:error, errors} -> {:error, Error.new(:protocol, invalid, errors)}
        end

      {:error, reason} ->
        {:error, Error.new(:protocol, {:unsafe_schema, direction, reason})}
    end
  end

  defp run_validator(validator, built, data) do
    case validator.validate(built, data) do
      :ok -> :ok
      {:error, errors} -> {:error, errors}
      _other -> {:error, :validator_failed}
    end
  rescue
    _error -> {:error, :validator_failed}
  end

  # The arguments as they go on the wire (string keys, JSON values).
  defp json(term), do: term |> JSON.encode!() |> JSON.decode!()

  # 6 and 7. Policy, then the approver.
  defp authorize(s) do
    case policy(s.settings) do
      nil ->
        {:ok, s}

      :missing ->
        decision(s, no_policy(), nil)
        {:error, Error.new(:denied, :no_policy)}

      %Policy{} = policy ->
        decision = Policy.evaluate(trust(policy, s), s.call, s.tool, s.ctx)

        case decision.decision do
          :allow ->
            decision(s, decision, nil)
            {:ok, s}

          :deny ->
            decision(s, decision, nil)
            {:error, Error.new(:denied, decision.reason, decision)}

          :ask ->
            ask(s, decision)
        end
    end
  end

  defp policy(%{policy: nil}), do: nil

  defp policy(%{policy: {:named, name}}) do
    case Policy.get(name) do
      nil -> :missing
      policy -> policy
    end
  end

  defp policy(%{policy: %Policy{} = policy}), do: policy

  defp trust(policy, %{settings: %{trusted: true}, tool: tool}) do
    case policy.trusted do
      true -> policy
      ids -> %{policy | trusted: MapSet.put(ids, tool.server_id)}
    end
  end

  defp trust(policy, _s), do: policy

  defp ask(s, decision) do
    now = Governance.now(s.settings)
    key = grant_key(s, Governance.fingerprint(s.tool))

    cond do
      Grants.granted?(s.gov, key, now) ->
        decision(s, decision, :grant)
        {:ok, s}

      s.settings.on_ask == nil ->
        decision(s, decision, :failed)
        {:error, Error.new(:denied, :no_approver, decision)}

      true ->
        metadata = Telemetry.logger_metadata(s.env.telemetry)

        case Exec.run(
               s.view.task_sup,
               s.settings.on_ask,
               [s.call, s.ctx],
               s.settings.ask_timeout,
               metadata
             ) do
          {:ok, {:allow, :once}} ->
            decision(s, decision, :once)
            {:ok, s}

          {:ok, {:allow, :always}} ->
            Grants.put(s.gov, key, now)
            decision(s, decision, :always)
            {:ok, s}

          {:ok, {:deny, reason}} ->
            decision(s, decision, :denied)
            {:error, Error.new(:denied, :ask_denied, reason)}

          {:ok, {:deny, reason, :halt}} ->
            decision(s, decision, :halted)
            {:error, Error.new(:denied, :ask_halt, reason)}

          {:ok, _other} ->
            decision(s, decision, :failed)
            {:error, Error.new(:denied, {:ask_failed, :bad_return})}

          {:failed, kind} ->
            decision(s, decision, :failed)
            {:error, Error.new(:denied, {:ask_failed, kind})}
        end
    end
  end

  defp decision(s, decision, approval) do
    extra = %{target: :tool, tool_name: s.env.telemetry.tool_name}

    extra =
      if s.ctx.principal == nil, do: extra, else: Map.put(extra, :principal, s.ctx.principal)

    Telemetry.policy_decision(Map.delete(s.env.telemetry, :tool_name), decision, approval, extra)
  end

  # 8. Encode: what policy and the approver saw is what is sent.
  defp encode(%{call: call, digest: digest}) do
    if Canonical.sha256(call.args) == digest and call.args_digest == digest do
      params = %{"name" => call.name, "arguments" => call.args}
      params = if call.meta == %{}, do: params, else: Map.put(params, "_meta", call.meta)
      {:ok, params}
    else
      {:error, Error.new(:hook, :args_changed)}
    end
  end

  # 9 and 10. Send (with the MRTR loop), then output-schema validation.
  defp send_call(s, params) do
    {result, rounds} = Client.__send_tool_call__(s.client, s.view, params, s.mode, s.opts, s.tool)

    case result do
      {:ok, %ToolResult{is_error: false} = result} -> {validate_output(s, result), rounds}
      other -> {other, rounds}
    end
  end

  defp validate_output(%{settings: %{validate: %{structured_content: true}}} = s, result) do
    data = if result.structured == nil, do: nil, else: json(result.structured)

    with :ok <- validate_schema(s, :output, data, :invalid_structured_content),
         do: {:ok, result}
  end

  defp validate_output(_s, result), do: {:ok, result}

  # 11 and 12. Post-hooks or failure hooks, then shaping.
  defp finish(s, {:ok, %ToolResult{} = result}), do: post(s, result)
  defp finish(s, {:halted, %ToolResult{} = result}), do: post(s, result)
  defp finish(_s, {:ok, _task} = ok), do: ok

  defp finish(s, {:error, %Error{} = error}) do
    case Hooks.run_failed(s.settings.hooks, s.call, error, s.subject, s.ctx, s.env) do
      {:ok, result} -> {:ok, shape(s, result)}
      {:error, _} = error -> error
    end
  end

  defp post(s, result) do
    {:ok, result} = Hooks.run_post(s.settings.hooks, s.call, result, s.subject, s.ctx, s.env)
    {:ok, shape(s, result)}
  end

  defp shape(%{shape: :llm} = s, result),
    do: Shaping.shape(result, s.view.server_id, s.settings.max_result_bytes_for_llm)

  defp shape(_s, result), do: result

  defp subject(%Tool{} = tool, ctx),
    do: Pattern.subject(:tool, tool.server_id, tool.name, ctx, tool: tool)

  # --- listings, resources, prompts ------------------------------------------------------

  @doc false
  # The tools a governed client shows: visible under the filter, with a
  # usable schema when validation is on, after the `:on_tools_listed` hooks.
  # `full?` marks a complete listing, which may record the approval baseline.
  @spec present_tools(Client.client(), map(), [Tool.t()], keyword(), boolean()) ::
          {:ok, [Tool.t()]} | {:error, Error.t()}
  def present_tools(client, view, tools, opts, full?) do
    with {:ok, gov} <- Governance.lookup(client) do
      settings = gov.settings

      if settings.enabled? do
        if full? and settings.policy != nil, do: Governance.record_baseline(gov, tools)

        ctx = list_ctx(client, view, settings, opts)
        tools = Enum.filter(tools, &(visible?(settings, &1, ctx) and schemas_ok?(gov, &1)))
        base = Telemetry.base(client, view.server_id, view.transport, view.era)
        env = %{task_sup: view.task_sup, hook_timeout: settings.hook_timeout, telemetry: base}

        Hooks.run_tools_listed(settings.hooks, tools, &subject(&1, ctx), ctx, env)
      else
        {:ok, tools}
      end
    end
  end

  @doc false
  # Whether one cached tool may be shown (`ConduitMcp.Client.tool/3`).
  @spec present_tool?(Client.client(), map(), Tool.t(), keyword()) :: boolean()
  def present_tool?(client, view, tool, opts) do
    case Governance.lookup(client) do
      {:ok, %{settings: %{enabled?: true} = settings} = gov} ->
        visible?(settings, tool, list_ctx(client, view, settings, opts)) and
          schemas_ok?(gov, tool)

      _plain ->
        true
    end
  end

  defp visible?(%{filter: nil}, _tool, _ctx), do: true
  defp visible?(%{filter: filter}, tool, ctx), do: ToolFilter.visible?(filter, tool, ctx)

  defp schemas_ok?(%{settings: %{validate: nil}}, _tool), do: true

  defp schemas_ok?(%{settings: %{validate: validate}} = gov, tool) do
    (not validate.arguments or match?({:ok, _}, Governance.schema(gov, tool, :input))) and
      (not validate.structured_content or match?({:ok, _}, Governance.schema(gov, tool, :output)))
  end

  defp list_ctx(client, view, settings, opts) do
    %{
      client: client,
      server_id: view.server_id,
      era: view.era,
      assigns: Keyword.get(opts, :assigns) || view.input.assigns,
      principal: Keyword.get(opts, :principal),
      has_approver?: settings.on_ask != nil
    }
  end

  @doc false
  # Gates `resources/read` on a governed client: `:on_resource_read` hooks,
  # then the policy's resource rules (when `:resources` is in its scope).
  # There is no approver for reads, so an ask rule denies.
  @spec authorize_resource(Client.client(), map(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def authorize_resource(client, view, uri, opts) do
    with {:ok, gov} <- Governance.lookup(client) do
      settings = gov.settings

      if settings.enabled? do
        ctx = %{list_ctx(client, view, settings, opts) | has_approver?: false}
        base = Telemetry.base(client, view.server_id, view.transport, view.era)
        env = %{task_sup: view.task_sup, hook_timeout: settings.hook_timeout, telemetry: base}
        subject = Pattern.subject(:resource, view.server_id, uri, ctx)

        with :ok <- Hooks.run_resource_read(settings.hooks, uri, subject, ctx, env) do
          target_policy(settings, base, :resource, ctx, fn policy ->
            Policy.evaluate_resource(policy, view.server_id, uri, ctx)
          end)
        end
      else
        :ok
      end
    end
  end

  @doc false
  # Gates `prompts/get` like `authorize_resource/4`; hooks may rewrite the
  # arguments.
  @spec authorize_prompt(Client.client(), map(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def authorize_prompt(client, view, name, args, opts) do
    with {:ok, gov} <- Governance.lookup(client) do
      settings = gov.settings

      if settings.enabled? do
        ctx = %{list_ctx(client, view, settings, opts) | has_approver?: false}
        base = Telemetry.base(client, view.server_id, view.transport, view.era)
        env = %{task_sup: view.task_sup, hook_timeout: settings.hook_timeout, telemetry: base}
        subject = Pattern.subject(:prompt, view.server_id, name, ctx)

        with {:ok, args} <- Hooks.run_prompt_get(settings.hooks, name, args, subject, ctx, env),
             :ok <-
               target_policy(settings, base, :prompt, ctx, fn policy ->
                 Policy.evaluate_prompt(policy, view.server_id, name, ctx)
               end),
             do: {:ok, args}
      else
        {:ok, args}
      end
    end
  end

  defp target_policy(settings, base, target, ctx, evaluate) do
    extra =
      if ctx.principal == nil,
        do: %{target: target},
        else: %{target: target, principal: ctx.principal}

    case policy(settings) do
      nil ->
        :ok

      :missing ->
        Telemetry.policy_decision(base, no_policy(), nil, extra)

        {:error, Error.new(:denied, :no_policy)}

      policy ->
        decision = evaluate.(policy)
        Telemetry.policy_decision(base, decision, nil, extra)

        if decision.decision == :allow,
          do: :ok,
          else: {:error, Error.new(:denied, decision.reason, decision)}
    end
  end

  defp no_policy, do: %{decision: :deny, source: :default, rule_id: nil, reason: :no_policy}
end
