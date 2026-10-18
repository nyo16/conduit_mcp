defmodule ConduitMcp.Client.Naming do
  @moduledoc """
  Builds the exposed (model-facing) tool names for one or more servers.

  `build/2` turns `[{server_id, [%Tool{}]}]` into a `ConduitMcp.Client.ToolSet`
  plus a report of every tool it left out, in four steps:

    1. **Spec charset.** A tool whose name is not 1-128 characters of
       `[A-Za-z0-9_.-]` is rejected with reason `:invalid_name`. This catches
       homoglyphs, zero-width and bidi characters, spaces and empty names
       before any mangling can hide them.
    2. **Mangle.** The exposed name is `prefix <> server_id <> "__" <> sanitize(tool)`,
       where `sanitize/1` maps every character outside `[A-Za-z0-9_-]` to `_`.
       With `namespace: false` (a single server) it is `prefix <> sanitize(tool)`.
    3. **Length.** A name over 64 bytes becomes `prefix <> "trunc_" <> hex8`,
       where `hex8` is the first 8 lower-case hex digits of
       `sha256(server_id <> <<0>> <> tool)`.
    4. **Collisions.** When two or more tools mangle to the same exposed name,
       **all** of them are rejected with reason `:collision`. Picking a
       winner would let one server shadow another's tool.

  Every exposed name therefore matches `^[A-Za-z0-9_-]{1,64}$`, and the
  mapping from accepted tools to exposed names is injective by construction.

  ## Server ids

  A `server_id` is operator configuration, never the self-reported
  `serverInfo.name`. It must match `^[a-z][a-z0-9_]{0,31}$`, must not contain
  `__` and must not end in `_`. The last two rules make the `__` separator
  unambiguous: without them `"a_" <> "__" <> "x"` and `"a" <> "__" <> "_x"`
  would both be `"a___x"`. `validate_server_ids!/1` also rejects duplicates.

  ## Report

  `build/2` returns `{toolset, report}` where `report` is

      %{
        rejected: [{server_id, tool_name, :invalid_name | :collision}],
        collisions: [{exposed_name, [{server_id, tool_name}, ...]}]
      }

  in input order, so the runtime can emit telemetry and log a warning for
  each entry. This module emits nothing itself.
  """

  alias ConduitMcp.Client.{Tool, ToolSet}

  @max_exposed_bytes 64
  @trunc_marker "trunc_"
  @hash_hex_chars 8
  @trunc_bytes byte_size(@trunc_marker) + @hash_hex_chars
  @max_prefix_bytes @max_exposed_bytes - @trunc_bytes

  @server_id_regex ~r/\A[a-z][a-z0-9_]{0,31}\z/
  @tool_name_regex ~r/\A[A-Za-z0-9_.\-]{1,128}\z/
  @prefix_regex ~r/\A[A-Za-z0-9_\-]*\z/

  @type server_id :: String.t()
  @type reason :: :invalid_name | :collision
  @type report :: %{
          rejected: [{server_id(), String.t(), reason()}],
          collisions: [{ToolSet.exposed_name(), [{server_id(), String.t()}, ...]}]
        }

  @doc """
  Builds the toolset and its report.

  `servers` is `[{server_id, tools}]` in configuration order. Each tool's
  `server_id` must equal the server id it is listed under.

  ## Options

    * `:prefix` - a string of `[A-Za-z0-9_-]` prepended to every exposed
      name, at most #{@max_prefix_bytes} bytes. It counts toward the 64-byte
      limit and is kept on truncated names. Default `""`.
    * `:namespace` - `true` (default) puts `server_id <> "__"` in front of
      each tool name. `false` exposes bare (sanitized) tool names and accepts
      exactly one server; its id is then not checked against the server id
      rules.

  Raises `ArgumentError` on an invalid or duplicate server id, a bad
  `:prefix`, `namespace: false` with more than one server, or a tool whose
  `server_id` differs from the one it is listed under.

  ## Example

      iex> {:ok, a} = ConduitMcp.Client.Tool.from_wire("files", %{"name" => "fs.read", "inputSchema" => %{}})
      iex> {:ok, b} = ConduitMcp.Client.Tool.from_wire("files", %{"name" => "fs_read", "inputSchema" => %{}})
      iex> {:ok, c} = ConduitMcp.Client.Tool.from_wire("files", %{"name" => "list", "inputSchema" => %{}})
      iex> {toolset, report} = ConduitMcp.Client.Naming.build([{"files", [a, b, c]}])
      iex> ConduitMcp.Client.ToolSet.names(toolset)
      ["files__list"]
      iex> report.collisions
      [{"files__fs_read", [{"files", "fs.read"}, {"files", "fs_read"}]}]
  """
  @spec build([{server_id(), [Tool.t()]}], keyword()) :: {ToolSet.t(), report()}
  def build(servers, opts \\ []) when is_list(servers) do
    prefix = validate_prefix!(Keyword.get(opts, :prefix, ""))
    namespace? = Keyword.get(opts, :namespace, true)

    if namespace? do
      servers |> Enum.map(&elem(&1, 0)) |> validate_server_ids!()
    else
      validate_single_server!(servers)
    end

    {candidates, invalid} = mangle_all(servers, prefix, namespace?)

    {accepted, collisions} = split_collisions(candidates)

    collided =
      for {_name, colliders} <- collisions, {sid, tool} <- colliders, do: {sid, tool, :collision}

    rejected = order_rejections(servers, invalid ++ collided)

    {ToolSet.new(accepted), %{rejected: rejected, collisions: collisions}}
  end

  @doc """
  Checks one server id against the naming rules.

  Returns `:ok` or `{:error, reason}` with `reason` one of `:not_a_string`,
  `:invalid_format`, `:double_underscore`, `:trailing_underscore`.

      iex> ConduitMcp.Client.Naming.validate_server_id("github")
      :ok
      iex> ConduitMcp.Client.Naming.validate_server_id("git__hub")
      {:error, :double_underscore}
  """
  @spec validate_server_id(term()) ::
          :ok
          | {:error, :not_a_string | :invalid_format | :double_underscore | :trailing_underscore}
  def validate_server_id(id) when not is_binary(id), do: {:error, :not_a_string}

  def validate_server_id(id) do
    cond do
      not Regex.match?(@server_id_regex, id) -> {:error, :invalid_format}
      String.contains?(id, "__") -> {:error, :double_underscore}
      String.ends_with?(id, "_") -> {:error, :trailing_underscore}
      true -> :ok
    end
  end

  @doc """
  Validates a list of server ids: each must pass `validate_server_id/1` and
  none may repeat. Raises `ArgumentError` naming the offending id.
  """
  @spec validate_server_ids!([term()]) :: :ok
  def validate_server_ids!(ids) when is_list(ids) do
    _seen =
      Enum.reduce(ids, MapSet.new(), fn id, seen ->
        case validate_server_id(id) do
          :ok -> :ok
          {:error, reason} -> raise ArgumentError, "invalid server_id #{inspect(id)}: #{reason}"
        end

        if MapSet.member?(seen, id) do
          raise ArgumentError, "duplicate server_id #{inspect(id)}"
        end

        MapSet.put(seen, id)
      end)

    :ok
  end

  @doc """
  Whether `name` satisfies the spec tool-name charset: 1-128 characters of
  `[A-Za-z0-9_.-]`.
  """
  @spec valid_tool_name?(term()) :: boolean()
  def valid_tool_name?(name) when is_binary(name), do: Regex.match?(@tool_name_regex, name)
  def valid_tool_name?(_name), do: false

  @doc """
  Maps every character outside `[A-Za-z0-9_-]` to `_` (one `_` per
  character, not per byte; an invalid UTF-8 sequence also becomes `_`).

      iex> ConduitMcp.Client.Naming.sanitize("fs.read-all")
      "fs_read-all"
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(name) when is_binary(name),
    do: name |> String.replace_invalid("_") |> String.replace(~r/[^A-Za-z0-9_\-]/u, "_")

  @doc """
  The exposed name for `server_id`'s tool `tool_name`, before collision
  handling. Takes the same `:prefix` and `:namespace` options as `build/2`
  but does not validate them.
  """
  @spec exposed_name(server_id(), String.t(), keyword()) :: ToolSet.exposed_name()
  def exposed_name(server_id, tool_name, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")

    base =
      if Keyword.get(opts, :namespace, true),
        do: prefix <> server_id <> "__" <> sanitize(tool_name),
        else: prefix <> sanitize(tool_name)

    if byte_size(base) <= @max_exposed_bytes,
      do: base,
      else: prefix <> @trunc_marker <> short_hash(server_id, tool_name)
  end

  defp short_hash(server_id, tool_name) do
    :crypto.hash(:sha256, [server_id, 0, tool_name])
    |> Base.encode16(case: :lower)
    |> binary_part(0, @hash_hex_chars)
  end

  defp mangle_all(servers, prefix, namespace?) do
    opts = [prefix: prefix, namespace: namespace?]

    {candidates, invalid} =
      Enum.reduce(servers, {[], []}, fn {server_id, tools}, acc ->
        Enum.reduce(tools, acc, fn %Tool{} = tool, {ok, bad} ->
          check_tool_server!(tool, server_id)

          if valid_tool_name?(tool.name) do
            {[{exposed_name(server_id, tool.name, opts), tool} | ok], bad}
          else
            {ok, [{server_id, tool.name, :invalid_name} | bad]}
          end
        end)
      end)

    {Enum.reverse(candidates), Enum.reverse(invalid)}
  end

  defp split_collisions(candidates) do
    counts = Enum.frequencies_by(candidates, &elem(&1, 0))

    {accepted, colliding} = Enum.split_with(candidates, fn {name, _} -> counts[name] == 1 end)

    collisions =
      colliding
      |> Enum.group_by(&elem(&1, 0), fn {_name, tool} -> {tool.server_id, tool.name} end)
      |> then(fn groups ->
        # Report collisions in the order their first member was listed.
        colliding
        |> Enum.map(&elem(&1, 0))
        |> Enum.uniq()
        |> Enum.map(&{&1, Map.fetch!(groups, &1)})
      end)

    {accepted, collisions}
  end

  # Rejections in input order: by server position, then by tool position.
  defp order_rejections(servers, rejected) do
    position =
      for {{server_id, tools}, s} <- Enum.with_index(servers),
          {tool, t} <- Enum.with_index(tools),
          reduce: %{} do
        acc -> Map.put_new(acc, {server_id, tool.name}, {s, t})
      end

    Enum.sort_by(rejected, fn {sid, name, _} -> Map.fetch!(position, {sid, name}) end)
  end

  defp check_tool_server!(%Tool{server_id: server_id}, server_id), do: :ok

  defp check_tool_server!(%Tool{server_id: other, name: name}, server_id) do
    raise ArgumentError,
          "tool #{inspect(name)} has server_id #{inspect(other)} but is listed under #{inspect(server_id)}"
  end

  defp validate_prefix!(prefix)
       when is_binary(prefix) and byte_size(prefix) <= @max_prefix_bytes do
    if Regex.match?(@prefix_regex, prefix) do
      prefix
    else
      raise ArgumentError, ":prefix must contain only [A-Za-z0-9_-], got: #{inspect(prefix)}"
    end
  end

  defp validate_prefix!(prefix) do
    raise ArgumentError,
          ":prefix must be a string of at most #{@max_prefix_bytes} bytes, got: #{inspect(prefix)}"
  end

  defp validate_single_server!([{server_id, _tools}]) when is_binary(server_id), do: :ok
  defp validate_single_server!([]), do: :ok

  defp validate_single_server!(servers) do
    raise ArgumentError,
          "namespace: false accepts exactly one server, got #{length(servers)}"
  end
end
