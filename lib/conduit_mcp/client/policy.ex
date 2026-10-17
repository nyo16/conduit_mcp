defmodule ConduitMcp.Client.Policy do
  @moduledoc """
  Authorization for tool calls (and, opt-in, resource reads and prompt
  gets): decides `:allow`, `:ask` or `:deny` for one call.

  Evaluation is pure: no I/O, no processes, no telemetry. It runs in the
  caller, on the final arguments (after pre-hooks), and returns a
  `ConduitMcp.Client.Policy.Decision` carrying the matching rule's id and a
  closed `reason` atom for the pipeline's telemetry.

      policy =
        ConduitMcp.Client.Policy.compile(
          deny: ["*/delete_*", "shell/*"],
          ask: ["github/create_*", {"fs", ~r/^write/}],
          allow: ["github/get_*", {:all, ["fs/*", {:annotation, :read_only, true}]}],
          trusted: ["fs"]
        )

      ConduitMcp.Client.Policy.evaluate(policy, call, tool, %{has_approver?: true})

  ## Precedence (PO-1)

  Fixed and not configurable: **deny > pin > ask > allow > default**. List
  order and rule specificity never change the outcome; a narrow allow cannot
  carve an exception out of a broad deny. Within one list, list order only
  picks which `rule_id` is reported.

  ## Rules

  Every rule matches the structured target `{server_id, name}`, one segment
  at a time, never a namespaced string (PO-3), so server `a_b` + tool `c`
  and server `a` + tool `b_c` are never confused.

    * `"server/tool"` - `*` globs within one segment; a bare `"tool"` means
      any server.
    * `{server, %Regex{}}` - the regex is matched against the tool name;
      `server` is a segment glob.
    * `fn %ConduitMcp.Client.Tool{}, ctx -> boolean end`.
    * `{:annotation, :read_only | :destructive | :open_world | :idempotent, boolean}`
      - compares the tool's effective annotation (see "Annotations").
    * `{:args, fun}` - `fun.(args)` or `fun.(args, ctx)` on the call's final
      arguments; `ConduitMcp.Client.Policy.Paths` builds path predicates.
    * `{:all, [rule, ...]}` - matches when every member matches, for example
      `{:all, ["fs/write", {:args, Paths.inside("path", "/data")}]}`.
    * `{:rule, id, rule}` - any rule above with an explicit `rule_id` (an
      atom or a string); otherwise the id is `{list, index}`.

  Function rules get the pipeline `ctx`, including `ctx.server_id` (where
  the call goes) and `ctx.taint` (the servers whose output is in the
  model's context, HB-3); `tainted/1` builds the common taint rule.

  With `:resources` / `:prompts` in `:scope`, these also apply:

    * `"resource:server/uri"` (glob on the URI; `*` may span `/`),
      `{:resource, server, %Regex{}}`
    * `"prompt:server/name"`, `{:prompt, server, %Regex{}}`

  Tool rules never match resources or prompts and vice versa. Server ids
  never contain `:`, so a server segment with `:` is rejected (this catches
  `"resource:repo://x"`, which needs a server: `"resource:*/repo://x"`).

  ### Asymmetric matching (PO-5)

  Deny and ask rules match **loosely**: both segments are compared Unicode
  lower-cased with `-`, `.` and `_` equivalent, and a regex is tried against
  both the name and that folded form. So `deny: ["*/delete_repo"]` also
  denies `Delete_Repo`, `delete-repo` and `DELETE.REPO`. Allow rules match
  **exactly** and case-sensitively: `allow: ["*/delete_repo"]` does not
  allow `Delete_Repo`.

  ### Failing predicates

  Function, argument and annotation predicates run in the caller. A
  predicate that raises, exits, throws or returns a non-boolean counts as
  **matching** in deny and ask lists (`reason: :predicate_failed`) and as
  **not matching** in the allow list: failures never widen access.

  ## Annotations (PO-8)

  Tool annotations are untrusted unless the server is listed in `:trusted`.
  For an untrusted server every annotation rule sees the conservative value
  regardless of the hints: not read-only, destructive, open-world,
  non-idempotent. For a trusted server the boolean hint is used, with the
  spec defaults when absent, and a read-only tool is not destructive.

  ## Pinning and new tools (PO-6)

  The pipeline passes the approved baseline in
  `ctx[:approved_fingerprints]`: a map `{server_id, tool_name} =>
  fingerprint` (`ConduitMcp.Client.Fingerprint`). A missing key is treated
  as an empty map (every tool is new), which fails closed.

    * `pin_tools: true` (default) - a tool whose current fingerprint
      (`tool.fingerprint`, or computed from `tool.raw` when `nil`) differs
      from its approved one is decided by the pin, right after deny rules:
      `:ask` (or `:deny` without an approver), `source: :pin`,
      `reason: :definition_changed`.
    * `allow_new_tools: false` (default) - a tool with no approved
      fingerprint is matched only by **exact** allow rules: a string rule
      whose server and tool segments are both literal (`"fs/read"`), or an
      `:all` containing one. Globs, bare names, regexes, functions and
      annotation or argument predicates do not allow it; it falls through to
      the default. Deny and ask rules apply to new tools as usual.

  ## Default and approvers (PO-2)

  `ctx[:has_approver?]` (default `false`) tells evaluation whether an
  approver (`on_ask`) will run. Without one, evaluation never returns
  `:ask`: an ask rule becomes `:deny` with `reason: :no_approver`, the pin
  and an `:ask` default become `:deny` with their own reasons. The no-match
  default is `default: :ask` (the default; `:deny` without an approver) or
  `default: :deny`.

  ## Runtime updates

  `update/2` stores a compiled policy in `:persistent_term` under
  `{ConduitMcp.Client.Policy, name}`, and `get/1` reads it in the caller.
  There is no server process. `:persistent_term` updates are global and
  trigger a scan of every process's heap, so update rarely (operator
  changes, "always allow" persistence), not per call.
  """

  alias ConduitMcp.Client.{Fingerprint, Pattern, Tool, ToolCall}
  alias ConduitMcp.Client.Policy.Decision

  defstruct deny: [],
            ask: [],
            allow: [],
            default: :ask,
            scope: [:tools],
            pin_tools: true,
            allow_new_tools: false,
            trusted: MapSet.new()

  @typep matcher :: Pattern.matcher()

  @typedoc "A compiled rule: its id, matcher, and whether it names one exact target."
  @type rule :: {term(), matcher(), boolean()}

  @type scope :: :tools | :resources | :prompts

  @typedoc "A compiled policy. Treat as opaque apart from reading options."
  @type t :: %__MODULE__{
          deny: [rule()],
          ask: [rule()],
          allow: [rule()],
          default: :ask | :deny,
          scope: [scope()],
          pin_tools: boolean(),
          allow_new_tools: boolean(),
          trusted: true | MapSet.t(String.t())
        }

  @options [:deny, :ask, :allow, :default, :scope, :pin_tools, :allow_new_tools, :trusted]
  @scopes [:tools, :resources, :prompts]
  @allowed [:name, :regex, :fun, :annotation, :args, :all, :resource, :prompt]

  @doc """
  Compiles a policy. Raises `ArgumentError` naming the option or entry on
  any invalid input.

  ## Options

    * `:deny`, `:ask`, `:allow` - rule lists (default `[]`); see the moduledoc.
    * `:default` - `:ask` (default) or `:deny`, for calls no rule matches.
    * `:scope` - a non-empty subset of `[:tools, :resources, :prompts]`
      (default `[:tools]`). Resource and prompt rules require their scope.
    * `:pin_tools` - default `true`.
    * `:allow_new_tools` - default `false`.
    * `:trusted` - servers whose annotations are trusted: `false` (default),
      `true` (every server), a list or `MapSet` of server ids, or a map of
      server id to boolean.

  A compiled policy is returned unchanged.
  """
  @spec compile(keyword() | t()) :: t()
  def compile(%__MODULE__{} = policy), do: policy

  def compile(opts) when is_list(opts) do
    Enum.each(opts, fn
      {key, _value} when key in @options -> :ok
      other -> raise ArgumentError, "unknown policy option #{inspect(other)}"
    end)

    scope = scope!(Keyword.get(opts, :scope, [:tools]))

    %__MODULE__{
      deny: rules!(opts, :deny, true, scope),
      ask: rules!(opts, :ask, true, scope),
      allow: rules!(opts, :allow, false, scope),
      default: one_of!(opts, :default, [:ask, :deny], :ask),
      scope: scope,
      pin_tools: one_of!(opts, :pin_tools, [true, false], true),
      allow_new_tools: one_of!(opts, :allow_new_tools, [true, false], false),
      trusted: trusted!(Keyword.get(opts, :trusted, false))
    }
  end

  defp scope!([_ | _] = scope) do
    if Enum.all?(scope, &(&1 in @scopes)),
      do: Enum.uniq(scope),
      else:
        raise(
          ArgumentError,
          "policy :scope must be a subset of #{inspect(@scopes)}, got: #{inspect(scope)}"
        )
  end

  defp scope!(other),
    do: raise(ArgumentError, "policy :scope must be a non-empty list, got: #{inspect(other)}")

  defp one_of!(opts, key, allowed, default) do
    value = Keyword.get(opts, key, default)

    if value in allowed,
      do: value,
      else:
        raise(
          ArgumentError,
          "policy #{inspect(key)} must be one of #{inspect(allowed)}, got: #{inspect(value)}"
        )
  end

  defp trusted!(true), do: true
  defp trusted!(false), do: MapSet.new()
  defp trusted!(%MapSet{} = ids), do: trusted!(MapSet.to_list(ids))

  defp trusted!(ids) when is_list(ids) do
    if Enum.all?(ids, &is_binary/1),
      do: MapSet.new(ids),
      else:
        raise(
          ArgumentError,
          "policy :trusted must list server ids (strings), got: #{inspect(ids)}"
        )
  end

  defp trusted!(ids) when is_map(ids) do
    ids
    |> Enum.map(fn
      {id, trusted?} when is_binary(id) and is_boolean(trusted?) -> {id, trusted?}
      entry -> raise ArgumentError, "invalid policy :trusted entry #{inspect(entry)}"
    end)
    |> Enum.filter(&elem(&1, 1))
    |> MapSet.new(&elem(&1, 0))
  end

  defp trusted!(other),
    do: raise(ArgumentError, "invalid policy :trusted value #{inspect(other)}")

  defp rules!(opts, list, loose?, scope) do
    case Keyword.get(opts, list, []) do
      entries when is_list(entries) ->
        entries
        |> Enum.with_index()
        |> Enum.map(fn {entry, index} -> rule!(entry, {list, index}, list, loose?, scope) end)

      other ->
        raise ArgumentError, "policy #{inspect(list)} must be a list, got: #{inspect(other)}"
    end
  end

  defp rule!({:rule, id, entry}, _default_id, list, loose?, scope)
       when is_atom(id) or is_binary(id),
       do: rule!(entry, id, list, loose?, scope)

  defp rule!(entry, id, list, loose?, scope) do
    matcher = Pattern.compile(entry, loose?, "policy #{inspect(list)}", @allowed)
    needed = scope_of(Pattern.kind(matcher))

    unless needed in scope do
      raise ArgumentError,
            "invalid policy #{inspect(list)} entry #{inspect(entry)}: " <>
              "it needs #{inspect(needed)} in :scope"
    end

    {id, matcher, Pattern.exact?(matcher)}
  end

  defp scope_of(:tool), do: :tools
  defp scope_of(:resource), do: :resources
  defp scope_of(:prompt), do: :prompts

  @doc """
  Decides a tool call. `call` and `tool` must name the same
  `{server_id, name}` (`ArgumentError` otherwise).

  `ctx` is the pipeline context; evaluation reads:

    * `:has_approver?` - whether an approver will run (default `false`);
    * `:approved_fingerprints` - `%{{server_id, tool_name} => fingerprint}`
      (default `%{}`);

  and passes the whole `ctx` to function and `{:args, fun/2}` predicates.
  Returns an `:allow` decision with `reason: :out_of_scope` when `:tools` is
  not in the policy's scope.
  """
  @spec evaluate(t(), ToolCall.t(), Tool.t(), map()) :: Decision.t()
  def evaluate(%__MODULE__{} = policy, %ToolCall{} = call, %Tool{} = tool, ctx)
      when is_map(ctx) do
    %ToolCall{server_id: server_id, name: name, args: args} = call

    unless tool.server_id == server_id and tool.name == name do
      raise ArgumentError,
            "the call targets #{inspect({server_id, name})} " <>
              "but the tool is #{inspect({tool.server_id, tool.name})}"
    end

    if :tools in policy.scope do
      subject =
        Pattern.subject(:tool, server_id, name, ctx,
          tool: tool,
          args: args,
          trusted?: trusted?(policy, server_id)
        )

      approved = approved_fingerprint(ctx, {server_id, name})

      with :continue <- deny(policy, subject),
           :continue <- pin(policy, tool, approved, ctx),
           :continue <- ask(policy, subject, ctx),
           :continue <- allow(policy, subject, approved == :new) do
        default(policy, ctx)
      end
    else
      out_of_scope()
    end
  end

  @doc """
  Decides a `resources/read` of `uri` on `server_id`, when `:resources` is
  in the policy's scope (otherwise `:allow` with `reason: :out_of_scope`).
  Only resource rules apply; there is no pinning. Reads
  `ctx[:has_approver?]` like `evaluate/4`.
  """
  @spec evaluate_resource(t(), String.t(), String.t(), map()) :: Decision.t()
  def evaluate_resource(%__MODULE__{} = policy, server_id, uri, ctx)
      when is_binary(server_id) and is_binary(uri) and is_map(ctx),
      do: evaluate_target(policy, :resources, :resource, server_id, uri, ctx)

  @doc """
  Decides a `prompts/get` of prompt `name` on `server_id`, when `:prompts` is
  in the policy's scope (otherwise `:allow` with `reason: :out_of_scope`).
  Only prompt rules apply; there is no pinning. Reads `ctx[:has_approver?]`
  like `evaluate/4`.
  """
  @spec evaluate_prompt(t(), String.t(), String.t(), map()) :: Decision.t()
  def evaluate_prompt(%__MODULE__{} = policy, server_id, name, ctx)
      when is_binary(server_id) and is_binary(name) and is_map(ctx),
      do: evaluate_target(policy, :prompts, :prompt, server_id, name, ctx)

  defp evaluate_target(policy, scope, kind, server_id, name, ctx) do
    if scope in policy.scope do
      subject = Pattern.subject(kind, server_id, name, ctx)

      with :continue <- deny(policy, subject),
           :continue <- ask(policy, subject, ctx),
           :continue <- allow(policy, subject, false) do
        default(policy, ctx)
      end
    else
      out_of_scope()
    end
  end

  defp deny(policy, subject) do
    case first_match(policy.deny, subject, true) do
      {id, true} -> decision(:deny, :deny, :deny_rule, id)
      {id, :error} -> decision(:deny, :deny, :predicate_failed, id)
      nil -> :continue
    end
  end

  defp pin(%__MODULE__{pin_tools: true}, tool, {:approved, fingerprint}, ctx) do
    if current_fingerprint(tool) == fingerprint,
      do: :continue,
      else: ask_or_deny(:pin, :definition_changed, :definition_changed, nil, ctx)
  end

  defp pin(_policy, _tool, _approved, _ctx), do: :continue

  defp ask(policy, subject, ctx) do
    case first_match(policy.ask, subject, true) do
      {id, true} -> ask_or_deny(:ask, :ask_rule, :no_approver, id, ctx)
      {id, :error} -> ask_or_deny(:ask, :predicate_failed, :no_approver, id, ctx)
      nil -> :continue
    end
  end

  defp allow(policy, subject, new?) do
    rules =
      if new? and not policy.allow_new_tools,
        do: Enum.filter(policy.allow, fn {_id, _matcher, exact?} -> exact? end),
        else: policy.allow

    case Enum.find(rules, fn {_id, matcher, _exact?} ->
           Pattern.match(matcher, subject, false) == true
         end) do
      {id, _matcher, _exact?} -> decision(:allow, :allow, :allow_rule, id)
      nil -> :continue
    end
  end

  defp default(%__MODULE__{default: :ask}, ctx),
    do: ask_or_deny(:default, :no_rule, :no_rule, nil, ctx)

  defp default(%__MODULE__{default: :deny}, _ctx), do: decision(:deny, :default, :no_rule, nil)

  defp out_of_scope, do: decision(:allow, :default, :out_of_scope, nil)

  defp first_match(rules, subject, loose?) do
    Enum.find_value(rules, fn {id, matcher, _exact?} ->
      case Pattern.match(matcher, subject, loose?) do
        false -> nil
        result -> {id, result}
      end
    end)
  end

  defp ask_or_deny(source, reason, no_approver_reason, id, ctx) do
    if Map.get(ctx, :has_approver?) == true,
      do: decision(:ask, source, reason, id),
      else: decision(:deny, source, no_approver_reason, id)
  end

  defp decision(decision, source, reason, id),
    do: %Decision{decision: decision, source: source, reason: reason, rule_id: id}

  defp trusted?(%__MODULE__{trusted: true}, _server_id), do: true
  defp trusted?(%__MODULE__{trusted: ids}, server_id), do: MapSet.member?(ids, server_id)

  defp approved_fingerprint(ctx, key) do
    case Map.get(ctx, :approved_fingerprints, %{}) do
      approved when is_map(approved) ->
        case Map.fetch(approved, key) do
          {:ok, fingerprint} -> {:approved, fingerprint}
          :error -> :new
        end

      other ->
        raise ArgumentError,
              "ctx[:approved_fingerprints] must be a map, got: #{inspect(other)}"
    end
  end

  defp current_fingerprint(%Tool{fingerprint: fingerprint}) when is_binary(fingerprint),
    do: fingerprint

  defp current_fingerprint(%Tool{} = tool), do: Fingerprint.compute(tool)

  @doc """
  A policy that allows every tool call: `allow: ["*/*"]` with
  `allow_new_tools: true` and `pin_tools: false`. `ConduitMcp.Client.Hub`
  accepts `policy: :allow_all` for it; it is never a default (PO-2).
  """
  @spec allow_all() :: t()
  def allow_all, do: compile(allow: ["*/*"], allow_new_tools: true, pin_tools: false)

  @doc """
  A function rule matching a call made while another server's output is in
  the model's context (HB-3): the call's `:taint` set (`ctx.taint`, see
  `ConduitMcp.Client.Pipeline`) holds a server id other than the called
  tool's own server and not in `:ignore`.

      ask: [{:all, [{:annotation, :open_world, true}, Policy.tainted(ignore: ["docs"])]}],
      deny: [{:all, ["mail/send", Policy.tainted()]}]

  A call without a `:taint` option is never tainted. Use it in deny and ask
  lists; in the allow list it would only widen access for tainted calls.

  ## Options

    * `:ignore` - server ids whose output does not count (default `[]`).
  """
  @spec tainted(keyword()) :: (Tool.t(), map() -> boolean())
  def tainted(opts \\ []) do
    ignore =
      case Keyword.validate!(opts, ignore: [])[:ignore] do
        ids when is_list(ids) ->
          MapSet.new(ids)

        other ->
          raise ArgumentError, ":ignore must be a list of server ids, got: #{inspect(other)}"
      end

    fn %Tool{server_id: target}, ctx ->
      ctx
      |> Map.get(:taint, MapSet.new())
      |> Enum.any?(&(&1 != target and not MapSet.member?(ignore, &1)))
    end
  end

  @doc """
  Compiles `policy` (unless already compiled) and stores it under `name` in
  `:persistent_term`, replacing any previous one. Raises like `compile/1`;
  on a raise the stored policy is unchanged.
  """
  @spec update(term(), keyword() | t()) :: :ok
  def update(name, policy) do
    :persistent_term.put(key(name), compile(policy))
  end

  @doc "The policy stored under `name` by `update/2`, or `nil`."
  @spec get(term()) :: t() | nil
  def get(name), do: :persistent_term.get(key(name), nil)

  @doc "Removes the policy stored under `name`, if any."
  @spec delete(term()) :: :ok
  def delete(name) do
    :persistent_term.erase(key(name))
    :ok
  end

  defp key(name), do: {__MODULE__, name}
end
