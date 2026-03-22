# Shared setup for all benchmark files.
# Each benchmark file should: Code.require_file("bench/bench_helper.exs")

# Compile bench support modules
Code.compile_file("bench/support/bench_servers.ex")

# Ensure the app is started (needed for Application.get_env, telemetry, etc.)
Application.ensure_all_started(:conduit_mcp)

# Configure validation
Application.put_env(:conduit_mcp, :validation,
  runtime_validation: true,
  type_coercion: true,
  log_validation_errors: false
)

# Ensure output directory exists
File.mkdir_p!("bench/output")

# --- Fixtures ---

defmodule Bench.Fixtures do
  @moduledoc false

  def tool_call_request(tool_name, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => params}
    }
  end

  def resource_read_request(uri) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "resources/read",
      "params" => %{"uri" => uri}
    }
  end

  def prompt_get_request(name, args) do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "prompts/get",
      "params" => %{"name" => name, "arguments" => args}
    }
  end

  def ping_request do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping", "params" => %{}}
  end

  def list_tools_request do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}
  end

  def list_resources_request do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/list", "params" => %{}}
  end

  def list_prompts_request do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => "prompts/list", "params" => %{}}
  end

  def small_params, do: %{"message" => "hello world"}

  def medium_params do
    %{
      "name" => "Alice Smith",
      "email" => "alice@example.com",
      "age" => "30",
      "role" => "admin",
      "active" => "true"
    }
  end

  def large_params do
    Enum.into(1..20, %{}, fn i -> {"field_#{i}", "value_#{i}"} end)
  end

  def fake_conn do
    %Plug.Conn{
      private: %{server_name: "bench", server_version: "1.0"},
      assigns: %{}
    }
  end
end

# --- Alternative implementations for comparison benchmarks ---

