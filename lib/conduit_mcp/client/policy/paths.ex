defmodule ConduitMcp.Client.Policy.Paths do
  @moduledoc """
  Path canonicalization and path predicates for `ConduitMcp.Client.Policy`
  argument rules (PO-9).

      root = "/srv/sandbox"

      ConduitMcp.Client.Policy.compile(
        deny: [{:args, ConduitMcp.Client.Policy.Paths.escapes("path", root)}],
        allow: [{:all, ["fs/write", {:args, ConduitMcp.Client.Policy.Paths.inside("path", root)}]}]
      )

  Argument rules are **defence in depth, not a sandbox**: the server is the
  enforcement point. These helpers only make the client's view of a path
  hard to fool with encodings.

  ## Canonicalization

  `canonicalize/3` turns an argument into an absolute, normalized path, or
  fails:

    * the value must be a valid UTF-8 string with no NUL byte; it is
      normalized to Unicode NFC;
    * a relative path is joined to `root`; `~` is **not** expanded (it is an
      ordinary file name);
    * `.` segments and empty segments are dropped and `..` removes the
      previous segment, lexically (`..` at `/` stays at `/`);
    * with the `:resolve` option, the lexical result is passed to that
      function (for example one that resolves symlinks with
      `:file.read_link_all/1`) and its `{:ok, path}` result is normalized
      again; anything else is a failure. Nothing here touches the file
      system by itself.

  The root goes through the same steps (it must be absolute), so
  `inside?/3` compares like with like.

  ## Predicates

  `inside/3` and `escapes/3` build `{:args, fun}` predicates that read one
  argument, selected by a key (`"path"`) or a key/index list
  (`["files", 0, "path"]`, string keys only). A list value is checked element
  by element. They differ in how they fail:

    * `inside/3` is for allow rules: it matches only when every path
      canonicalizes and lies within the root. A missing argument, an empty
      list, or any failure is no match.
    * `escapes/3` is for deny and ask rules: it matches when any path fails
      to canonicalize (including a non-string value) or lies outside the
      root. A missing argument is no match (there is no path to check).
  """

  @typedoc "Selects one argument: a key, or a list of keys and list indexes."
  @type selector :: String.t() | [String.t() | non_neg_integer()]

  @typedoc "Why a path did not canonicalize."
  @type reason :: :not_a_string | :nul_byte | :invalid_unicode | :relative_root | :resolve_failed

  @doc """
  Canonicalizes `path` against the absolute `root`; see the moduledoc.

  ## Options

    * `:resolve` - `(String.t() -> {:ok, String.t()} | {:error, term()})`,
      applied to the lexically normalized path (default: none).

  ## Examples

      iex> ConduitMcp.Client.Policy.Paths.canonicalize("../../etc/passwd", "/srv/sandbox")
      {:ok, "/etc/passwd"}

      iex> ConduitMcp.Client.Policy.Paths.canonicalize("a/./b//c/..", "/srv")
      {:ok, "/srv/a/b"}

      iex> ConduitMcp.Client.Policy.Paths.canonicalize("a\\0b", "/srv")
      {:error, :nul_byte}
  """
  @spec canonicalize(term(), String.t(), keyword()) :: {:ok, String.t()} | {:error, reason()}
  def canonicalize(path, root, opts \\ []) do
    with {:ok, root} <- canonical_root(root, opts) do
      canonicalize_under(path, root, opts)
    end
  end

  @doc """
  Whether `path` canonicalizes and lies within `root` (or is `root` itself).
  Takes the same options as `canonicalize/3`; any failure is `false`.

      iex> ConduitMcp.Client.Policy.Paths.inside?("/data/../etc", "/data")
      false
      iex> ConduitMcp.Client.Policy.Paths.inside?("/data/x", "/data")
      true
  """
  @spec inside?(term(), String.t(), keyword()) :: boolean()
  def inside?(path, root, opts \\ []) do
    with {:ok, root} <- canonical_root(root, opts),
         {:ok, path} <- canonicalize_under(path, root, opts) do
      within?(path, root)
    else
      _ -> false
    end
  end

  @doc """
  An argument predicate (for `{:args, fun}`) that matches when the selected
  argument is a path, or a non-empty list of paths, all inside `root`.

  Raises `ArgumentError` at build time when `root` is not an absolute path
  or `selector` is malformed.
  """
  @spec inside(selector(), String.t(), keyword()) :: (map() -> boolean())
  def inside(selector, root, opts \\ []) do
    {selector, root} = build!(selector, root, opts)

    fn args ->
      case fetch(args, selector) do
        {:ok, [_ | _] = paths} -> Enum.all?(paths, &inside_root?(&1, root, opts))
        {:ok, []} -> false
        {:ok, path} -> inside_root?(path, root, opts)
        :error -> false
      end
    end
  end

  @doc """
  An argument predicate (for `{:args, fun}`) that matches when the selected
  argument, or any element of it when it is a list, fails to canonicalize or
  lies outside `root`.

  Raises `ArgumentError` at build time when `root` is not an absolute path
  or `selector` is malformed.
  """
  @spec escapes(selector(), String.t(), keyword()) :: (map() -> boolean())
  def escapes(selector, root, opts \\ []) do
    {selector, root} = build!(selector, root, opts)

    fn args ->
      case fetch(args, selector) do
        {:ok, paths} when is_list(paths) -> not Enum.all?(paths, &inside_root?(&1, root, opts))
        {:ok, path} -> not inside_root?(path, root, opts)
        :error -> false
      end
    end
  end

  defp build!(selector, root, opts) do
    selector = List.wrap(selector)

    if selector == [] or not Enum.all?(selector, &(is_binary(&1) or (is_integer(&1) and &1 >= 0))) do
      raise ArgumentError,
            "a path selector must be a string key or a non-empty list of string keys " <>
              "and indexes, got: #{inspect(selector)}"
    end

    case canonical_root(root, opts) do
      {:ok, root} -> {selector, root}
      {:error, reason} -> raise ArgumentError, "invalid path root #{inspect(root)}: #{reason}"
    end
  end

  defp fetch(value, []), do: {:ok, value}

  defp fetch(map, [key | rest]) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch(value, rest)
      :error -> :error
    end
  end

  defp fetch(list, [index | rest]) when is_list(list) and is_integer(index) do
    case Enum.fetch(list, index) do
      {:ok, value} -> fetch(value, rest)
      :error -> :error
    end
  end

  defp fetch(_value, _selector), do: :error

  defp inside_root?(path, root, opts) do
    case canonicalize_under(path, root, opts) do
      {:ok, path} -> within?(path, root)
      {:error, _reason} -> false
    end
  end

  # A root ending in a separator ("/" or a Windows volume such as "c:/")
  # already contains every path that starts with it.
  defp within?(path, root) do
    if String.ends_with?(root, "/"),
      do: String.starts_with?(path, root),
      else: path == root or String.starts_with?(path, root <> "/")
  end

  defp canonical_root(root, opts) do
    with {:ok, root} <- clean(root),
         :absolute <- Path.type(root) do
      normalize_resolved(normalize(root), opts)
    else
      {:error, _} = error -> error
      _relative -> {:error, :relative_root}
    end
  end

  # `root` is already canonical here.
  defp canonicalize_under(path, root, opts) do
    with {:ok, path} <- clean(path) do
      absolute = if Path.type(path) == :absolute, do: path, else: Path.join(root, path)
      normalize_resolved(normalize(absolute), opts)
    end
  end

  defp clean(path) when is_binary(path) do
    cond do
      String.contains?(path, <<0>>) ->
        {:error, :nul_byte}

      not String.valid?(path) ->
        {:error, :invalid_unicode}

      true ->
        case :unicode.characters_to_nfc_binary(path) do
          nfc when is_binary(nfc) -> {:ok, nfc}
          _error -> {:error, :invalid_unicode}
        end
    end
  end

  defp clean(_path), do: {:error, :not_a_string}

  defp normalize_resolved(path, opts) do
    case Keyword.get(opts, :resolve) do
      nil ->
        {:ok, path}

      resolve when is_function(resolve, 1) ->
        case resolve.(path) do
          {:ok, resolved} when is_binary(resolved) ->
            with {:ok, resolved} <- clean(resolved),
                 :absolute <- Path.type(resolved) do
              {:ok, normalize(resolved)}
            else
              _ -> {:error, :resolve_failed}
            end

          _other ->
            {:error, :resolve_failed}
        end
    end
  end

  # Lexical normalization of an absolute path: `Path.split/1` yields the
  # root ("/" or a Windows volume) first; `.`/empty segments are dropped and
  # `..` pops, never above the root.
  defp normalize(absolute) do
    [root | segments] = Path.split(absolute)

    segments
    |> Enum.reduce([], fn
      ".", acc -> acc
      "", acc -> acc
      "..", [] -> []
      "..", [_ | acc] -> acc
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
    |> case do
      [] -> root
      kept -> Path.join([root | kept])
    end
  end
end
