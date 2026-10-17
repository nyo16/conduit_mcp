defmodule ConduitMcp.Client.Pipeline.Shaping do
  @moduledoc false
  # LLM shaping of a tool result (PI-2): what `ConduitMcp.Client.Pipeline`
  # returns for `shape: :llm`. Pure; documented in the pipeline's moduledoc.

  alias ConduitMcp.Client.Adapters.Content
  alias ConduitMcp.Client.ToolResult

  @image_mimes ["image/jpeg", "image/png", "image/gif", "image/webp"]
  @audio_mimes ["audio/wav", "audio/x-wav", "audio/mpeg", "audio/ogg", "audio/webm", "audio/flac"]

  @bidi ~r/[\x{061C}\x{200E}\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]/u
  @zero_width ~r/[\x{00AD}\x{034F}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{180B}-\x{180F}\x{200B}-\x{200D}\x{2060}-\x{2064}\x{3164}\x{FE00}-\x{FE0F}\x{FEFF}\x{FFA0}\x{E0100}-\x{E01EF}]/u
  @tag_chars ~r/[\x{E0000}-\x{E007F}]/u

  @typedoc "Why shaping changed a result; reported in `provenance.flags`."
  @type flag :: :bidi | :zero_width | :tag_chars | :media_dropped | :unsupported_content

  @doc """
  Shapes `result` for a model: provenance, invisible characters stripped,
  media outside the allowlist replaced, `_meta` and unknown keys dropped,
  and everything capped at `max_bytes` (with a truncation marker).
  """
  @spec shape(ToolResult.t(), String.t(), pos_integer()) :: ToolResult.t()
  def shape(%ToolResult{} = result, server_id, max_bytes) do
    state = %{left: max_bytes, truncated: false, flags: MapSet.new()}

    {content, state} =
      Enum.reduce(result.content, {[], state}, fn block, {acc, state} ->
        if state.truncated do
          {acc, state}
        else
          {blocks, state} = block(block, state)
          {Enum.reverse(blocks, acc), state}
        end
      end)

    {structured, state} = structured(result.structured, state)
    content = Enum.reverse(content)

    content =
      if state.truncated,
        do: content ++ [text_block(marker(max_bytes))],
        else: content

    %ToolResult{
      content: content,
      structured: structured,
      is_error: result.is_error,
      meta: %{},
      extra: %{},
      provenance: %{
        server_id: server_id,
        truncated: state.truncated,
        flags: state.flags |> MapSet.to_list() |> Enum.sort()
      }
    }
  end

  @doc "The text appended to a truncated result."
  @spec marker(pos_integer()) :: String.t()
  def marker(max_bytes),
    do: "[truncated by the MCP client: the result exceeded #{max_bytes} bytes]"

  defp block(%{"type" => "text", "text" => text}, state) when is_binary(text) do
    {text, state} = clean(text, state)
    {text, state} = take_text(text, state)
    {[text_block(text)], state}
  end

  defp block(%{"type" => type, "data" => data, "mimeType" => mime}, state)
       when type in ["image", "audio"] and is_binary(data) and is_binary(mime) do
    allowed = if type == "image", do: @image_mimes, else: @audio_mimes

    cond do
      mime not in allowed ->
        placeholder(
          "[#{type} omitted: #{safe(mime)} is not an allowed type]",
          :media_dropped,
          state
        )

      byte_size(data) > state.left ->
        {[], %{state | truncated: true}}

      true ->
        {[%{"type" => type, "data" => data, "mimeType" => mime}],
         %{state | left: state.left - byte_size(data)}}
    end
  end

  defp block(%{"type" => "resource_link", "uri" => uri} = link, state) when is_binary(uri) do
    {fields, state} =
      Enum.reduce(["name", "title", "description"], {%{}, state}, fn key, {acc, state} ->
        case link do
          %{^key => value} when is_binary(value) ->
            {value, state} = clean(value, state)
            {Map.put(acc, key, value), state}

          _absent ->
            {acc, state}
        end
      end)

    {uri, state} = clean(uri, state)
    block = Map.merge(fields, %{"type" => "resource_link", "uri" => uri})
    block = put_mime(block, link)
    size = block |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    if size > state.left,
      do: {[], %{state | truncated: true}},
      else: {[block], %{state | left: state.left - size}}
  end

  defp block(%{"type" => "resource", "resource" => %{"uri" => uri} = resource}, state)
       when is_binary(uri) do
    {uri, state} = clean(uri, state)

    case resource do
      %{"text" => text} when is_binary(text) ->
        {text, state} = clean(text, state)
        {text, state} = take_text(text, %{state | left: max(state.left - byte_size(uri), 0)})

        embedded = put_mime(%{"uri" => uri, "text" => text}, resource)
        {[%{"type" => "resource", "resource" => embedded}], state}

      %{"blob" => blob, "mimeType" => mime} when is_binary(blob) and mime in @image_mimes ->
        if byte_size(blob) > state.left do
          {[], %{state | truncated: true}}
        else
          embedded = %{"uri" => uri, "blob" => blob, "mimeType" => mime}

          {[%{"type" => "resource", "resource" => embedded}],
           %{state | left: state.left - byte_size(blob)}}
        end

      %{"blob" => _blob} ->
        mime = if is_binary(resource["mimeType"]), do: safe(resource["mimeType"]), else: "unknown"
        placeholder("[resource omitted: #{uri} (#{mime})]", :media_dropped, state)

      _other ->
        placeholder("[resource: #{uri}]", :unsupported_content, state)
    end
  end

  defp block(_other, state),
    do: placeholder("[unsupported content omitted]", :unsupported_content, state)

  defp placeholder(text, flag, state) do
    {text, state} = take_text(text, %{state | flags: MapSet.put(state.flags, flag)})
    {[text_block(text)], state}
  end

  defp put_mime(block, %{"mimeType" => mime}) when is_binary(mime),
    do: Map.put(block, "mimeType", safe(mime))

  defp put_mime(block, _source), do: block

  defp text_block(text), do: %{"type" => "text", "text" => text}

  defp safe(text), do: text |> Content.strip_invisible() |> String.slice(0, 128)

  # Strips invisible characters, recording which classes were present.
  defp clean(text, state) do
    text = String.replace_invalid(text)

    flags =
      Enum.reduce(
        [{:bidi, @bidi}, {:zero_width, @zero_width}, {:tag_chars, @tag_chars}],
        state.flags,
        fn {flag, regex}, flags ->
          if Regex.match?(regex, text), do: MapSet.put(flags, flag), else: flags
        end
      )

    {Content.strip_invisible(text), %{state | flags: flags}}
  end

  defp take_text(text, state) when byte_size(text) <= state.left,
    do: {text, %{state | left: state.left - byte_size(text)}}

  defp take_text(text, state),
    do:
      {Content.trim_to_valid(binary_part(text, 0, state.left)),
       %{state | left: 0, truncated: true}}

  defp structured(nil, state), do: {nil, state}

  defp structured(_structured, %{truncated: true} = state), do: {nil, state}

  defp structured(structured, state) do
    {structured, state} = clean_term(structured, state)
    size = byte_size(JSON.encode!(structured))

    if size > state.left,
      do: {nil, %{state | truncated: true}},
      else: {structured, %{state | left: state.left - size}}
  end

  defp clean_term(text, state) when is_binary(text), do: clean(text, state)

  defp clean_term(list, state) when is_list(list) do
    {items, state} = Enum.map_reduce(list, state, &clean_term/2)
    {items, state}
  end

  defp clean_term(map, state) when is_map(map) and not is_struct(map) do
    {pairs, state} =
      Enum.map_reduce(map, state, fn {key, value}, state ->
        {key, state} = if is_binary(key), do: clean(key, state), else: {key, state}
        {value, state} = clean_term(value, state)
        {{key, value}, state}
      end)

    {Map.new(pairs), state}
  end

  defp clean_term(other, state), do: {other, state}
end
