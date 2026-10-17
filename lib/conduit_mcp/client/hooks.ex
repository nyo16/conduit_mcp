defmodule ConduitMcp.Client.Hooks do
  @moduledoc """
  Host code that runs around a client's tool calls (and, optionally, its
  tool listings, resource reads and prompt gets), configured with the
  client's `:hooks` option and run by `ConduitMcp.Client.Pipeline`.

      {ConduitMcp.Client,
       name: :fs,
       transport: {...},
       hooks: [
         pre_tool_call: [
           {:all, &MyApp.Audit.before/2, id: :audit},
           {"fs/write_*", {MyApp.Paths, :normalize}, id: :normalize}
         ],
         post_tool_call: [{"fs/*", &MyApp.Redact.result/3, id: :redact}],
         tool_call_failed: [{:all, &MyApp.Alert.failed/3, id: :alert, on_error: :ignore}]
       ]}

  ## Events

  | Event | Called as | Returns |
  |---|---|---|
  | `:pre_tool_call` | `fun.(%ToolCall{}, ctx)` | `:cont`, `{:cont, %ToolCall{}}`, `{:deny, reason}` or `{:halt, %ToolResult{}}` |
  | `:post_tool_call` | `fun.(%ToolCall{}, %ToolResult{}, ctx)` | `:cont` or `{:cont, %ToolResult{}}` |
  | `:tool_call_failed` | `fun.(%ToolCall{}, %Error{}, ctx)` | `:cont` or `{:recover, %ToolResult{}}` |
  | `:on_tools_listed` | `fun.([%Tool{}], ctx)` | `:cont` or `{:cont, [%Tool{}]}` |
  | `:on_resource_read` | `fun.(uri, ctx)` | `:cont` or `{:deny, reason}` |
  | `:on_prompt_get` | `fun.(name, args, ctx)` | `:cont`, `{:cont, args}` or `{:deny, reason}` |

    * A pre-hook may rewrite only the call's `args` and `meta`; the digest
      is recomputed. A returned call with another `server_id`, `name` or
      `call_id` is a bad return. `{:deny, reason}` fails the call with
      `{:error, %Error{kind: :denied, reason: {:hook_denied, hook_id},
      data: reason}}`; `{:halt, result}` answers it with a synthetic result
      and nothing is sent (policy does not run; post-hooks do).
    * Post-hooks also see `is_error: true` results.
    * Failure hooks run instead of post-hooks when the call ends in an error
      (denied, transport, protocol, timeout, a failed hook, ...).
      `{:recover, result}` turns the error into that result and ends the
      chain.
    * `:on_tools_listed` hooks get the listed tools their matcher selects
      and may drop or annotate them; a returned tool must be one of those
      given (same `server_id` and `name`). This shapes what the host and
      its model see; it is not an authorization layer (use the `:tools`
      filter or a policy for that).
    * `:on_resource_read` / `:on_prompt_get` gate `read_resource/3` and
      `get_prompt/4` the way pre-hooks gate calls.

  **No hook can allow anything** (HK-5): there is no allow return, and a
  hook returning one is a bad return. Policy is the only allow authority,
  and it runs after the pre-hooks, on the final arguments.

  `ctx` is a map with `:client`, `:server_id`, `:era`, `:assigns` and
  `:principal` (from the call's options).

  ## Hook specs

  `{matcher, fun}` or `{matcher, fun, opts}`, where `fun` is a function of
  the event's arity or `{Module, :function}` (checked when the options are
  validated) and `matcher` is:

    * `:all` (or `:any`, `"*"`) - every call;
    * `"server/tool"` - `*` globs within one segment; a bare `"tool"` means
      any server (resource hooks glob the URI, prompt hooks the name);
    * `{server, %Regex{}}` - the regex is matched against the tool name
      (URI, prompt name).

  Matchers compare loosely, like `ConduitMcp.Client.Policy` deny rules
  (case-folded, with `-`, `.` and `_` equivalent), so a redaction hook on
  `"fs/read_file"` also covers `Read-File`.

  Options:

    * `:id` - an atom or string naming the hook in errors and telemetry
      (default `{event, index}`); ids must be unique.
    * `:timeout` - milliseconds (default the client's `:hook_timeout`,
      5 000).
    * `:on_error` - `:fail` (default) or `:ignore`, for post-hooks and
      failure hooks only.

  ## Order (HK-4)

  Hooks run one at a time, each `{:cont, value}` feeding the next, in onion
  order: **global** (`:all`), then **server** (`"server/*"`), then **tool**
  (any other matcher) for pre-hooks, tool listing, resource and prompt
  hooks; in declaration order within a level. Post-hooks and failure hooks
  run in the reverse order.

  ## Failures (HK-1, HK-2)

  Every hook runs in a task under the client's `Task.Supervisor` with its
  deadline, never in the connection process. A hook that raises, throws,
  exits (even `exit(:kill)`), times out or returns anything outside its
  contract:

    * pre-hook (and resource/prompt hook): fails the call with
      `{:error, %Error{kind: :hook, reason: {:hook_failed, hook_id, :raise |
      :exit | :timeout | :bad_return}}}`; no request is sent;
    * post-hook: the result is **withheld**: the caller gets
      `{:ok, %ToolResult{is_error: true}}` with a fixed text, and the raw
      result is dropped without being logged. With `on_error: :ignore` the
      hook is skipped instead;
    * failure hook: the original error is returned unchanged;
    * `:on_tools_listed` hook: the listing fails with a `:hook` error
      (rather than an empty list that looks like "no tools").

  What a failing hook raised is never logged or put in telemetry: it may
  quote the arguments or result.

  ## Telemetry

  Each run emits `[:conduit_mcp, :client, :hook, :stop]` (status `:cont`,
  `:rewrite`, `:deny`, `:halt` or `:recover`) or
  `[:conduit_mcp, :client, :hook, :exception]` (reason `:raise`, `:exit`,
  `:timeout` or `:bad_return`); see `ConduitMcp.Telemetry`.
  """

  alias ConduitMcp.Client.{Error, Pattern, Telemetry, Tool, ToolCall, ToolResult}
  alias ConduitMcp.Client.Governance.Exec

  @events [
    :pre_tool_call,
    :post_tool_call,
    :tool_call_failed,
    :on_tools_listed,
    :on_resource_read,
    :on_prompt_get
  ]
  @arity %{
    pre_tool_call: 2,
    post_tool_call: 3,
    tool_call_failed: 3,
    on_tools_listed: 2,
    on_resource_read: 2,
    on_prompt_get: 3
  }
  @ignorable [:post_tool_call, :tool_call_failed]
  @reversed [:post_tool_call, :tool_call_failed]
  @withheld "The tool result was withheld: a post-call hook failed."

  defmodule Hook do
    @moduledoc false
    # One compiled hook. `matcher` is `:global` or a `ConduitMcp.Client.Pattern`
    # matcher compiled loosely; `level` is 0 (global), 1 (server) or 2 (tool).
    @enforce_keys [:id, :event, :level, :matcher, :fun, :timeout, :on_error]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: term(),
            event: atom(),
            level: 0..2,
            matcher: :global | ConduitMcp.Client.Pattern.matcher(),
            fun: function() | {module(), atom()},
            timeout: pos_integer() | nil,
            on_error: :fail | :ignore
          }
  end

  defstruct pre_tool_call: [],
            post_tool_call: [],
            tool_call_failed: [],
            on_tools_listed: [],
            on_resource_read: [],
            on_prompt_get: []

  @typedoc "Compiled hooks, each list in run order. Treat as opaque."
  @type t :: %__MODULE__{
          pre_tool_call: [hook()],
          post_tool_call: [hook()],
          tool_call_failed: [hook()],
          on_tools_listed: [hook()],
          on_resource_read: [hook()],
          on_prompt_get: [hook()]
        }

  @typedoc "One compiled hook. Opaque."
  @type hook :: struct()

  @typedoc """
  What a runner needs from the pipeline: the client's task supervisor, the
  default timeout, and the telemetry base metadata (with `:tool_name` when
  there is one).
  """
  @type env :: %{
          required(:task_sup) => pid(),
          required(:hook_timeout) => pos_integer(),
          required(:telemetry) => map()
        }

  @doc """
  Compiles a `:hooks` keyword list (see the moduledoc). Raises
  `ArgumentError` naming the event and entry on any invalid input. Compiled
  hooks are returned unchanged.
  """
  @spec compile(keyword() | t()) :: t()
  def compile(%__MODULE__{} = hooks), do: hooks

  def compile(spec) when is_list(spec) do
    unless Keyword.keyword?(spec) do
      raise ArgumentError,
            "hooks must be a keyword list of event: [hook, ...], got: #{inspect(spec)}"
    end

    compiled =
      Enum.reduce(spec, %__MODULE__{}, fn
        {event, entries} = pair, acc when event in @events ->
          unless is_list(entries) do
            raise ArgumentError, "hooks #{inspect(event)} must be a list, got: #{inspect(pair)}"
          end

          hooks =
            entries
            |> Enum.with_index()
            |> Enum.map(fn {entry, index} -> hook!(event, entry, index) end)

          Map.update!(acc, event, &(&1 ++ hooks))

        {event, _entries}, _acc ->
          raise ArgumentError,
                "unknown hook event #{inspect(event)}; expected one of #{inspect(@events)}"
      end)

    ids = for event <- @events, hook <- Map.fetch!(compiled, event), do: hook.id

    case ids -- Enum.uniq(ids) do
      [] -> :ok
      [dup | _] -> raise ArgumentError, "duplicate hook id #{inspect(dup)}"
    end

    Enum.reduce(@events, compiled, fn event, acc ->
      ordered = Enum.sort_by(Map.fetch!(acc, event), & &1.level)
      ordered = if event in @reversed, do: Enum.reverse(ordered), else: ordered
      Map.put(acc, event, ordered)
    end)
  end

  def compile(other),
    do: raise(ArgumentError, "hooks must be a keyword list, got: #{inspect(other)}")

  @doc "Whether no hook is configured for any event."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{} = hooks), do: Enum.all?(@events, &(Map.fetch!(hooks, &1) == []))

  defp hook!(event, {matcher, fun}, index), do: hook!(event, {matcher, fun, []}, index)

  defp hook!(event, {matcher, fun, opts} = entry, index) when is_list(opts) do
    label = "hooks #{inspect(event)} entry #{inspect(entry)}"

    Enum.each(opts, fn
      {key, _value} when key in [:id, :timeout, :on_error] -> :ok
      other -> raise ArgumentError, "invalid #{label}: unknown option #{inspect(other)}"
    end)

    id = Keyword.get(opts, :id, {event, index})

    unless is_atom(id) or is_binary(id) or match?({^event, ^index}, id) do
      raise ArgumentError, "invalid #{label}: :id must be an atom or a string"
    end

    timeout = Keyword.get(opts, :timeout)

    unless timeout == nil or (is_integer(timeout) and timeout > 0) do
      raise ArgumentError, "invalid #{label}: :timeout must be a positive integer"
    end

    on_error = Keyword.get(opts, :on_error, :fail)

    cond do
      on_error not in [:fail, :ignore] ->
        raise ArgumentError, "invalid #{label}: :on_error must be :fail or :ignore"

      on_error == :ignore and event not in @ignorable ->
        raise ArgumentError,
              "invalid #{label}: on_error: :ignore is only allowed for post_tool_call " <>
                "and tool_call_failed hooks (the others fail closed)"

      true ->
        :ok
    end

    compiled = compile_matcher(event, matcher, label)

    %Hook{
      id: id,
      event: event,
      level: level(compiled),
      matcher: compiled,
      fun: fun!(event, fun, label),
      timeout: timeout,
      on_error: on_error
    }
  end

  defp hook!(event, entry, _index) do
    raise ArgumentError,
          "invalid hooks #{inspect(event)} entry #{inspect(entry)}: " <>
            "expected {matcher, fun} or {matcher, fun, opts}"
  end

  defp compile_matcher(_event, matcher, _label) when matcher in [:all, :any, "*", "*/*"],
    do: :global

  defp compile_matcher(event, matcher, label) do
    entry =
      case {kind(event), matcher} do
        {:tool, matcher} -> matcher
        {kind, string} when is_binary(string) -> "#{kind}:" <> string
        {kind, {server, %Regex{} = regex}} -> {kind, server, regex}
        {_kind, other} -> other
      end

    Pattern.compile(entry, true, label, [:name, :regex, :resource, :prompt])
  end

  defp kind(:on_resource_read), do: :resource
  defp kind(:on_prompt_get), do: :prompt
  defp kind(_event), do: :tool

  defp level({:name, _kind, :any, :any}), do: 0
  defp level({:name, _kind, _server, :any}), do: 1
  defp level(:global), do: 0
  defp level(_matcher), do: 2

  defp fun!(event, fun, label) do
    arity = Map.fetch!(@arity, event)

    case fun do
      fun when is_function(fun, arity) ->
        fun

      {module, name} when is_atom(module) and is_atom(name) ->
        if Code.ensure_loaded?(module) and function_exported?(module, name, arity),
          do: fun,
          else:
            raise(
              ArgumentError,
              "invalid #{label}: #{inspect(module)}.#{name}/#{arity} is not exported"
            )

      _other ->
        raise ArgumentError,
              "invalid #{label}: expected a #{arity}-arity function or {Module, :function}"
    end
  end

  # --- runners -------------------------------------------------------------------

  @doc false
  # Pre-hooks for `call` against `subject` (a `ConduitMcp.Client.Pattern`
  # subject of the tool).
  @spec run_pre(t(), ToolCall.t(), map(), map(), env()) ::
          {:ok, ToolCall.t()} | {:halt, ToolResult.t()} | {:error, Error.t()}
  def run_pre(%__MODULE__{pre_tool_call: hooks}, %ToolCall{} = call, subject, ctx, env) do
    hooks
    |> matching(subject)
    |> Enum.reduce_while({:ok, call}, fn hook, {:ok, call} ->
      case invoke(hook, [call, ctx], env) do
        {:ok, :cont, time} ->
          stop(hook, env, time, :cont)
          {:cont, {:ok, call}}

        {:ok, {:cont, %ToolCall{} = new}, time} ->
          case rewrite(call, new) do
            {:ok, call} ->
              stop(hook, env, time, :rewrite)
              {:cont, {:ok, call}}

            :error ->
              {:halt, fail_closed(hook, env, time, :bad_return)}
          end

        {:ok, {:deny, reason}, time} ->
          stop(hook, env, time, :deny)
          {:halt, {:error, Error.new(:denied, {:hook_denied, hook.id}, reason)}}

        {:ok, {:halt, %ToolResult{} = result}, time} ->
          if valid_result?(result) do
            stop(hook, env, time, :halt)
            {:halt, {:halt, result}}
          else
            {:halt, fail_closed(hook, env, time, :bad_return)}
          end

        {:ok, _other, time} ->
          {:halt, fail_closed(hook, env, time, :bad_return)}

        {:failed, reason, time} ->
          {:halt, fail_closed(hook, env, time, reason)}
      end
    end)
  end

  # Only `args` and `meta` may change; the digest is recomputed here, never
  # taken from the hook.
  defp rewrite(%ToolCall{} = call, %ToolCall{} = new) do
    if new.server_id == call.server_id and new.name == call.name and
         new.call_id == call.call_id and is_map(new.args) and not is_struct(new.args) and
         is_map(new.meta) and not is_struct(new.meta) do
      {:ok, %{ToolCall.put_args(call, new.args) | meta: new.meta}}
    else
      :error
    end
  rescue
    # Arguments the canonical encoder rejects (not JSON-encodable).
    _error -> :error
  end

  @doc false
  # Post-hooks, in reverse onion order. Never fails: a failing hook withholds
  # the result (or is skipped with `on_error: :ignore`).
  @spec run_post(t(), ToolCall.t(), ToolResult.t(), map(), map(), env()) :: {:ok, ToolResult.t()}
  def run_post(
        %__MODULE__{post_tool_call: hooks},
        call,
        %ToolResult{} = result,
        subject,
        ctx,
        env
      ) do
    hooks
    |> matching(subject)
    |> Enum.reduce_while({:ok, result}, fn hook, {:ok, result} ->
      case invoke(hook, [call, result, ctx], env) do
        {:ok, :cont, time} ->
          stop(hook, env, time, :cont)
          {:cont, {:ok, result}}

        {:ok, {:cont, %ToolResult{} = new}, time} ->
          if valid_result?(new) do
            stop(hook, env, time, :rewrite)
            {:cont, {:ok, new}}
          else
            post_failed(hook, env, time, :bad_return, result)
          end

        {:ok, _other, time} ->
          post_failed(hook, env, time, :bad_return, result)

        {:failed, reason, time} ->
          post_failed(hook, env, time, reason, result)
      end
    end)
  end

  defp post_failed(hook, env, time, reason, result) do
    exception(hook, env, time, reason)

    case hook.on_error do
      :ignore -> {:cont, {:ok, result}}
      :fail -> {:halt, {:ok, withheld()}}
    end
  end

  @doc false
  # The synthetic result a failed post-hook leaves in place of the real one.
  @spec withheld() :: ToolResult.t()
  def withheld,
    do: %ToolResult{content: [%{"type" => "text", "text" => @withheld}], is_error: true}

  @doc false
  # Failure hooks, in reverse onion order. A failing failure hook ends the
  # chain with the original error (or is skipped with `on_error: :ignore`).
  @spec run_failed(t(), ToolCall.t(), Error.t(), map(), map(), env()) ::
          {:ok, ToolResult.t()} | {:error, Error.t()}
  def run_failed(%__MODULE__{tool_call_failed: hooks}, call, %Error{} = error, subject, ctx, env) do
    hooks
    |> matching(subject)
    |> Enum.reduce_while({:error, error}, fn hook, original ->
      case invoke(hook, [call, error, ctx], env) do
        {:ok, :cont, time} ->
          stop(hook, env, time, :cont)
          {:cont, original}

        {:ok, {:recover, %ToolResult{} = result}, time} ->
          if valid_result?(result) do
            stop(hook, env, time, :recover)
            {:halt, {:ok, result}}
          else
            failed_failed(hook, env, time, :bad_return, original)
          end

        {:ok, _other, time} ->
          failed_failed(hook, env, time, :bad_return, original)

        {:failed, reason, time} ->
          failed_failed(hook, env, time, reason, original)
      end
    end)
  end

  defp failed_failed(hook, env, time, reason, original) do
    exception(hook, env, time, reason)

    case hook.on_error do
      :ignore -> {:cont, original}
      :fail -> {:halt, original}
    end
  end

  @doc false
  # `:on_tools_listed` hooks over a tool list; `subject_fun` builds a tool's
  # match subject.
  @spec run_tools_listed(t(), [Tool.t()], (Tool.t() -> map()), map(), env()) ::
          {:ok, [Tool.t()]} | {:error, Error.t()}
  def run_tools_listed(%__MODULE__{on_tools_listed: []}, tools, _subject_fun, _ctx, _env),
    do: {:ok, tools}

  def run_tools_listed(%__MODULE__{on_tools_listed: hooks}, tools, subject_fun, ctx, env) do
    Enum.reduce_while(hooks, {:ok, tools}, fn hook, {:ok, tools} ->
      case Enum.filter(tools, &applies?(hook, subject_fun.(&1))) do
        [] ->
          {:cont, {:ok, tools}}

        mine ->
          case invoke(hook, [mine, ctx], env) do
            {:ok, :cont, time} ->
              stop(hook, env, time, :cont)
              {:cont, {:ok, tools}}

            {:ok, {:cont, kept}, time} when is_list(kept) ->
              case replace(tools, mine, kept) do
                {:ok, tools} ->
                  stop(hook, env, time, :rewrite)
                  {:cont, {:ok, tools}}

                :error ->
                  {:halt, fail_closed(hook, env, time, :bad_return)}
              end

            {:ok, _other, time} ->
              {:halt, fail_closed(hook, env, time, :bad_return)}

            {:failed, reason, time} ->
              {:halt, fail_closed(hook, env, time, reason)}
          end
      end
    end)
  end

  # `kept` must be distinct tools from `mine` (by `{server_id, name}`); they
  # replace `mine` in place, keeping the list's order. The fingerprint stays
  # the server's.
  defp replace(tools, mine, kept) do
    originals = Map.new(mine, &{{&1.server_id, &1.name}, &1})

    returned =
      Enum.reduce_while(kept, %{}, fn
        %Tool{server_id: server_id, name: name} = tool, acc ->
          key = {server_id, name}

          case Map.fetch(originals, key) do
            {:ok, original} when not is_map_key(acc, key) ->
              {:cont, Map.put(acc, key, %{tool | fingerprint: original.fingerprint})}

            _missing_or_duplicate ->
              {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end)

    case returned do
      :error ->
        :error

      returned ->
        {:ok,
         Enum.flat_map(tools, fn tool ->
           key = {tool.server_id, tool.name}

           cond do
             not Map.has_key?(originals, key) -> [tool]
             Map.has_key?(returned, key) -> [Map.fetch!(returned, key)]
             true -> []
           end
         end)}
    end
  end

  @doc false
  @spec run_resource_read(t(), String.t(), map(), map(), env()) :: :ok | {:error, Error.t()}
  def run_resource_read(%__MODULE__{on_resource_read: hooks}, uri, subject, ctx, env) do
    hooks
    |> matching(subject)
    |> Enum.reduce_while(:ok, fn hook, :ok ->
      case invoke(hook, [uri, ctx], env) do
        {:ok, :cont, time} ->
          stop(hook, env, time, :cont)
          {:cont, :ok}

        {:ok, {:deny, reason}, time} ->
          stop(hook, env, time, :deny)
          {:halt, {:error, Error.new(:denied, {:hook_denied, hook.id}, reason)}}

        {:ok, _other, time} ->
          {:halt, fail_closed(hook, env, time, :bad_return)}

        {:failed, reason, time} ->
          {:halt, fail_closed(hook, env, time, reason)}
      end
    end)
  end

  @doc false
  @spec run_prompt_get(t(), String.t(), map(), map(), map(), env()) ::
          {:ok, map()} | {:error, Error.t()}
  def run_prompt_get(%__MODULE__{on_prompt_get: hooks}, name, args, subject, ctx, env) do
    hooks
    |> matching(subject)
    |> Enum.reduce_while({:ok, args}, fn hook, {:ok, args} ->
      case invoke(hook, [name, args, ctx], env) do
        {:ok, :cont, time} ->
          stop(hook, env, time, :cont)
          {:cont, {:ok, args}}

        {:ok, {:cont, new}, time} when is_map(new) and not is_struct(new) ->
          stop(hook, env, time, :rewrite)
          {:cont, {:ok, new}}

        {:ok, {:deny, reason}, time} ->
          stop(hook, env, time, :deny)
          {:halt, {:error, Error.new(:denied, {:hook_denied, hook.id}, reason)}}

        {:ok, _other, time} ->
          {:halt, fail_closed(hook, env, time, :bad_return)}

        {:failed, reason, time} ->
          {:halt, fail_closed(hook, env, time, reason)}
      end
    end)
  end

  # --- helpers ---------------------------------------------------------------------

  defp matching(hooks, subject), do: Enum.filter(hooks, &applies?(&1, subject))

  defp applies?(%Hook{matcher: :global}, _subject), do: true

  defp applies?(%Hook{matcher: matcher}, subject),
    do: Pattern.match(matcher, subject, true) == true

  defp valid_result?(%ToolResult{content: content, is_error: is_error}),
    do: is_list(content) and is_boolean(is_error)

  defp invoke(hook, args, env) do
    start = System.monotonic_time()

    timeout = hook.timeout || env.hook_timeout
    metadata = Telemetry.logger_metadata(env.telemetry)

    case Exec.run(env.task_sup, hook.fun, args, timeout, metadata) do
      {:ok, value} -> {:ok, value, start}
      {:failed, reason} -> {:failed, reason, start}
    end
  end

  defp fail_closed(hook, env, start, reason) do
    exception(hook, env, start, reason)
    {:error, Error.new(:hook, {:hook_failed, hook.id, reason})}
  end

  defp stop(hook, env, start, status),
    do: Telemetry.hook_stop(env.telemetry, hook.id, hook.event, start, status)

  defp exception(hook, env, start, reason),
    do: Telemetry.hook_exception(env.telemetry, hook.id, hook.event, start, reason)
end