defmodule Bench.Alternatives do
  @moduledoc false

  # --- Key Conversion Alternatives ---

  # Current approach (replicated from Validation since it's private)
  def convert_keys_to_atoms(map) when is_map(map) do
    for {key, value} <- map, into: %{} do
      atom_key = if is_binary(key), do: String.to_atom(key), else: key
      {atom_key, convert_keys_to_atoms(value)}
    end
  end

  def convert_keys_to_atoms(value), do: value

  # Alternative: String.to_existing_atom (requires atoms pre-created)
  def convert_keys_to_existing_atoms(map) when is_map(map) do
    for {key, value} <- map, into: %{} do
      atom_key = if is_binary(key), do: String.to_existing_atom(key), else: key
      {atom_key, convert_keys_to_existing_atoms(value)}
    end
  end

  def convert_keys_to_existing_atoms(value), do: value

  # Alternative: pre-built key map lookup
  def convert_with_key_map(map, key_map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      case Map.get(key_map, k) do
        nil -> {k, v}
        atom_key -> {atom_key, v}
      end
    end)
  end

  # --- Constraint Validation Alternatives ---

  # Current: 4 separate passes (replicated)
  def validate_four_passes(params, schema) do
    with {:ok, params} <- validate_enum_pass(params, schema),
         {:ok, params} <- validate_numeric_pass(params, schema),
         {:ok, params} <- validate_string_length_pass(params, schema) do
      {:ok, params}
    end
  end

  # Alternative: single pass over schema
  def validate_single_pass(params, schema) do
    Enum.reduce_while(schema, {:ok, params}, fn {param_name, param_opts}, {:ok, acc} ->
      value = Map.get(acc, param_name)

      if value == nil do
        {:cont, {:ok, acc}}
      else
        with :ok <- check_enum(param_name, value, param_opts),
             :ok <- check_numeric(param_name, value, param_opts),
             :ok <- check_string_length(param_name, value, param_opts) do
          {:cont, {:ok, acc}}
        else
          {:error, err} -> {:halt, {:error, [err]}}
        end
      end
    end)
  end

  defp check_enum(param_name, value, opts) do
    enum_values = Keyword.get(opts, :__enum_values__) || Keyword.get(opts, :enum)

    case enum_values do
      nil ->
        :ok

      vals ->
        if value in vals do
          :ok
        else
          {:error,
           %{
             parameter: to_string(param_name),
             value: value,
             message: "must be one of #{inspect(vals)}"
           }}
        end
    end
  end

  defp check_numeric(param_name, value, opts) when is_number(value) do
    min_val = Keyword.get(opts, :__min_value__) || Keyword.get(opts, :min)
    max_val = Keyword.get(opts, :__max_value__) || Keyword.get(opts, :max)

    cond do
      min_val != nil and value < min_val ->
        {:error,
         %{parameter: to_string(param_name), value: value, message: "must be >= #{min_val}"}}

      max_val != nil and value > max_val ->
        {:error,
         %{parameter: to_string(param_name), value: value, message: "must be <= #{max_val}"}}

      true ->
        :ok
    end
  end

  defp check_numeric(_name, _value, _opts), do: :ok

  defp check_string_length(param_name, value, opts) when is_binary(value) do
    min_len = Keyword.get(opts, :__min_length__) || Keyword.get(opts, :min_length)
    max_len = Keyword.get(opts, :__max_length__) || Keyword.get(opts, :max_length)

    cond do
      min_len != nil and byte_size(value) < min_len ->
        {:error, %{parameter: to_string(param_name), value: value, message: "too short"}}

      max_len != nil and byte_size(value) > max_len ->
        {:error, %{parameter: to_string(param_name), value: value, message: "too long"}}

      true ->
        :ok
    end
  end

  defp check_string_length(_name, _value, _opts), do: :ok

  # Replicated 4-pass helpers
  defp validate_enum_pass(params, schema) do
    Enum.reduce_while(schema, {:ok, params}, fn {param_name, param_opts}, {:ok, acc} ->
      enum_values = Keyword.get(param_opts, :__enum_values__) || Keyword.get(param_opts, :enum)

      case enum_values do
        nil ->
          {:cont, {:ok, acc}}

        vals ->
          value = Map.get(acc, param_name)

          if value == nil or value in vals do
            {:cont, {:ok, acc}}
          else
            {:halt,
             {:error, [%{parameter: to_string(param_name), value: value, message: "not in enum"}]}}
          end
      end
    end)
  end

  defp validate_numeric_pass(params, schema) do
    Enum.reduce_while(schema, {:ok, params}, fn {param_name, param_opts}, {:ok, acc} ->
      value = Map.get(acc, param_name)

      if value == nil do
        {:cont, {:ok, acc}}
      else
        case check_numeric(param_name, value, param_opts) do
          :ok -> {:cont, {:ok, acc}}
          {:error, err} -> {:halt, {:error, [err]}}
        end
      end
    end)
  end

  defp validate_string_length_pass(params, schema) do
    Enum.reduce_while(schema, {:ok, params}, fn {param_name, param_opts}, {:ok, acc} ->
      value = Map.get(acc, param_name)

      if value == nil do
        {:cont, {:ok, acc}}
      else
        case check_string_length(param_name, value, param_opts) do
          :ok -> {:cont, {:ok, acc}}
          {:error, err} -> {:halt, {:error, [err]}}
        end
      end
    end)
  end

  # --- Marker Removal Alternatives ---

  @custom_markers [
    :__enum_values__,
    :__min_value__,
    :__max_value__,
    :__min_length__,
    :__max_length__,
    :validator,
    :min,
    :max,
    :min_length,
    :max_length,
    :enum
  ]

  # Current: Enum.reduce over markers
  def remove_markers_reduce(schema) do
    Enum.map(schema, fn {param_name, param_opts} ->
      clean_opts =
        Enum.reduce(@custom_markers, param_opts, fn marker, acc ->
          Keyword.delete(acc, marker)
        end)

      {param_name, clean_opts}
    end)
  end

  # Alternative: Keyword.drop/2
  def remove_markers_drop(schema) do
    Enum.map(schema, fn {param_name, param_opts} ->
      {param_name, Keyword.drop(param_opts, @custom_markers)}
    end)
  end

  # --- URI Template Alternatives ---

  # Pre-compiled regex approach
  def precompile_uri_template(template) do
    param_names =
      Regex.scan(~r/\{([^}]+)\}/, template)
      |> Enum.map(fn [_full, name] -> name end)

    template_with_tokens = Regex.replace(~r/\{[^}]+\}/, template, "<<<PARAM>>>")
    escaped = Regex.escape(template_with_tokens)
    pattern = String.replace(escaped, "<<<PARAM>>>", "([^/]+)")
    {:ok, regex} = Regex.compile("^#{pattern}$")

    {param_names, regex}
  end

  def extract_with_precompiled(uri, {param_names, regex}) do
    case Regex.run(regex, uri) do
      nil -> :no_match
      [_full | values] -> {:ok, Enum.zip(param_names, values) |> Map.new()}
    end
  end

  # String.split approach for simple URIs
  def extract_with_split(template, uri) do
    template_parts = String.split(template, ~r/\{[^}]+\}/)

    param_names =
      Regex.scan(~r/\{([^}]+)\}/, template)
      |> Enum.map(fn [_, name] -> name end)

    remaining = extract_between_parts(uri, template_parts, [])

    case remaining do
      :no_match ->
        :no_match

      values when length(values) == length(param_names) ->
        {:ok, Enum.zip(param_names, values) |> Map.new()}

      _ ->
        :no_match
    end
  end

  defp extract_between_parts(str, [part], acc) do
    if String.ends_with?(str, part) do
      value = String.slice(str, 0, byte_size(str) - byte_size(part))
      Enum.reverse([value | acc])
    else
      if part == "" do
        Enum.reverse([str | acc])
      else
        :no_match
      end
    end
  end

  defp extract_between_parts(str, [part | rest], acc) do
    case String.split(str, part, parts: 2) do
      [value, remainder] ->
        if acc == [] and value == "" do
          extract_between_parts(remainder, rest, acc)
        else
          extract_between_parts(remainder, rest, [value | acc])
        end

      _ ->
        :no_match
    end
  end

  defp extract_between_parts(_, [], acc), do: Enum.reverse(acc)
end
