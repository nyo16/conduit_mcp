defmodule ConduitMcp.Headers do
  @moduledoc """
  HTTP request-metadata header codec for the MCP 2026-07-28 Streamable HTTP
  transport.

  The transport mirrors selected JSON-RPC body fields into HTTP headers so
  intermediaries can route requests without parsing the body:

    * `Mcp-Method` — the request `method`, on every request.
    * `Mcp-Name` — `params.name` for `tools/call` and `prompts/get`,
      `params.uri` for `resources/read`, and `params.taskId` for the tasks
      extension's `tasks/get`, `tasks/update` and `tasks/cancel`
      ([ext-tasks routing headers](https://github.com/modelcontextprotocol/ext-tasks/blob/main/specification/2026-07-28/tasks.md#streamable-http-routing-headers)).
    * `Mcp-Param-{Name}` — tool arguments whose `inputSchema` property carries
      an `"x-mcp-header": "{Name}"` annotation.

  This module is pure: it builds those headers for a client, validates
  `x-mcp-header` annotations, and lets a server decode header values and
  compare them to body values. Header names it returns are lowercase, matching
  how Plug normalizes request header names.

  ## Value encoding

  Strings are sent as-is, integers as decimal, booleans as `true`/`false`.
  A string that is not plain header-safe ASCII — it contains a byte outside
  `0x20..0x7E` (non-ASCII, control characters including tab and DEL), has a
  leading or trailing space, or starts with `=?` and ends with `?=` (so it
  could be mistaken for the sentinel) — is sent as
  `=?base64?{standard padded Base64 of its UTF-8 bytes}?=`.

  Integer comparison is numeric and strict: a header matches an integer body
  value only when it is a canonical decimal integer (optional `-`, no leading
  zeros other than `"0"` itself, no `"-0"`) within the JavaScript safe range
  `-(2^53 - 1)..(2^53 - 1)`. Body values `42` and `42.0` both match `"42"`.
  """

  @sentinel_prefix "=?base64?"
  @sentinel_suffix "?="
  @max_safe_integer 9_007_199_254_740_991
  @allowed_types ["string", "integer", "boolean"]
  @name_methods %{
    "tools/call" => "name",
    "prompts/get" => "name",
    "resources/read" => "uri",
    "tasks/get" => "taskId",
    "tasks/update" => "taskId",
    "tasks/cancel" => "taskId"
  }

  @typedoc "An `x-mcp-header` annotation reachable from the schema root."
  @type header_param :: %{header: String.t(), path: [String.t()], type: String.t()}

  @doc """
  Encodes a string, integer, or boolean as a header value.

  Strings that are not plain header-safe ASCII are wrapped in the
  `=?base64?...?=` sentinel; see the module documentation.
  """
  @spec encode_value(String.t() | integer() | boolean()) :: String.t()
  def encode_value(true), do: "true"
  def encode_value(false), do: "false"
  def encode_value(value) when is_integer(value), do: Integer.to_string(value)

  def encode_value(value) when is_binary(value) do
    if plain?(value) do
      value
    else
      @sentinel_prefix <> Base.encode64(value) <> @sentinel_suffix
    end
  end

  @doc """
  Decodes a received header value.

  A value that starts with `=?base64?` and ends with `?=` must carry valid,
  padded standard Base64 of valid UTF-8 and decodes to that string; anything
  else in that shape returns `:error`. Every other value is returned unchanged.
  """
  @spec decode_value(String.t()) :: {:ok, String.t()} | :error
  def decode_value(@sentinel_prefix <> rest = value) do
    if String.ends_with?(value, @sentinel_suffix) do
      decode_sentinel(rest)
    else
      {:ok, value}
    end
  end

  def decode_value(value) when is_binary(value), do: {:ok, value}

  defp decode_sentinel(rest) do
    payload_size = byte_size(rest) - byte_size(@sentinel_suffix)

    with true <- payload_size >= 0,
         {:ok, decoded} <- Base.decode64(binary_part(rest, 0, payload_size)),
         true <- String.valid?(decoded) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  @doc """
  Returns the `Mcp-Method` header for a request method.
  """
  @spec method_header(String.t()) :: {String.t(), String.t()}
  def method_header(method) when is_binary(method), do: {"mcp-method", method}

  @doc """
  Returns the `Mcp-Name` header for a request, or `nil` when none applies.

  Only `tools/call` and `prompts/get` (from `params["name"]`),
  `resources/read` (from `params["uri"]`) and the tasks extension's
  `tasks/get|update|cancel` (from `params["taskId"]`) carry the header, and
  only when that param is a string. The value is encoded with
  `encode_value/1`.
  """
  @spec name_header(String.t(), map()) :: {String.t(), String.t()} | nil
  def name_header(method, params) when is_map(params) do
    with {:ok, key} <- Map.fetch(@name_methods, method),
         value when is_binary(value) <- Map.get(params, key) do
      {"mcp-name", encode_value(value)}
    else
      _ -> nil
    end
  end

  def name_header(_method, _params), do: nil

  @doc """
  Returns whether requests with `method` must carry an `Mcp-Name` header.
  """
  @spec name_header_required?(String.t()) :: boolean()
  def name_header_required?(method), do: Map.has_key?(@name_methods, method)

  @doc """
  The `params` key `Mcp-Name` mirrors for `method` (`"name"`, `"uri"` or
  `"taskId"`), or `nil` when the method carries no `Mcp-Name`.
  """
  @spec name_param(String.t()) :: String.t() | nil
  def name_param(method), do: Map.get(@name_methods, method)

  @doc """
  Lists the `x-mcp-header` annotations reachable from the root of an
  `inputSchema` through chains of `properties` keys only.

  Each entry has the declared `header` Name as written, the property-key
  `path` from the root, and the property's declared `type`. Annotations whose
  Name or `type` is not a string are left out; `validate_x_mcp_header/1`
  reports those. Entries are ordered by path.
  """
  @spec header_params(map()) :: [header_param()]
  def header_params(schema) when is_map(schema), do: collect_params(schema, [])

  def header_params(_schema), do: []

  defp collect_params(schema, path) do
    case Map.get(schema, "properties") do
      properties when is_map(properties) ->
        properties
        |> Enum.sort_by(fn {key, _} -> key end)
        |> Enum.flat_map(fn
          {key, property} when is_map(property) -> param_entry(property, path ++ [key])
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp param_entry(property, path) do
    own =
      case property do
        %{"x-mcp-header" => header, "type" => type} when is_binary(header) and is_binary(type) ->
          [%{header: header, path: path, type: type}]

        _ ->
          []
      end

    own ++ collect_params(property, path)
  end

  @doc """
  Builds the `Mcp-Param-{Name}` headers for a tool call.

  `tool_or_schema` is a tool definition (with `"inputSchema"`) or an
  `inputSchema` itself; `args` are the string-keyed call arguments. A header
  is produced for each annotation from `header_params/1` whose argument value
  at `path` is a string, integer, boolean, or integral float (`42.0` encodes
  as `"42"`). Absent and `nil` values, and values of any other type, produce
  no header. Header names are `"mcp-param-"` followed by the lowercased Name.
  """
  @spec param_headers(map(), map()) :: [{String.t(), String.t()}]
  def param_headers(tool_or_schema, args) when is_map(tool_or_schema) and is_map(args) do
    schema =
      case tool_or_schema do
        %{"inputSchema" => schema} when is_map(schema) -> schema
        schema -> schema
      end

    schema
    |> header_params()
    |> Enum.flat_map(fn %{header: header, path: path} ->
      case header_value(fetch_path(args, path)) do
        nil -> []
        value -> [{"mcp-param-" <> String.downcase(header, :ascii), value}]
      end
    end)
  end

  defp fetch_path(value, []), do: value

  defp fetch_path(map, [key | rest]) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> fetch_path(value, rest)
      :error -> nil
    end
  end

  defp fetch_path(_value, _path), do: nil

  defp header_value(value) when is_binary(value) or is_integer(value) or is_boolean(value),
    do: encode_value(value)

  defp header_value(value) when is_float(value) do
    integer = trunc(value)
    if integer == value, do: encode_value(integer)
  end

  defp header_value(_value), do: nil

  @doc """
  Validates every `x-mcp-header` annotation in an `inputSchema`.

  The whole schema is searched, including `items`, composition keywords and
  `$defs`. Each annotation must:

    * sit on a property reachable from the root through `properties` keys only;
    * be on a property whose `"type"` is `"string"`, `"integer"` or `"boolean"`;
    * be a non-empty RFC 9110 token (which excludes CR and LF);
    * be unique, compared case-insensitively, within the schema.

  Errors name the annotation and its JSON Pointer location, never argument
  values.
  """
  @spec validate_x_mcp_header(map()) :: :ok | {:error, [String.t()]}
  def validate_x_mcp_header(schema) when is_map(schema) do
    annotations = walk(schema, true, [])

    errors =
      Enum.flat_map(annotations, &annotation_errors/1) ++ duplicate_errors(annotations)

    if errors == [], do: :ok, else: {:error, errors}
  end

  # Collects {name, pointer_segments, reachable?, property} for every map
  # carrying "x-mcp-header". `reachable?` is true only for the root and for
  # schemas reached from it purely through "properties" maps.
  defp walk(map, reachable?, path) when is_map(map) do
    own =
      case Map.fetch(map, "x-mcp-header") do
        {:ok, name} -> [{name, path, reachable? and path != [], map}]
        :error -> []
      end

    nested =
      map
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.flat_map(fn
        {"x-mcp-header", _} ->
          []

        {"properties", properties} when is_map(properties) ->
          properties
          |> Enum.sort_by(fn {key, _} -> key end)
          |> Enum.flat_map(fn {key, property} ->
            walk(property, reachable?, path ++ ["properties", key])
          end)

        {key, value} ->
          walk(value, false, path ++ [to_string(key)])
      end)

    own ++ nested
  end

  defp walk(list, _reachable?, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      walk(value, false, path ++ [Integer.to_string(index)])
    end)
  end

  defp walk(_value, _reachable?, _path), do: []

  defp annotation_errors({name, path, reachable?, property}) do
    location = pointer(path)
    label = "x-mcp-header #{inspect(name)} at #{location}"

    [
      name_error(name, location),
      if(not reachable?,
        do: "#{label} is not statically reachable from the schema root through properties keys"
      ),
      type_error(Map.get(property, "type"), label)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp name_error(name, location) when not is_binary(name),
    do: "x-mcp-header at #{location} must be a string"

  defp name_error("", location), do: "x-mcp-header at #{location} must not be empty"

  defp name_error(name, location) do
    cond do
      String.contains?(name, ["\r", "\n"]) ->
        "x-mcp-header #{inspect(name)} at #{location} must not contain CR or LF"

      not token?(name) ->
        "x-mcp-header #{inspect(name)} at #{location} is not a valid HTTP field-name token"

      true ->
        nil
    end
  end

  defp type_error(type, _label) when type in @allowed_types, do: nil

  defp type_error(type, label),
    do:
      "#{label} must be on a property of type \"string\", \"integer\" or \"boolean\", got #{inspect(type)}"

  defp duplicate_errors(annotations) do
    annotations
    |> Enum.filter(fn {name, _, _, _} -> is_binary(name) end)
    |> Enum.group_by(fn {name, _, _, _} -> String.downcase(name, :ascii) end)
    |> Enum.filter(fn {_, group} -> length(group) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {_, group} ->
      described =
        Enum.map_join(group, ", ", fn {name, path, _, _} ->
          "#{inspect(name)} at #{pointer(path)}"
        end)

      "duplicate x-mcp-header name (case-insensitive): #{described}"
    end)
  end

  defp token?(name) do
    name |> :binary.bin_to_list() |> Enum.all?(&tchar?/1)
  end

  defp tchar?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9, do: true
  defp tchar?(c), do: c in ~c"!#$%&'*+-.^_`|~"

  defp pointer(path) do
    "#" <>
      Enum.map_join(path, fn segment ->
        "/" <> (segment |> String.replace("~", "~0") |> String.replace("/", "~1"))
      end)
  end

  @doc """
  Compares a decoded header value to the corresponding body value.

  Strings compare exactly and booleans against `"true"`/`"false"`. Integers
  and floats compare numerically against a canonical decimal integer header
  within the JavaScript safe range (`"42"` matches `42` and `42.0`; `"042"`,
  `"-0"`, `"+1"` and `"42.0"` match nothing). Any other body value, including
  `nil`, never matches.
  """
  @spec value_matches?(String.t(), term()) :: boolean()
  def value_matches?(header, body) when is_binary(header) and is_binary(body), do: header == body
  def value_matches?("true", true), do: true
  def value_matches?("false", false), do: true

  def value_matches?(header, body) when is_binary(header) and is_number(body) do
    case parse_safe_integer(header) do
      {:ok, integer} -> integer == body
      :error -> false
    end
  end

  def value_matches?(_header, _body), do: false

  # 2^53 - 1 has 16 digits; a sign makes 17 bytes.
  defp parse_safe_integer(header) when byte_size(header) <= 17 do
    with true <- canonical_integer?(header),
         {integer, ""} <- Integer.parse(header),
         true <- integer >= -@max_safe_integer and integer <= @max_safe_integer do
      {:ok, integer}
    else
      _ -> :error
    end
  end

  defp parse_safe_integer(_header), do: :error

  defp canonical_integer?("0"), do: true
  defp canonical_integer?("-" <> digits), do: positive_digits?(digits)
  defp canonical_integer?(digits), do: positive_digits?(digits)

  defp positive_digits?(<<first, rest::binary>>) when first in ?1..?9,
    do: rest |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9))

  defp positive_digits?(_), do: false

  defp plain?(value) do
    printable_ascii?(value) and not edge_space?(value) and not sentinel_like?(value)
  end

  defp printable_ascii?(<<>>), do: true
  defp printable_ascii?(<<c, rest::binary>>) when c in 0x20..0x7E, do: printable_ascii?(rest)
  defp printable_ascii?(_), do: false

  defp edge_space?(value),
    do: String.starts_with?(value, " ") or String.ends_with?(value, " ")

  defp sentinel_like?(value),
    do: String.starts_with?(value, "=?") and String.ends_with?(value, @sentinel_suffix)
end
