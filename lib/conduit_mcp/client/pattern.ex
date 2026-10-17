defmodule ConduitMcp.Client.Pattern do
  @moduledoc false
  # Shared rule compiler and matcher for `ConduitMcp.Client.ToolFilter` and
  # `ConduitMcp.Client.Policy`. Rules always match a structured target
  # `{server_id, name}` (a tool name, resource URI or prompt name), one
  # segment at a time, never a namespaced string (PO-3).
  #
  # Compiled matchers:
  #
  #   {:name, kind, server_glob, name_glob}
  #   {:regex, kind, server_glob, %Regex{}}
  #   {:fun, fun}                       - tool rule, fun.(%Tool{}, ctx)
  #   {:annotation, key, boolean}       - tool rule
  #   {:args, fun}                      - tool rule, fun.(args) or fun.(args, ctx)
  #   {:all, kind, [matcher]}
  #
  # A glob is `:any`, `{:literal, binary}` or `{:glob, pieces}` (the pattern
  # split on `*`). `compile/3` folds literal text when `loose?` is set, and
  # `match/3` then compares it against the folded subject (see `fold/1`).
  #
  # `match/3` returns `true`, `false` or `:error`: `:error` means a user
  # predicate raised, exited, threw or returned a non-boolean, and the caller
  # decides which way that fails (match for deny-like lists, no match for
  # allow-like lists). An `:all` is `false` if any member is `false`, else
  # `:error` if any member errored, else `true`.

  alias ConduitMcp.Client.Tool

  @type kind :: :tool | :resource | :prompt
  @type glob :: :any | {:literal, String.t()} | {:glob, [String.t()]}
  @type matcher ::
          {:name, kind(), glob(), glob()}
          | {:regex, kind(), glob(), Regex.t()}
          | {:fun, (Tool.t(), map() -> boolean())}
          | {:annotation, annotation(), boolean()}
          | {:args, (map() -> boolean()) | (map(), map() -> boolean())}
          | {:all, kind(), [matcher()]}
  @type annotation :: :read_only | :destructive | :open_world | :idempotent

  @typedoc """
  What is being matched. `folded_*` are `fold/1` of `server_id`/`name`
  (computed once per evaluation); `tool`, `args`, `trusted?` only matter for
  tool rules.
  """
  @type subject :: %{
          required(:kind) => kind(),
          required(:server_id) => String.t(),
          required(:name) => String.t(),
          required(:folded_server) => String.t(),
          required(:folded_name) => String.t(),
          required(:ctx) => map(),
          optional(:tool) => Tool.t(),
          optional(:args) => map(),
          optional(:trusted?) => boolean()
        }

  @annotations [:read_only, :destructive, :open_world, :idempotent]

  @doc """
  Compiles one rule entry. `allowed` lists the matcher types the caller
  accepts (`:name`, `:regex`, `:fun`, `:annotation`, `:args`, `:all`, plus
  `:resource`/`:prompt` for the scoped string and regex forms). Raises
  `ArgumentError` naming `label` and the entry.
  """
  @spec compile(term(), boolean(), String.t(), [atom()]) :: matcher()
  def compile(entry, loose?, label, allowed) do
    case do_compile(entry, loose?, allowed) do
      {:ok, matcher} -> matcher
      {:error, why} -> raise ArgumentError, "invalid #{label} entry #{inspect(entry)}: #{why}"
    end
  end

  defp do_compile(string, loose?, allowed) when is_binary(string) do
    {kind, rest} = split_kind(string)

    with :ok <- check_allowed(kind_type(kind), allowed),
         {:ok, server, name} <- split_target(rest) do
      {:ok, {:name, kind, glob(server, loose?), glob(name, loose?)}}
    end
  end

  defp do_compile({server, %Regex{} = regex}, loose?, allowed),
    do: compile_regex(:tool, server, regex, loose?, allowed)

  defp do_compile({kind, server, %Regex{} = regex}, loose?, allowed)
       when kind in [:resource, :prompt],
       do: compile_regex(kind, server, regex, loose?, allowed)

  defp do_compile(fun, _loose?, allowed) when is_function(fun) do
    with :ok <- check_allowed(:fun, allowed) do
      if is_function(fun, 2),
        do: {:ok, {:fun, fun}},
        else: {:error, "a function rule must take 2 arguments (tool, ctx)"}
    end
  end

  defp do_compile({:annotation, key, expected}, _loose?, allowed) do
    with :ok <- check_allowed(:annotation, allowed) do
      cond do
        key not in @annotations ->
          {:error, "the annotation must be one of #{inspect(@annotations)}"}

        not is_boolean(expected) ->
          {:error, "the expected annotation value must be a boolean"}

        true ->
          {:ok, {:annotation, key, expected}}
      end
    end
  end

  defp do_compile({:args, fun}, _loose?, allowed) do
    with :ok <- check_allowed(:args, allowed) do
      if is_function(fun, 1) or is_function(fun, 2),
        do: {:ok, {:args, fun}},
        else: {:error, "an :args predicate must take (args) or (args, ctx)"}
    end
  end

  defp do_compile({:all, [_ | _] = entries}, loose?, allowed) do
    with :ok <- check_allowed(:all, allowed),
         {:ok, matchers} <- compile_all(entries, loose?, allowed) do
      case matchers |> Enum.map(&kind/1) |> Enum.uniq() do
        [kind] -> {:ok, {:all, kind, matchers}}
        _kinds -> {:error, "an :all rule cannot mix tool, resource and prompt rules"}
      end
    end
  end

  defp do_compile({:all, _entries}, _loose?, _allowed),
    do: {:error, ":all takes a non-empty list of rules"}

  defp do_compile(_entry, _loose?, _allowed), do: {:error, "unrecognized rule"}

  defp compile_all(entries, loose?, allowed) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case do_compile(entry, loose?, allowed) do
        {:ok, matcher} -> {:cont, {:ok, [matcher | acc]}}
        {:error, why} -> {:halt, {:error, "in #{inspect(entry)}: #{why}"}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp compile_regex(kind, server, regex, loose?, allowed) do
    with :ok <- check_allowed(kind_type(kind, :regex), allowed),
         :ok <- check_server(server) do
      {:ok, {:regex, kind, glob(server, loose?), regex}}
    end
  end

  defp kind_type(kind, base \\ :name)
  defp kind_type(:tool, base), do: base
  defp kind_type(kind, _base), do: kind

  defp check_allowed(type, allowed) do
    if type in allowed, do: :ok, else: {:error, "#{inspect(type)} rules are not accepted here"}
  end

  defp split_kind("resource:" <> rest), do: {:resource, rest}
  defp split_kind("prompt:" <> rest), do: {:prompt, rest}
  defp split_kind(rest), do: {:tool, rest}

  defp split_target(target) do
    case String.split(target, "/", parts: 2) do
      [""] ->
        {:error, "the name is empty"}

      [name] ->
        {:ok, "*", name}

      [server, name] ->
        with :ok <- check_server(server), :ok <- check_name(name), do: {:ok, server, name}
    end
  end

  defp check_server(server) when is_binary(server) do
    cond do
      server == "" -> {:error, "the server segment is empty"}
      String.contains?(server, ":") -> {:error, "the server segment cannot contain \":\""}
      true -> :ok
    end
  end

  defp check_server(_server), do: {:error, "the server must be a string"}

  defp check_name(""), do: {:error, "the name segment is empty"}
  defp check_name(_name), do: :ok

  defp glob(pattern, loose?) do
    pattern = if loose?, do: fold(pattern), else: pattern

    case String.split(pattern, "*") do
      [literal] ->
        {:literal, literal}

      pieces ->
        if Enum.all?(pieces, &(&1 == "")), do: :any, else: {:glob, pieces}
    end
  end

  @doc "The kind of target a compiled matcher applies to."
  @spec kind(matcher()) :: kind()
  def kind({:name, kind, _server, _name}), do: kind
  def kind({:regex, kind, _server, _regex}), do: kind
  def kind({:all, kind, _matchers}), do: kind
  def kind(_tool_only), do: :tool

  @doc """
  Whether the matcher names one exact target: a string rule whose server and
  name segments are both literal, or an `:all` with such a member.
  """
  @spec exact?(matcher()) :: boolean()
  def exact?({:name, _kind, {:literal, _}, {:literal, _}}), do: true
  def exact?({:all, _kind, matchers}), do: Enum.any?(matchers, &exact?/1)
  def exact?(_matcher), do: false

  @doc "Whether the matcher depends on nothing but the `{server_id, name}` target."
  @spec static?(matcher()) :: boolean()
  def static?({:name, _, _, _}), do: true
  def static?({:regex, _, _, _}), do: true
  def static?({:all, _kind, matchers}), do: Enum.all?(matchers, &static?/1)
  def static?(_matcher), do: false

  @doc """
  Case- and separator-insensitive form used by loose matching: Unicode
  lower-case, with `-` and `.` rewritten to `_`.
  """
  @spec fold(String.t()) :: String.t()
  def fold(string), do: string |> String.downcase() |> String.replace(["-", "."], "_")

  @doc "Builds a subject for `match/3`."
  @spec subject(kind(), String.t(), String.t(), map(), keyword()) :: subject()
  def subject(kind, server_id, name, ctx, extra \\ []) do
    Map.merge(
      %{
        kind: kind,
        server_id: server_id,
        name: name,
        folded_server: fold(server_id),
        folded_name: fold(name),
        ctx: ctx
      },
      Map.new(extra)
    )
  end

  @doc "Matches a compiled matcher against a subject; see the module comment."
  @spec match(matcher(), subject(), boolean()) :: boolean() | :error
  def match({:name, kind, server, name}, %{kind: kind} = subject, loose?) do
    glob_match?(server, target(subject, :server, loose?)) and
      glob_match?(name, target(subject, :name, loose?))
  end

  def match({:regex, kind, server, regex}, %{kind: kind} = subject, loose?) do
    glob_match?(server, target(subject, :server, loose?)) and
      (Regex.match?(regex, subject.name) or
         (loose? and Regex.match?(regex, subject.folded_name)))
  end

  def match({:fun, fun}, %{kind: :tool, tool: tool, ctx: ctx}, _loose?),
    do: call_predicate(fun, [tool, ctx])

  def match({:annotation, key, expected}, %{kind: :tool, tool: tool} = subject, _loose?),
    do: annotation(tool, key, Map.get(subject, :trusted?, false)) == expected

  def match({:args, fun}, %{kind: :tool, args: args, ctx: ctx}, _loose?) do
    if is_function(fun, 1),
      do: call_predicate(fun, [args]),
      else: call_predicate(fun, [args, ctx])
  end

  def match({:all, kind, matchers}, %{kind: kind} = subject, loose?) do
    Enum.reduce_while(matchers, true, fn matcher, acc ->
      case match(matcher, subject, loose?) do
        false -> {:halt, false}
        :error -> {:cont, :error}
        true -> {:cont, acc}
      end
    end)
  end

  def match(_matcher, _subject, _loose?), do: false

  defp target(subject, :server, true), do: subject.folded_server
  defp target(subject, :server, false), do: subject.server_id
  defp target(subject, :name, true), do: subject.folded_name
  defp target(subject, :name, false), do: subject.name

  @doc """
  The effective value of a tool annotation for policy (PO-8). An untrusted
  server's hints are ignored in favour of the conservative value
  (`read_only: false`, `destructive: true`, `open_world: true`,
  `idempotent: false`). A trusted server's boolean hint is used, with the
  spec defaults when absent; `destructive` is `false` for a trusted
  read-only tool, as the spec makes `destructiveHint` meaningful only when
  `readOnlyHint` is false.
  """
  @spec annotation(Tool.t(), annotation(), boolean()) :: boolean()
  def annotation(_tool, :read_only, false), do: false
  def annotation(_tool, :destructive, false), do: true
  def annotation(_tool, :open_world, false), do: true
  def annotation(_tool, :idempotent, false), do: false

  def annotation(%Tool{annotations: hints}, key, true) do
    hints = hints || %{}
    read_only = hint(hints, "readOnlyHint", false)

    case key do
      :read_only -> read_only
      :destructive -> not read_only and hint(hints, "destructiveHint", true)
      :open_world -> hint(hints, "openWorldHint", true)
      :idempotent -> hint(hints, "idempotentHint", false)
    end
  end

  defp hint(hints, key, default) do
    case Map.get(hints, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  # User predicates run in the caller; a crash, exit, throw or non-boolean
  # return is reported as `:error` instead of crashing the evaluation.
  defp call_predicate(fun, args) do
    case apply(fun, args) do
      result when is_boolean(result) -> result
      _other -> :error
    end
  catch
    _kind, _reason -> :error
  end

  defp glob_match?(:any, _string), do: true
  defp glob_match?({:literal, literal}, string), do: literal == string

  defp glob_match?({:glob, [first | rest]}, string) do
    String.starts_with?(string, first) and
      match_pieces(
        rest,
        binary_part(string, byte_size(first), byte_size(string) - byte_size(first))
      )
  end

  defp match_pieces([last], string), do: String.ends_with?(string, last)
  defp match_pieces(["" | rest], string), do: match_pieces(rest, string)

  defp match_pieces([piece | rest], string) do
    case :binary.match(string, piece) do
      {pos, len} ->
        skip = pos + len
        match_pieces(rest, binary_part(string, skip, byte_size(string) - skip))

      :nomatch ->
        false
    end
  end
end
