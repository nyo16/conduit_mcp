defmodule ConduitMcp.Client.Input.Elicitation do
  @moduledoc false

  # Pure checks around `elicitation/create` (SC-3, SC-4):
  #
  #   * `check_schema/1` - a form's `requestedSchema` must be the spec's flat
  #     primitive subset: an object whose properties are strings (with
  #     length, format, `enum`, titled `oneOf`), numbers, integers, booleans,
  #     or arrays of string enums (multi-select). No nesting, no `$ref`, no
  #     keyword outside the subset. It also flags secret-looking fields.
  #   * `check_content/2` - a form `accept` answer must fit that schema
  #     before it is sent.
  #   * `check_url/2` - a URL-mode request must carry an absolute `https`
  #     URL without userinfo. Nothing here fetches or resolves it.

  @string_formats ["email", "uri", "date", "date-time"]
  @annotations ["title", "description", "default"]

  @allowed %{
    "string" => ["minLength", "maxLength", "format", "enum", "enumNames", "oneOf"],
    "number" => ["minimum", "maximum"],
    "integer" => ["minimum", "maximum"],
    "boolean" => [],
    "array" => ["items", "minItems", "maxItems"]
  }

  # Field names, titles or descriptions that suggest a credential: the host
  # should not let a user type a secret into a server's form.
  @sensitive ~r/pass(word|wd|phrase|code)?|secret|token|api[-_ ]?key|private[-_ ]?key|credential|ssn|social[-_ ]?security|credit[-_ ]?card|card[-_ ]?number|cvv|cvc|\bpin\b|\botp\b|one[-_ ]?time/i

  @type fields :: %{String.t() => %{sensitive_suspected: boolean()}}

  @doc "Checks a form `requestedSchema`; returns per-field flags."
  @spec check_schema(term()) :: {:ok, fields()} | {:error, String.t()}
  def check_schema(%{"type" => "object", "properties" => properties} = schema)
      when is_map(properties) do
    required = Map.get(schema, "required", [])

    cond do
      Map.has_key?(schema, "$ref") or Map.has_key?(schema, "$defs") ->
        {:error, "requestedSchema must not use references"}

      not (is_list(required) and Enum.all?(required, &Map.has_key?(properties, &1))) ->
        {:error, "requestedSchema required names unknown properties"}

      true ->
        Enum.reduce_while(properties, {:ok, %{}}, fn {name, property}, {:ok, acc} ->
          if primitive?(property) do
            {:cont, {:ok, Map.put(acc, name, %{sensitive_suspected: sensitive?(name, property)})}}
          else
            {:halt, {:error, "requestedSchema property is outside the primitive subset"}}
          end
        end)
    end
  end

  def check_schema(_schema),
    do: {:error, "requestedSchema must be an object schema with properties"}

  defp primitive?(%{"type" => type} = property) when is_map_key(@allowed, type) do
    allowed = @annotations ++ Map.fetch!(@allowed, type) ++ ["type"]

    Enum.all?(Map.keys(property), &(&1 in allowed)) and valid_keywords?(type, property)
  end

  defp primitive?(_property), do: false

  defp valid_keywords?("string", property) do
    non_neg?(property["minLength"]) and non_neg?(property["maxLength"]) and
      (property["format"] == nil or property["format"] in @string_formats) and
      optional_strings?(property["enum"]) and optional_strings?(property["enumNames"]) and
      optional_consts?(property["oneOf"])
  end

  defp valid_keywords?(type, property) when type in ["number", "integer"],
    do: optional_number?(property["minimum"]) and optional_number?(property["maximum"])

  defp valid_keywords?("boolean", property),
    do: property["default"] == nil or is_boolean(property["default"])

  defp valid_keywords?("array", %{"items" => items} = property) do
    non_neg?(property["minItems"]) and non_neg?(property["maxItems"]) and
      case items do
        %{"type" => "string", "enum" => enum} = items when map_size(items) == 2 -> strings?(enum)
        %{"anyOf" => consts} when map_size(items) == 1 -> consts?(consts)
        _other -> false
      end
  end

  defp valid_keywords?("array", _property), do: false

  defp non_neg?(nil), do: true
  defp non_neg?(value), do: is_integer(value) and value >= 0

  defp optional_number?(value), do: value == nil or is_number(value)
  defp optional_strings?(value), do: value == nil or strings?(value)
  defp optional_consts?(value), do: value == nil or consts?(value)

  defp strings?(list), do: is_list(list) and list != [] and Enum.all?(list, &is_binary/1)

  defp consts?(list) do
    is_list(list) and list != [] and
      Enum.all?(list, fn
        %{"const" => const} = entry when is_binary(const) ->
          Enum.all?(Map.keys(entry), &(&1 in ["const", "title"]))

        _other ->
          false
      end)
  end

  defp sensitive?(name, property) do
    [name, property["title"], property["description"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.any?(&Regex.match?(@sensitive, &1))
  end

  @doc "Checks the `content` of a form `accept` against the (checked) schema."
  @spec check_content(term(), map()) :: :ok | {:error, String.t()}
  def check_content(content, %{"properties" => properties} = schema) when is_map(content) do
    required = Map.get(schema, "required", [])

    cond do
      Enum.any?(Map.keys(content), &(not Map.has_key?(properties, &1))) ->
        {:error, "content has a field the schema does not define"}

      Enum.any?(required, &(not Map.has_key?(content, &1))) ->
        {:error, "content lacks a required field"}

      Enum.all?(content, fn {name, value} -> fits?(value, properties[name]) end) ->
        :ok

      true ->
        {:error, "content does not match the schema"}
    end
  end

  def check_content(_content, _schema), do: {:error, "content must be an object"}

  defp fits?(value, %{"type" => "string"} = property) when is_binary(value) do
    length = String.length(value)

    length >= (property["minLength"] || 0) and
      (property["maxLength"] == nil or length <= property["maxLength"]) and
      member?(value, property["enum"], property["oneOf"])
  end

  defp fits?(value, %{"type" => "number"} = property) when is_number(value),
    do: within?(value, property)

  defp fits?(value, %{"type" => "integer"} = property) when is_integer(value),
    do: within?(value, property)

  defp fits?(value, %{"type" => "boolean"}) when is_boolean(value), do: true

  defp fits?(values, %{"type" => "array", "items" => items} = property) when is_list(values) do
    count = length(values)

    count >= (property["minItems"] || 0) and
      (property["maxItems"] == nil or count <= property["maxItems"]) and
      Enum.all?(values, &(is_binary(&1) and member?(&1, items["enum"], items["anyOf"])))
  end

  defp fits?(_value, _property), do: false

  defp within?(value, property) do
    (property["minimum"] == nil or value >= property["minimum"]) and
      (property["maximum"] == nil or value <= property["maximum"])
  end

  defp member?(_value, nil, nil), do: true
  defp member?(value, enum, nil), do: value in enum
  defp member?(value, nil, consts), do: Enum.any?(consts, &(&1["const"] == value))
  defp member?(value, enum, consts), do: value in enum or member?(value, nil, consts)

  @doc """
  Checks a URL-mode `url`: absolute `https` with a host and no userinfo.
  Returns what the handler is told about it. `origin` is the server's
  origin when known; any other origin, or no known origin, is a mismatch.
  """
  @spec check_url(term(), String.t() | nil) ::
          {:ok,
           %{url: String.t(), host: String.t(), idn?: boolean(), origin_mismatch?: boolean()}}
          | {:error, String.t()}
  def check_url(url, origin) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        if String.downcase(scheme) == "https" do
          host = String.downcase(host)

          {:ok,
           %{url: url, host: host, idn?: idn?(host), origin_mismatch?: mismatch?(uri, origin)}}
        else
          {:error, "elicitation URL must use https"}
        end

      _other ->
        {:error, "elicitation URL must be an absolute https URL"}
    end
  end

  def check_url(_url, _origin), do: {:error, "elicitation URL must be a string"}

  # Punycode labels may render as a look-alike host. (A raw non-ASCII host
  # never gets here: `URI.new/1` refuses it.)
  defp idn?(host), do: host |> String.split(".") |> Enum.any?(&String.starts_with?(&1, "xn--"))

  defp mismatch?(_uri, nil), do: true

  defp mismatch?(uri, origin) do
    case URI.new(origin) do
      {:ok, %URI{scheme: scheme, host: host, port: port}}
      when is_binary(scheme) and is_binary(host) ->
        {String.downcase(scheme), String.downcase(host), port} !=
          {String.downcase(uri.scheme), String.downcase(uri.host), uri.port}

      _other ->
        true
    end
  end
end
