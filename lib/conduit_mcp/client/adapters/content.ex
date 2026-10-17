defmodule ConduitMcp.Client.Adapters.Content do
  @moduledoc false
  # Provider-neutral pieces shared by the `ConduitMcp.Client.Adapters.*`
  # modules: description hygiene (PI-1), and flattening a tool outcome into
  # text and media parts that each adapter then renders in its own shape.

  alias ConduitMcp.Client.{Error, ToolResult}

  @max_description_bytes 4096
  @ellipsis "…"

  # Invisible or direction-changing code points (PI-1): C0/C1 controls other
  # than tab/LF/CR, soft hyphen, combining grapheme joiner, Arabic letter
  # mark, Hangul fillers, Khmer/Mongolian invisibles and variation selectors,
  # zero-width and bidi controls (U+200B-200F, U+202A-202E, U+2060-206F),
  # BOM, interlinear annotation controls, Unicode tag characters
  # (U+E0000-E007F) and the supplementary variation selectors.
  @invisible ~r/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{007F}-\x{009F}\x{00AD}\x{034F}\x{061C}\x{115F}\x{1160}\x{17B4}\x{17B5}\x{180B}-\x{180F}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{206F}\x{3164}\x{FE00}-\x{FE0F}\x{FEFF}\x{FFA0}\x{FFF9}-\x{FFFB}\x{E0000}-\x{E007F}\x{E0100}-\x{E01EF}]/u

  # Image types every supported provider accepts inline. Anything else
  # (notably SVG, PI-2) becomes a text placeholder.
  @image_mimes ["image/jpeg", "image/png", "image/gif", "image/webp"]

  @type media_kind :: :image | :audio | :blob
  @type part ::
          {:text, String.t()}
          | {:media, media_kind(), mime :: String.t(), base64 :: String.t(), source :: String.t()}

  @doc "Maximum description size in bytes after sanitizing."
  @spec max_description_bytes() :: pos_integer()
  def max_description_bytes, do: @max_description_bytes

  @doc """
  Strips invisible characters from a tool description and caps it at 4 KiB
  (an ellipsis marks a cut). `nil` stays `nil`.
  """
  @spec description(String.t() | nil) :: String.t() | nil
  def description(nil), do: nil

  def description(text) when is_binary(text) do
    text
    |> String.replace_invalid()
    |> String.replace(@invisible, "")
    |> cap(@max_description_bytes)
  end

  defp cap(text, max) when byte_size(text) <= max, do: text

  defp cap(text, max) do
    keep = max - byte_size(@ellipsis)
    trim_to_valid(binary_part(text, 0, keep)) <> @ellipsis
  end

  defp trim_to_valid(bin) do
    if String.valid?(bin), do: bin, else: trim_to_valid(binary_part(bin, 0, byte_size(bin) - 1))
  end

  @doc "Whether `mime` is an image type all providers accept inline."
  @spec inline_image?(term()) :: boolean()
  def inline_image?(mime), do: mime in @image_mimes

  @doc """
  Flattens a tool outcome into `{is_error, parts}`.

  `ConduitMcp.Client.Error` values become one error text part. A
  `ConduitMcp.Client.ToolResult` keeps its content order; `structuredContent`
  is handled per the `:structured` option:

    * `:auto` (default) - used (as JSON text) only when `content` is empty.
    * `:prefer` - replaces `content` when present.
    * `:append` - appended after `content` when present.
    * `:ignore` - never used.
  """
  @spec parts(ToolResult.t() | Error.t(), keyword()) :: {boolean(), [part()]}
  def parts(%Error{} = error, _opts), do: {true, [{:text, Exception.message(error)}]}

  def parts(%ToolResult{} = result, opts) do
    content = Enum.map(result.content, &content_part/1)
    {result.is_error, with_structured(content, result.structured, structured_mode(opts))}
  end

  defp structured_mode(opts) do
    case Keyword.get(opts, :structured, :auto) do
      mode when mode in [:auto, :prefer, :append, :ignore] ->
        mode

      other ->
        raise ArgumentError,
              ":structured must be :auto, :prefer, :append or :ignore, got: #{inspect(other)}"
    end
  end

  defp with_structured(content, nil, _mode), do: content
  defp with_structured(content, _structured, :ignore), do: content
  defp with_structured([], structured, :auto), do: [structured_text(structured)]
  defp with_structured(content, _structured, :auto), do: content
  defp with_structured(_content, structured, :prefer), do: [structured_text(structured)]
  defp with_structured(content, structured, :append), do: content ++ [structured_text(structured)]

  defp structured_text(structured), do: {:text, JSON.encode!(structured)}

  defp content_part(%{"type" => "text", "text" => text}) when is_binary(text), do: {:text, text}

  defp content_part(%{"type" => "image", "data" => data, "mimeType" => mime})
       when is_binary(data) and is_binary(mime),
       do: {:media, :image, mime, data, "image"}

  defp content_part(%{"type" => "audio", "data" => data, "mimeType" => mime})
       when is_binary(data) and is_binary(mime),
       do: {:media, :audio, mime, data, "audio"}

  defp content_part(%{"type" => "resource_link", "uri" => uri} = link) when is_binary(uri) do
    name = if is_binary(link["name"]), do: link["name"] <> " ", else: ""
    mime = if is_binary(link["mimeType"]), do: " (#{link["mimeType"]})", else: ""
    {:text, "[resource] #{name}<#{uri}>#{mime}"}
  end

  defp content_part(%{"type" => "resource", "resource" => %{"uri" => uri} = resource})
       when is_binary(uri) do
    mime = if is_binary(resource["mimeType"]), do: resource["mimeType"], else: nil

    case resource do
      %{"text" => text} when is_binary(text) ->
        {:text, "[resource: #{uri}#{if mime, do: " (#{mime})", else: ""}]\n" <> text}

      %{"blob" => blob} when is_binary(blob) ->
        {:media, :blob, mime || "application/octet-stream", blob, uri}

      _ ->
        {:text, "[resource: #{uri}]"}
    end
  end

  defp content_part(%{"type" => type}) when is_binary(type),
    do: {:text, "[unsupported content: #{String.slice(type, 0, 64)}]"}

  defp content_part(_other), do: {:text, "[unsupported content]"}

  @doc """
  The text that stands in for media a provider cannot take, for example
  `"[image: image/svg+xml, 1024 bytes]"`.
  """
  @spec placeholder(part()) :: String.t()
  def placeholder({:media, :blob, mime, data, uri}),
    do: "[resource: #{uri} (#{mime}), #{decoded_size(data)} bytes]"

  def placeholder({:media, _kind, mime, data, label}),
    do: "[#{label}: #{mime}, #{decoded_size(data)} bytes]"

  defp decoded_size(b64) do
    padding =
      cond do
        String.ends_with?(b64, "==") -> 2
        String.ends_with?(b64, "=") -> 1
        true -> 0
      end

    max(div(byte_size(b64) * 3, 4) - padding, 0)
  end

  @doc """
  Renders parts as plain text: text parts verbatim, media as placeholders,
  joined by blank lines.
  """
  @spec to_text([part()]) :: String.t()
  def to_text(parts) do
    Enum.map_join(parts, "\n\n", fn
      {:text, text} -> text
      media -> placeholder(media)
    end)
  end

  @doc "Error text for a tool name the model invented (HB-2)."
  @spec unknown_tool_text(term()) :: String.t()
  def unknown_tool_text(name) when is_binary(name) do
    shown =
      name |> String.replace_invalid() |> String.replace(@invisible, "") |> String.slice(0, 128)

    "Error: unknown tool #{inspect(shown)}. Only the tools listed in this request can be called."
  end

  def unknown_tool_text(_name), do: "Error: the tool call has no valid tool name."

  @doc "Error text for a call whose arguments are not a JSON object."
  @spec invalid_arguments_text() :: String.t()
  def invalid_arguments_text, do: "Error: the tool arguments must be a JSON object."
end
