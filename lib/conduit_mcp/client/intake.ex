defmodule ConduitMcp.Client.Intake do
  @moduledoc false

  # Turns one page of a list result into client structs. Tools are checked
  # one by one and a bad one is dropped, never the whole page (PO-4, HT-12):
  #
  #   * a name outside the spec charset (`[A-Za-z0-9_.-]`, 1-128) -
  #     `:invalid_name` (homoglyphs, zero-width and bidi characters, spaces,
  #     empty and over-long names all fail it);
  #   * a definition that is not a tool (no string `name`, no object
  #     `inputSchema`) - `:invalid_definition`;
  #   * a second tool with a name already seen on this listing -
  #     `:duplicate_name`;
  #   * on `:http` transports only, an `inputSchema` whose `x-mcp-header`
  #     annotations fail `ConduitMcp.Headers.validate_x_mcp_header/1` -
  #     `:invalid_x_mcp_header` (the headers are only sent over HTTP).
  #
  # Each drop emits `[:conduit_mcp, :client, :tool, :rejected]` and logs a
  # warning naming the sanitized tool name. Kept tools carry their
  # `ConduitMcp.Client.Fingerprint`. Prompts, resources and templates keep
  # the stricter shape check: one malformed item fails the page.

  require Logger

  alias ConduitMcp.Client.Error
  alias ConduitMcp.Client.Fingerprint
  alias ConduitMcp.Client.Naming
  alias ConduitMcp.Client.Prompt
  alias ConduitMcp.Client.Resource
  alias ConduitMcp.Client.Telemetry
  alias ConduitMcp.Client.Tool
  alias ConduitMcp.Reflect

  @type kind :: :tools | :prompts | :resources | :resource_templates
  @type ctx :: %{server_id: String.t(), http?: boolean(), telemetry: Telemetry.base()}

  @doc """
  Decodes the `items` of one page. `seen` holds the tool names already kept
  on earlier pages of the same listing (`MapSet.new()` for a single page).
  Returns the kept items, the count of rejected ones and the updated `seen`.
  """
  @spec decode(kind(), term(), ctx(), MapSet.t()) ::
          {:ok, [term()], non_neg_integer(), MapSet.t()} | {:error, Error.t()}
  def decode(_kind, items, _ctx, _seen) when not is_list(items),
    do: {:error, Error.new(:protocol, :invalid_list_result)}

  def decode(:tools, items, ctx, seen), do: tools(items, ctx, seen)

  def decode(:prompts, items, ctx, seen),
    do: strict(items, seen, &Prompt.from_wire(ctx.server_id, &1))

  def decode(:resources, items, ctx, seen),
    do: strict(items, seen, &Resource.from_wire(ctx.server_id, &1))

  def decode(:resource_templates, items, _ctx, seen), do: strict(items, seen, &raw_object/1)

  defp tools(items, ctx, seen) do
    {kept, rejected, seen} =
      Enum.reduce(items, {[], 0, seen}, fn raw, {kept, rejected, seen} ->
        case check_tool(raw, ctx, seen) do
          {:ok, tool} ->
            {[tool | kept], rejected, MapSet.put(seen, tool.name)}

          {:reject, name, reason} ->
            report(ctx, name, reason)
            {kept, rejected + 1, seen}
        end
      end)

    {:ok, Enum.reverse(kept), rejected, seen}
  end

  defp check_tool(raw, ctx, seen) do
    name = if is_map(raw), do: Map.get(raw, "name")

    cond do
      not Naming.valid_tool_name?(name) ->
        {:reject, name, :invalid_name}

      MapSet.member?(seen, name) ->
        {:reject, name, :duplicate_name}

      true ->
        case Tool.from_wire(ctx.server_id, raw) do
          {:ok, tool} -> check_headers(tool, ctx)
          {:error, _} -> {:reject, name, :invalid_definition}
        end
    end
  end

  defp check_headers(tool, %{http?: true}) do
    case ConduitMcp.Headers.validate_x_mcp_header(tool.input_schema) do
      :ok -> {:ok, fingerprinted(tool)}
      {:error, _errors} -> {:reject, tool.name, :invalid_x_mcp_header}
    end
  end

  defp check_headers(tool, _ctx), do: {:ok, fingerprinted(tool)}

  defp fingerprinted(tool), do: %{tool | fingerprint: Fingerprint.compute(tool)}

  defp report(ctx, name, reason) do
    shown = shown_name(name)
    Telemetry.tool_rejected(ctx.telemetry, shown, reason)

    Logger.warning(
      "MCP client excluded a tool listed by server #{Reflect.text(ctx.server_id, 64)}: " <>
        "name=#{inspect(shown)} reason=#{reason}"
    )
  end

  # Names that fail the charset may carry bidi or zero-width characters:
  # only the sanitized form reaches logs and telemetry.
  defp shown_name(name) when is_binary(name), do: name |> Naming.sanitize() |> Reflect.text(128)
  defp shown_name(_name), do: nil

  defp strict(items, seen, decode) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case decode.(item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded), 0, seen}
      error -> error
    end
  end

  defp raw_object(%{} = map) when not is_struct(map), do: {:ok, map}
  defp raw_object(other), do: {:error, Error.new(:protocol, :invalid_item, other)}
end
