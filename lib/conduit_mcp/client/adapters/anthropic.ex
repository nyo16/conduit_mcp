defmodule ConduitMcp.Client.Adapters.Anthropic do
  @moduledoc """
  Converts between a `ConduitMcp.Client.ToolSet` and the Anthropic Messages
  API tool format. Pure functions over string-keyed maps; no HTTP.

      {toolset, _report} = ConduitMcp.Client.Naming.build([{"files", tools}])

      request = %{"model" => model, "messages" => messages,
                  "tools" => Anthropic.tools(toolset, cache_control: :last)}

      # ... the response stops with "tool_use" ...
      {calls, rejected} = Anthropic.tool_calls(response, toolset)
      # run each %ToolCall{} through the client pipeline, then:
      results = Enum.map(outcomes, fn {call, outcome} -> Anthropic.tool_result(call.call_id, outcome) end)
      # next user turn: %{"role" => "user", "content" => rejected ++ results ++ other_blocks}

  ## Tool definitions

  `tools/2` emits `%{"name", "description", "input_schema"}` per tool in
  toolset order. Names are the toolset's exposed names, which satisfy
  Anthropic's `^[a-zA-Z0-9_-]{1,128}$`. Descriptions have invisible
  characters (bidi, zero-width, tag, other controls) removed and are capped
  at 4 KiB (PI-1). Only tools in the toolset are emitted, so tools removed by
  a filter, a collision or a down server never reach the model (PO-7).

  ## No forced `tool_choice`

  This module never builds a `tool_choice` of type `any` or `tool`. Current
  Claude models (Opus 5.5, Sonnet 5.5, Fable 5.1, Mythos 5.1) reject forced
  tool use with HTTP 400; leave `tool_choice` unset (or `auto`/`none`).
  Source: https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use
  (verified 2026-10-17).

  ## Results

  `tool_result/3` maps MCP content into `tool_result.content`:

  | MCP content | Anthropic block |
  |---|---|
  | `text` | `text` |
  | `image` (JPEG/PNG/GIF/WebP) | `image` with a base64 source |
  | other images (e.g. SVG), `audio` | `text` placeholder `"[image: mime, n bytes]"` |
  | `resource_link` | `text` `"[resource] name <uri> (mime)"` |
  | embedded text `resource` | `text` with a `[resource: uri]` header |
  | embedded blob `resource` | `image` if an accepted image type, else a placeholder |

  `is_error` is `true` for a `ToolResult` with `is_error: true` and for any
  `ConduitMcp.Client.Error`. `tool_result` blocks must come first in the
  next user turn.
  """

  alias ConduitMcp.Client.Adapters.Content
  alias ConduitMcp.Client.{Error, ToolCall, ToolResult, ToolSet}

  @doc """
  The `tools` request parameter for `toolset`.

  ## Options

    * `:cache_control` - `:last` sets `"cache_control" => %{"type" => "ephemeral"}`
      on the last tool, caching the whole tool list as a prompt prefix.
      Default `nil` (no cache marker).
  """
  @spec tools(ToolSet.t(), keyword()) :: [map()]
  def tools(%ToolSet{} = toolset, opts \\ []) do
    defs =
      for {name, tool} <- ToolSet.entries(toolset) do
        %{"name" => name, "input_schema" => tool.input_schema}
        |> put_description(Content.description(tool.description))
      end

    case Keyword.get(opts, :cache_control) do
      nil ->
        defs

      :last ->
        List.update_at(defs, -1, &Map.put(&1, "cache_control", %{"type" => "ephemeral"}))

      other ->
        raise ArgumentError, ":cache_control must be :last or nil, got: #{inspect(other)}"
    end
  end

  defp put_description(map, nil), do: map
  defp put_description(map, description), do: Map.put(map, "description", description)

  @doc """
  Extracts the tool calls from a response.

  Accepts a Messages API response or assistant message (anything with a
  `"content"` list) or the content block list itself. Every `tool_use` block
  whose `name` resolves in `toolset` becomes a `ConduitMcp.Client.ToolCall`
  for the tool's server and MCP name, with `call_id` set to the block's `id`.

  A `tool_use` naming a tool that is not in the toolset, or whose `input` is
  not an object, produces no call (nothing may be sent to a server, HB-2).
  Instead it yields an `is_error` `tool_result` block, returned in the
  second list, to put in the next user turn. Other block types are ignored.
  """
  @spec tool_calls(map() | [map()], ToolSet.t()) :: {[ToolCall.t()], [map()]}
  def tool_calls(%{"content" => blocks}, %ToolSet{} = toolset) when is_list(blocks),
    do: tool_calls(blocks, toolset)

  def tool_calls(blocks, %ToolSet{} = toolset) when is_list(blocks) do
    {calls, rejected} =
      Enum.reduce(blocks, {[], []}, fn
        %{"type" => "tool_use"} = block, {calls, rejected} ->
          case to_call(block, toolset) do
            {:ok, call} -> {[call | calls], rejected}
            {:error, text} -> {calls, [error_block(block["id"], text) | rejected]}
          end

        _other, acc ->
          acc
      end)

    {Enum.reverse(calls), Enum.reverse(rejected)}
  end

  defp to_call(%{"name" => name} = block, toolset) do
    with {:ok, tool} <- resolve(toolset, name),
         {:ok, input} <- input(block) do
      {:ok, ToolCall.new(tool.server_id, tool.name, input, call_id: block["id"])}
    end
  end

  defp to_call(_block, _toolset), do: {:error, Content.unknown_tool_text(nil)}

  defp resolve(toolset, name) do
    case ToolSet.resolve(toolset, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, Content.unknown_tool_text(name)}
    end
  end

  defp input(%{"input" => input}) when is_map(input), do: {:ok, input}
  defp input(block) when not is_map_key(block, "input"), do: {:ok, %{}}
  defp input(_block), do: {:error, Content.invalid_arguments_text()}

  defp error_block(tool_use_id, text) do
    %{
      "type" => "tool_result",
      "tool_use_id" => tool_use_id,
      "is_error" => true,
      "content" => [%{"type" => "text", "text" => text}]
    }
  end

  @doc """
  Builds the `tool_result` block answering `tool_use_id`.

  ## Options

    * `:structured` - how `structuredContent` is used: `:auto` (default, only
      when `content` is empty), `:prefer`, `:append` or `:ignore`. It is
      rendered as JSON text.
  """
  @spec tool_result(String.t(), ToolResult.t() | Error.t(), keyword()) :: map()
  def tool_result(tool_use_id, result, opts \\ []) do
    {is_error, parts} = Content.parts(result, opts)

    %{
      "type" => "tool_result",
      "tool_use_id" => tool_use_id,
      "is_error" => is_error,
      "content" => Enum.map(parts, &render/1)
    }
  end

  defp render({:text, text}), do: %{"type" => "text", "text" => text}

  defp render({:media, kind, mime, data, _label} = part) do
    if kind != :audio and Content.inline_image?(mime) do
      %{
        "type" => "image",
        "source" => %{"type" => "base64", "media_type" => mime, "data" => data}
      }
    else
      %{"type" => "text", "text" => Content.placeholder(part)}
    end
  end
end
