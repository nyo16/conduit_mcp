defmodule ConduitMcp.Client.Adapters.OpenAI do
  @moduledoc """
  Converts between a `ConduitMcp.Client.ToolSet` and OpenAI function tools,
  for both the Chat Completions API (`api: :chat`) and the Responses API
  (`api: :responses`). Pure functions over string-keyed maps; no HTTP.

      {toolset, _} = ConduitMcp.Client.Naming.build([{"files", tools}])
      {tools, report} = OpenAI.tools(toolset, api: :responses)
      # report.fallbacks -> emit [:conduit_mcp, :client, :adapter, :strict_fallback]

      {calls, rejected} = OpenAI.tool_calls(response, toolset, report.null_paths)
      # run each %ToolCall{} through the client pipeline, then:
      outputs = Enum.map(outcomes, fn {call, outcome} ->
        OpenAI.tool_output(call.call_id, outcome, api: :responses)
      end)
      # next input: rejected ++ outputs

  ## Tool definitions

  Chat: `%{"type" => "function", "function" => %{"name", "description", "parameters", "strict"}}`.
  Responses: `%{"type" => "function", "name", "description", "parameters", "strict"}`.

  `"strict"` is **always sent**: when it is omitted the Responses API tries
  to normalize the schema to strict mode and silently falls back, so the
  same tool list would behave differently per API. Names are the toolset's
  exposed names (`^[A-Za-z0-9_-]{1,64}$`, OpenAI's limit). Descriptions have
  invisible characters removed and are capped at 4 KiB (PI-1). Only tools in
  the toolset are emitted (PO-7).

  ## Strict mode

  `strict_schema/1` rewrites an MCP `inputSchema` into the subset OpenAI
  accepts with `"strict": true`, per
  https://developers.openai.com/api/docs/guides/structured-outputs#supported-schemas
  and https://developers.openai.com/api/docs/guides/function-calling#strict-mode
  (checked 2026-10-17):

    * The root must be `"type": "object"` and must not be `anyOf`.
    * Every object gets `"additionalProperties": false` and lists **every**
      property in `required` (sorted). A property that was optional is made
      nullable (`"type": [t, "null"]`, `null` appended to an `enum`, or
      `anyOf: [schema, {"type": "null"}]`); its instance path is returned in
      `null_paths` so `tool_calls/3` can drop the `null` the model must now
      send for it. A property whose schema already allowed `null` keeps it.
    * Kept: `type` (`string number integer boolean object array null`, or a
      list of them), `properties`, `required`, `additionalProperties: false`,
      `items`, `enum`, `const`, `anyOf`, local `$ref` (`#`, `#/$defs/x`,
      `#/definitions/x`) with root `$defs`/`definitions`, `description`,
      `title`, `pattern`, `minLength`, `maxLength`, `multipleOf`,
      `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`,
      `minItems`, `maxItems`, and `format` when it is one of
      `#{Enum.join(ConduitMcp.Client.Adapters.OpenAI.Strict.supported_formats(), " ")}`.
    * Unsupported, so the conversion fails (`{:unsupported, path, keyword}`):
      `#{Enum.join(ConduitMcp.Client.Adapters.OpenAI.Strict.unsupported_keywords(), " ")}`;
      an open map (`additionalProperties` other than `false`, or a nested
      object with neither `properties` nor `additionalProperties: false`);
      an array without an `items` schema; a node with no `type`, `enum`,
      `const`, `anyOf` or `$ref`; a non-local or unresolvable `$ref`; and a
      recursive `$ref` whose definitions have optional properties (their
      null paths would be unbounded).
    * Everything else (`default`, `examples`, `uniqueItems`, `minProperties`,
      `contentMediaType`, vendor keywords, other `format`s) is dropped: it
      only narrows or annotates values, and the server still validates.
    * Limits: at most 5000 properties in total, 10 levels of object nesting
      (`$defs` count from their own root), 120,000 characters across
      property names, definition names, enum values and string consts, 1000
      enum values, and 15,000 characters for a string enum of more than 250
      values. Exceeding one gives `{:unsupported, path, limit}` with `limit`
      one of `:max_properties`, `:max_depth`, `:max_chars`,
      `:max_enum_values`, `:max_enum_chars`.

  With `strict: :auto` (default) each tool that cannot be converted is sent
  with `"strict": false` and its original schema, and listed in the
  report's `fallbacks` so the runtime can emit
  `[:conduit_mcp, :client, :adapter, :strict_fallback]`. With `strict: true`
  such a tool is left out (listed in `excluded`), because OpenAI rejects the
  whole request otherwise.

  ## Results

  Chat Completions tool messages are text only, so media becomes a
  placeholder such as `"[image: image/png, 1024 bytes]"`. Responses
  `function_call_output` takes a string, or an array of `input_text` /
  `input_image` items when the result has an image (JPEG/PNG/GIF/WebP, as a
  data URI); other media becomes an `input_text` placeholder. A result with
  `is_error: true`, or a `ConduitMcp.Client.Error`, is prefixed with
  `"Error: "` (OpenAI has no error flag).
  """

  alias ConduitMcp.Client.Adapters.Content
  alias ConduitMcp.Client.Adapters.OpenAI.Strict
  alias ConduitMcp.Client.{Error, ToolCall, ToolResult, ToolSet}

  @type api :: :chat | :responses
  @type null_path :: [String.t() | :items]
  @type report :: %{
          null_paths: %{ToolSet.exposed_name() => [null_path()]},
          fallbacks: [{ToolSet.exposed_name(), Strict.error()}],
          excluded: [{ToolSet.exposed_name(), Strict.error()}]
        }

  @doc """
  The `tools` request parameter for `toolset`, and a report.

  The report has `null_paths` (exposed name → paths, for every tool sent
  with `"strict": true`; pass it to `tool_calls/3`), `fallbacks` (tools sent
  non-strict under `strict: :auto`, with the conversion error) and
  `excluded` (tools left out under `strict: true`).

  ## Options

    * `:api` - `:chat` or `:responses` (required).
    * `:strict` - `:auto` (default), `true` or `false`.
  """
  @spec tools(ToolSet.t(), keyword()) :: {[map()], report()}
  def tools(%ToolSet{} = toolset, opts) do
    api = api!(opts)
    mode = strict_mode!(opts)
    report = %{null_paths: %{}, fallbacks: [], excluded: []}

    {defs, report} =
      Enum.reduce(ToolSet.entries(toolset), {[], report}, fn {name, tool}, {defs, report} ->
        case definition(name, tool.input_schema, mode) do
          {:strict, schema, paths} ->
            tool_def = build(api, name, tool.description, schema, true)
            {[tool_def | defs], %{report | null_paths: Map.put(report.null_paths, name, paths)}}

          {:loose, schema, nil} ->
            {[build(api, name, tool.description, schema, false) | defs], report}

          {:loose, schema, error} ->
            tool_def = build(api, name, tool.description, schema, false)
            {[tool_def | defs], %{report | fallbacks: [{name, error} | report.fallbacks]}}

          {:excluded, error} ->
            {defs, %{report | excluded: [{name, error} | report.excluded]}}
        end
      end)

    {Enum.reverse(defs),
     %{
       report
       | fallbacks: Enum.reverse(report.fallbacks),
         excluded: Enum.reverse(report.excluded)
     }}
  end

  defp definition(_name, schema, false), do: {:loose, schema, nil}

  defp definition(_name, schema, mode) do
    case {strict_schema(schema), mode} do
      {{:ok, strict, paths}, _} -> {:strict, strict, paths}
      {{:error, error}, :auto} -> {:loose, schema, error}
      {{:error, error}, true} -> {:excluded, error}
    end
  end

  defp build(api, name, description, parameters, strict?) do
    fields =
      %{"name" => name, "parameters" => parameters, "strict" => strict?}
      |> put_description(Content.description(description))

    case api do
      :chat -> %{"type" => "function", "function" => fields}
      :responses -> Map.put(fields, "type", "function")
    end
  end

  defp put_description(map, nil), do: map
  defp put_description(map, description), do: Map.put(map, "description", description)

  @doc """
  Rewrites a JSON Schema into OpenAI's strict-mode subset.

  Returns `{:ok, strict_schema, null_paths}`, where each null path is the
  list of property names (and `:items` for "every array element") leading
  to a property that was optional and is now nullable, or
  `{:error, {:unsupported, schema_path, keyword_or_limit}}`. The rules are
  in the moduledoc.

      iex> schema = %{
      ...>   "type" => "object",
      ...>   "properties" => %{"q" => %{"type" => "string"}, "limit" => %{"type" => "integer"}},
      ...>   "required" => ["q"]
      ...> }
      iex> {:ok, strict, paths} = ConduitMcp.Client.Adapters.OpenAI.strict_schema(schema)
      iex> strict["properties"]["limit"]
      %{"type" => ["integer", "null"]}
      iex> {strict["required"], strict["additionalProperties"], paths}
      {["limit", "q"], false, [["limit"]]}

      iex> ConduitMcp.Client.Adapters.OpenAI.strict_schema(%{
      ...>   "type" => "object",
      ...>   "properties" => %{"v" => %{"oneOf" => [%{"type" => "string"}]}}
      ...> })
      {:error, {:unsupported, ["properties", "v"], "oneOf"}}
  """
  @spec strict_schema(term()) :: {:ok, map(), [null_path()]} | {:error, Strict.error()}
  def strict_schema(schema), do: Strict.convert(schema)

  @doc """
  Removes `null` values at `null_paths` (as returned by `strict_schema/1`)
  from decoded arguments. Only exact `null`s at those paths are removed.

      iex> ConduitMcp.Client.Adapters.OpenAI.strip_nulls(
      ...>   %{"q" => "x", "limit" => nil, "tags" => [%{"k" => nil}]},
      ...>   [["limit"], ["tags", :items, "k"]]
      ...> )
      %{"q" => "x", "tags" => [%{}]}
  """
  @spec strip_nulls(term(), [null_path()]) :: term()
  def strip_nulls(args, null_paths), do: Strict.strip_nulls(args, null_paths)

  @doc """
  Extracts the function calls from a response.

  Accepts a Chat Completion (the first choice's message is used), a Chat
  assistant message (`"tool_calls"`), a Responses response (`"output"`), or
  a list of Chat `tool_calls` entries or Responses output items. Each
  function call whose name resolves in `toolset` becomes a
  `ConduitMcp.Client.ToolCall` with `call_id` set to the Chat `id` or the
  Responses `call_id`. Its `arguments` JSON is decoded (an empty string
  reads as `{}`) and the nulls strict mode introduced are removed using
  `null_paths_by_tool` (the `null_paths` from `tools/2`).

  A call naming a tool not in the toolset, or with arguments that are not a
  JSON object, produces no `ToolCall` (HB-2). Instead it yields an error
  output in the same API's shape, returned in the second list, to send back
  to the model. Other output items (messages, reasoning) are ignored.
  """
  @spec tool_calls(map() | [map()], ToolSet.t(), %{optional(String.t()) => [null_path()]}) ::
          {[ToolCall.t()], [map()]}
  def tool_calls(response, toolset, null_paths_by_tool \\ %{})

  def tool_calls(%{"choices" => [%{"message" => message} | _]}, toolset, null_paths),
    do: tool_calls(message, toolset, null_paths)

  def tool_calls(%{"choices" => _}, _toolset, _null_paths), do: {[], []}

  def tool_calls(%{"output" => items}, toolset, null_paths) when is_list(items),
    do: tool_calls(items, toolset, null_paths)

  def tool_calls(%{"tool_calls" => calls}, toolset, null_paths) when is_list(calls),
    do: tool_calls(calls, toolset, null_paths)

  def tool_calls(%{} = _message, _toolset, _null_paths), do: {[], []}

  def tool_calls(items, %ToolSet{} = toolset, null_paths) when is_list(items) do
    {calls, rejected} =
      Enum.reduce(items, {[], []}, fn item, {calls, rejected} ->
        case function_call(item) do
          nil ->
            {calls, rejected}

          {api, id, name, arguments} ->
            case to_call(id, name, arguments, toolset, null_paths) do
              {:ok, call} -> {[call | calls], rejected}
              {:error, text} -> {calls, [text_output(api, id, text) | rejected]}
            end
        end
      end)

    {Enum.reverse(calls), Enum.reverse(rejected)}
  end

  defp function_call(%{"function" => %{} = function} = item),
    do: {:chat, item["id"], function["name"], function["arguments"]}

  defp function_call(%{"type" => "function_call"} = item),
    do: {:responses, item["call_id"], item["name"], item["arguments"]}

  defp function_call(_item), do: nil

  defp to_call(id, name, arguments, toolset, null_paths) do
    with {:ok, tool} <- resolve(toolset, name),
         {:ok, args} <- decode_arguments(arguments) do
      args = Strict.strip_nulls(args, Map.get(null_paths, name, []))
      {:ok, ToolCall.new(tool.server_id, tool.name, args, call_id: id)}
    end
  end

  defp resolve(toolset, name) do
    case ToolSet.resolve(toolset, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, Content.unknown_tool_text(name)}
    end
  end

  defp decode_arguments(nil), do: {:ok, %{}}
  defp decode_arguments(""), do: {:ok, %{}}
  defp decode_arguments(args) when is_map(args), do: {:ok, args}

  defp decode_arguments(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, args} when is_map(args) -> {:ok, args}
      _ -> {:error, Content.invalid_arguments_text()}
    end
  end

  defp decode_arguments(_args), do: {:error, Content.invalid_arguments_text()}

  @doc """
  Builds the message (Chat) or input item (Responses) answering `call_id`.

  ## Options

    * `:api` - `:chat` or `:responses` (required).
    * `:error_prefix` - prepended to the text of an error result
      (default `"Error: "`).
    * `:structured` - how `structuredContent` is used: `:auto` (default,
      only when `content` is empty), `:prefer`, `:append` or `:ignore`. It
      is rendered as JSON text.
  """
  @spec tool_output(String.t(), ToolResult.t() | Error.t(), keyword()) :: map()
  def tool_output(call_id, result, opts) do
    api = api!(opts)
    {is_error, parts} = Content.parts(result, opts)
    prefix = if is_error, do: Keyword.get(opts, :error_prefix, "Error: "), else: ""

    case api do
      :chat ->
        text_output(:chat, call_id, prefix <> Content.to_text(parts))

      :responses ->
        if Enum.any?(parts, &inline_image?/1),
          do: responses_output(call_id, responses_items(parts, prefix)),
          else: text_output(:responses, call_id, prefix <> Content.to_text(parts))
    end
  end

  defp text_output(:chat, call_id, text),
    do: %{"role" => "tool", "tool_call_id" => call_id, "content" => text}

  defp text_output(:responses, call_id, text), do: responses_output(call_id, text)

  defp responses_output(call_id, output),
    do: %{"type" => "function_call_output", "call_id" => call_id, "output" => output}

  defp inline_image?({:media, kind, mime, _data, _label}),
    do: kind != :audio and Content.inline_image?(mime)

  defp inline_image?(_part), do: false

  defp responses_items(parts, prefix) do
    items =
      Enum.map(parts, fn
        {:text, text} ->
          %{"type" => "input_text", "text" => text}

        {:media, _kind, mime, data, _label} = part ->
          if inline_image?(part),
            do: %{"type" => "input_image", "image_url" => "data:#{mime};base64,#{data}"},
            else: %{"type" => "input_text", "text" => Content.placeholder(part)}
      end)

    if prefix == "", do: items, else: [%{"type" => "input_text", "text" => prefix} | items]
  end

  defp api!(opts) do
    case Keyword.fetch(opts, :api) do
      {:ok, api} when api in [:chat, :responses] ->
        api

      {:ok, other} ->
        raise ArgumentError, ":api must be :chat or :responses, got: #{inspect(other)}"

      :error ->
        raise ArgumentError, "the :api option is required (:chat or :responses)"
    end
  end

  defp strict_mode!(opts) do
    case Keyword.get(opts, :strict, :auto) do
      mode when mode in [:auto, true, false] ->
        mode

      other ->
        raise ArgumentError, ":strict must be :auto, true or false, got: #{inspect(other)}"
    end
  end
end
