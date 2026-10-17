defmodule ConduitMcp.Client.ToolFilter do
  @moduledoc """
  Tool visibility: which tools an application (and its LLM) can see at all.

  Visibility is separate from authorization (`ConduitMcp.Client.Policy`): a
  hidden tool is left out of tool lists and adapter output, and calling it
  fails with `{:error, %ConduitMcp.Client.Error{kind: :not_found}}` (PO-7),
  so it cannot be reached by guessing its name.

      filter =
        ConduitMcp.Client.ToolFilter.compile(
          include: ["github/*", "fs/read_*"],
          exclude: ["*/delete_*", fn tool, ctx -> hidden_for?(ctx.assigns.user, tool) end]
        )

      ConduitMcp.Client.ToolFilter.visible?(filter, tool, ctx)

  ## Patterns

  Every pattern matches the structured target `{server_id, tool_name}`, never
  a namespaced string, so `server "a_b"` + `tool "c"` and `server "a"` +
  `tool "b_c"` can never be confused:

    * `"server/tool"` - `*` is a glob within one segment (it matches any run
      of characters, including none, in that segment only). A bare `"tool"`
      (no `/`) means any server. `"*"` matches every tool.
    * `{server, %Regex{}}` - the regex is matched against the tool name;
      `server` is a segment glob as above (`"*"` for any server).
    * a 2-arity function `fn %ConduitMcp.Client.Tool{}, ctx -> boolean end`.
      It is called in the caller. A function that raises, exits, throws or
      returns a non-boolean counts as matching for `:exclude` (hidden) and
      as not matching for `:include` (fail closed).

  ## Semantics

    * `:exclude` always wins: a tool matching any exclude pattern is hidden.
    * An empty `:include` (the default) means every tool not excluded is
      visible; otherwise a tool must match at least one include pattern.
    * Exclude patterns match **loosely** (Unicode lower-case, with `-`, `.`
      and `_` equivalent), so `exclude: ["*/delete_repo"]` also hides
      `Delete-Repo`. Include patterns match **exactly** (case-sensitive), the
      same asymmetry `ConduitMcp.Client.Policy` uses for deny and allow
      (PO-5). Loose matching applies to both segments, and a regex is tried
      against both the tool name and its folded form.

  ## Static and dynamic filtering

  String and regex patterns depend only on the target, so they can be applied
  once when a server's tool list is refreshed: `static_visible?/2`. Function
  patterns depend on the call context (`ctx.assigns`), so they run at read
  time in the caller: `visible?/3`. `static_visible?/2` never hides a tool
  that `visible?/3` could show, so refresh-time filtering followed by
  read-time filtering gives the same result as `visible?/3` alone.
  """

  alias ConduitMcp.Client.{Pattern, Tool}

  @enforce_keys [:include, :exclude]
  defstruct include: [], exclude: []

  @typedoc "A pattern as written in `compile/1` options."
  @type pattern ::
          String.t() | {String.t(), Regex.t()} | (Tool.t(), map() -> boolean())

  @typedoc "A compiled filter. Treat as opaque."
  @type t :: %__MODULE__{include: [Pattern.matcher()], exclude: [Pattern.matcher()]}

  @allowed [:name, :regex, :fun]

  @doc """
  Compiles `include:` and `exclude:` pattern lists (both default to `[]`).

  Raises `ArgumentError` naming the option and the entry for an unknown
  option, a non-list value, an unrecognized pattern, an empty segment, a
  server segment containing `:`, or a function of the wrong arity.
  """
  @spec compile(keyword()) :: t()
  def compile(opts \\ []) when is_list(opts) do
    Enum.each(opts, fn
      {key, _} when key in [:include, :exclude] -> :ok
      other -> raise ArgumentError, "unknown tool filter option #{inspect(other)}"
    end)

    %__MODULE__{
      include: compile_list(opts, :include, false),
      exclude: compile_list(opts, :exclude, true)
    }
  end

  defp compile_list(opts, key, loose?) do
    case Keyword.get(opts, key, []) do
      list when is_list(list) ->
        Enum.map(list, &Pattern.compile(&1, loose?, "tool filter #{inspect(key)}", @allowed))

      other ->
        raise ArgumentError, "tool filter #{inspect(key)} must be a list, got: #{inspect(other)}"
    end
  end

  @doc """
  Whether `tool` is visible under every pattern, including function patterns
  (called with `ctx`). Use at read time, in the caller.
  """
  @spec visible?(t(), Tool.t(), map()) :: boolean()
  def visible?(%__MODULE__{include: include, exclude: exclude}, %Tool{} = tool, ctx)
      when is_map(ctx) do
    subject = subject(tool, ctx)

    not Enum.any?(exclude, &(Pattern.match(&1, subject, true) != false)) and
      (include == [] or Enum.any?(include, &(Pattern.match(&1, subject, false) == true)))
  end

  @doc """
  Whether `tool` survives the static (string and regex) patterns alone. Use
  when a tool list is refreshed. Function patterns are not called: an
  include list that has a function pattern keeps every tool it does not
  statically include, for `visible?/3` to decide at read time.
  """
  @spec static_visible?(t(), Tool.t()) :: boolean()
  def static_visible?(%__MODULE__{include: include, exclude: exclude}, %Tool{} = tool) do
    subject = subject(tool, %{})
    {static_include, dynamic_include} = Enum.split_with(include, &Pattern.static?/1)

    not Enum.any?(exclude, &(Pattern.static?(&1) and Pattern.match(&1, subject, true))) and
      (include == [] or dynamic_include != [] or
         Enum.any?(static_include, &Pattern.match(&1, subject, false)))
  end

  defp subject(%Tool{server_id: server_id, name: name} = tool, ctx),
    do: Pattern.subject(:tool, server_id, name, ctx, tool: tool)
end
