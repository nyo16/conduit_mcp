defmodule ConduitMcp.Endpoint do
  @moduledoc """
  Aggregates `ConduitMcp.Component` modules into a full MCP server.

  The Endpoint implements the `ConduitMcp.Server` behaviour by generating
  all required callbacks at compile time from registered components.
  It also carries declarative configuration for rate limiting, message
  limiting, and authentication that transports auto-extract.

  ## Example

      defmodule MyApp.MCPServer do
        use ConduitMcp.Endpoint,
          name: "My Server",
          version: "1.0.0",
          rate_limit: [backend: MyApp.RateLimiter, limit: 60, scale: 60_000],
          message_rate_limit: [backend: MyApp.RateLimiter, limit: 50, scale: 300_000]

        component MyApp.Echo
        component MyApp.ReadUser
        component MyApp.CodeReviewPrompt
      end

  Then wire it up with a transport — the Endpoint config is auto-extracted:

      {Bandit,
       plug: {ConduitMcp.Transport.StreamableHTTP, server_module: MyApp.MCPServer},
       port: 4001}

  ## Options

  - `:name` — Server name for the MCP `initialize` response
  - `:version` — Server version for the MCP `initialize` response
  - `:rate_limit` — HTTP rate limiting config (same format as transport opts)
  - `:message_rate_limit` — Message-level rate limiting config
  - `:auth` — Authentication config (same format as transport opts)

  ## How It Works

  At compile time, the `@before_compile` hook:

  1. Validates all registered components (existence, uniqueness, types)
  2. Groups components by type (tool, resource, prompt)
  3. Generates all `ConduitMcp.Server` callbacks:
     - `handle_list_tools/1`, `handle_call_tool/3`
     - `handle_list_resources/1`, `handle_read_resource/2`
     - `handle_list_prompts/1`, `handle_get_prompt/3`
  4. Generates validation schema lookups for the existing validation pipeline
  5. Generates `__endpoint_config__/0` for transport auto-extraction
  6. Generates `__capabilities__/0` for selective capability advertisement

  Because the Endpoint implements `ConduitMcp.Server`, it works with the
  existing `ConduitMcp.Handler` and all transports without modification.
  """

  @doc """
  Registers a component module with the endpoint.

  The component must `use ConduitMcp.Component` and implement `execute/2`.

  ## Examples

      component MyApp.Echo
      component MyApp.ReadUser
      component MyApp.CodeReviewPrompt
  """
  defmacro component(module) do
    quote do
      @endpoint_components unquote(module)
    end
  end

  defmacro __using__(opts) do
    quote do
      @behaviour ConduitMcp.Server

      import ConduitMcp.Endpoint, only: [component: 1]

      Module.register_attribute(__MODULE__, :endpoint_components, accumulate: true)
      @endpoint_opts unquote(opts)

      @before_compile ConduitMcp.Endpoint
    end
  end

  defmacro __before_compile__(env) do
    module = env.module
    components = Module.get_attribute(module, :endpoint_components) || []
    opts = Module.get_attribute(module, :endpoint_opts) || []

    # Ensure all component modules are compiled and valid
    components = Enum.reverse(components)
    validate_components!(components, module)

    # Group by type
    tools = Enum.filter(components, &(&1.__component_type__() == :tool))
    resources = Enum.filter(components, &(&1.__component_type__() == :resource))
    prompts = Enum.filter(components, &(&1.__component_type__() == :prompt))

    # Check for name conflicts
    validate_no_name_conflicts!(tools, :tool, module)
    validate_no_name_conflicts!(prompts, :prompt, module)

    # Collect schemas at compile time
    tool_schemas = Enum.map(tools, & &1.__component_schema__())
    resource_schemas = Enum.map(resources, & &1.__component_schema__())
    prompt_schemas = Enum.map(prompts, & &1.__component_schema__())

    # Build tool dispatch clauses
    tool_clauses = generate_tool_clauses(tools)
    prompt_clauses = generate_prompt_clauses(prompts)
    resource_clause = generate_resource_clause(resources)

    # Build validation schema lookups
    tool_validation_clauses = generate_tool_validation_clauses(tools)
    prompt_validation_clauses = generate_prompt_validation_clauses(prompts)

    # Build scope map
    scope_map = build_scope_map(tools)

    # Build key maps for atom conversion (one per component)
    tool_key_maps = build_key_maps(tools)
    prompt_key_maps = build_key_maps(prompts)

    # Build capabilities
    capabilities = build_capabilities(tools, resources, prompts)

    # Endpoint config for transport auto-extraction
    endpoint_config =
      opts
      |> Keyword.take([:name, :version, :rate_limit, :message_rate_limit, :auth])

    quote do
      # --- Tool callbacks ---

      def handle_list_tools(_conn) do
        {:ok, %{"tools" => unquote(Macro.escape(tool_schemas))}}
      end

      unquote(tool_clauses)

      def handle_call_tool(_conn, tool_name, _params) do
        {:error,
         %{
           "code" => ConduitMcp.Errors.method_not_found(),
           "message" => "Tool not found: #{tool_name}"
         }}
      end

      # --- Resource callbacks ---

      def handle_list_resources(_conn) do
        {:ok, %{"resources" => unquote(Macro.escape(resource_schemas))}}
      end

      unquote(resource_clause)

      # Only generate catch-all if no resources defined their own handler
      if unquote(is_nil(resource_clause)) do
        def handle_read_resource(_conn, uri) do
          {:error,
           %{
             "code" => ConduitMcp.Errors.resource_not_found(),
             "message" => "Resource not found: #{uri}"
           }}
        end
      end

      # --- Prompt callbacks ---

      def handle_list_prompts(_conn) do
        {:ok, %{"prompts" => unquote(Macro.escape(prompt_schemas))}}
      end

      unquote(prompt_clauses)

      def handle_get_prompt(_conn, prompt_name, _args) do
        {:error,
         %{
           "code" => ConduitMcp.Errors.method_not_found(),
           "message" => "Prompt not found: #{prompt_name}"
         }}
      end

      # --- Validation schema lookups ---

      unquote(tool_validation_clauses)

      def __validation_schema_for_tool__(_name), do: nil

      unquote(prompt_validation_clauses)

      def __validation_schema_for_prompt__(_name), do: nil

      # --- Scope lookup ---

      def __scope_for_tool__(tool_name) do
        Map.get(unquote(Macro.escape(scope_map)), tool_name)
      end

      # --- Key maps for atom conversion ---

      @__tool_key_maps unquote(Macro.escape(tool_key_maps))
      @__prompt_key_maps unquote(Macro.escape(prompt_key_maps))

      defp __convert_to_atom_keys__(component_name, params) do
        key_map =
          Map.get(@__tool_key_maps, component_name) ||
            Map.get(@__prompt_key_maps, component_name, %{})

        Map.new(params, fn {k, v} ->
          case Map.get(key_map, k) do
            nil -> {k, v}
            atom_key -> {atom_key, v}
          end
        end)
      end

      # --- Endpoint config ---

      def __endpoint_config__ do
        unquote(endpoint_config)
      end

      # --- Capabilities ---

      def __capabilities__ do
        unquote(Macro.escape(capabilities))
      end
    end
  end

  # --- Compile-time helpers ---

  defp validate_components!(components, endpoint_module) do
    Enum.each(components, fn mod ->
      case Code.ensure_compiled(mod) do
        {:module, ^mod} ->
          unless function_exported?(mod, :__component_type__, 0) do
            raise CompileError,
              description:
                "#{inspect(endpoint_module)}: #{inspect(mod)} is not a valid ConduitMcp.Component " <>
                  "(missing __component_type__/0). Did you forget `use ConduitMcp.Component`?"
          end

          unless function_exported?(mod, :execute, 2) do
            raise CompileError,
              description:
                "#{inspect(endpoint_module)}: #{inspect(mod)} does not implement execute/2"
          end

        {:error, reason} ->
          raise CompileError,
            description:
              "#{inspect(endpoint_module)}: could not compile component #{inspect(mod)}: #{inspect(reason)}"
      end
    end)
  end

  defp validate_no_name_conflicts!(components, type, endpoint_module) do
    names = Enum.map(components, & &1.__component_name__())
    duplicates = names -- Enum.uniq(names)

    unless Enum.empty?(duplicates) do
      raise CompileError,
        description:
          "#{inspect(endpoint_module)}: duplicate #{type} name(s): #{inspect(Enum.uniq(duplicates))}"
    end
  end

  defp generate_tool_clauses(tools) do
    Enum.map(tools, fn mod ->
      name = mod.__component_name__()

      quote do
        def handle_call_tool(conn, unquote(name), params) do
          atom_params = __convert_to_atom_keys__(unquote(name), params)
          unquote(mod).execute(atom_params, conn)
        end
      end
    end)
  end

  defp generate_prompt_clauses(prompts) do
    Enum.map(prompts, fn mod ->
      name = mod.__component_name__()

      quote do
        def handle_get_prompt(conn, unquote(name), args) do
          atom_args = __convert_to_atom_keys__(unquote(name), args)
          unquote(mod).execute(atom_args, conn)
        end
      end
    end)
  end

  defp generate_resource_clause([]), do: nil

  defp generate_resource_clause(resources) do
    # Separate static URIs (no {param} placeholders) from templated URIs
    {static_resources, templated_resources} =
      Enum.split_with(resources, fn mod ->
        template = Keyword.fetch!(mod.__component_opts__(), :uri)
        not String.contains?(template, "{")
      end)

    # Static URIs get direct pattern-match clauses — O(1) dispatch
    static_clauses =
      Enum.map(static_resources, fn mod ->
        uri = Keyword.fetch!(mod.__component_opts__(), :uri)

        quote do
          def handle_read_resource(conn, unquote(uri)) do
            unquote(mod).execute(%{}, conn)
          end
        end
      end)

    # Templated URIs use pre-compiled regex scan
    templated_compiled =
      Enum.map(templated_resources, fn mod ->
        template = Keyword.fetch!(mod.__component_opts__(), :uri)
        {param_names, regex} = ConduitMcp.DSL.compile_uri_template(template)
        {param_names, regex, mod}
      end)

    templated_clause =
      if templated_resources != [] do
        quote do
          @__resource_compiled unquote(Macro.escape(templated_compiled))

          def handle_read_resource(conn, uri) do
            Enum.find_value(@__resource_compiled, fn {param_names, regex, mod} ->
              case ConduitMcp.DSL.extract_uri_params_compiled(uri, param_names, regex) do
                {:ok, params} ->
                  atom_params = Map.new(params, fn {k, v} -> {String.to_atom(k), v} end)
                  mod.execute(atom_params, conn)

                :no_match ->
                  nil
              end
            end) ||
              {:error,
               %{
                 "code" => ConduitMcp.Errors.resource_not_found(),
                 "message" => "Resource not found: #{uri}"
               }}
          end
        end
      else
        # All resources are static; add a catch-all for unknown URIs
        quote do
          def handle_read_resource(_conn, uri) do
            {:error,
             %{
               "code" => ConduitMcp.Errors.resource_not_found(),
               "message" => "Resource not found: #{uri}"
             }}
          end
        end
      end

    quote do
      unquote(static_clauses)
      unquote(templated_clause)
    end
  end

  @custom_constraint_markers [
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

  defp generate_tool_validation_clauses(tools) do
    Enum.map(tools, fn mod ->
      name = mod.__component_name__()
      schema = mod.__validation_schema__()
      clean_schema = strip_markers(schema)

      quote do
        def __validation_schema_for_tool__(unquote(name)) do
          {unquote(Macro.escape(schema)), unquote(Macro.escape(clean_schema))}
        end
      end
    end)
  end

  defp generate_prompt_validation_clauses(prompts) do
    Enum.map(prompts, fn mod ->
      name = mod.__component_name__()
      schema = mod.__validation_schema__()
      clean_schema = strip_markers(schema)

      quote do
        def __validation_schema_for_prompt__(unquote(name)) do
          {unquote(Macro.escape(schema)), unquote(Macro.escape(clean_schema))}
        end
      end
    end)
  end

  defp strip_markers(schema) when is_list(schema) do
    Enum.map(schema, fn {param_name, param_opts} ->
      {param_name, Keyword.drop(param_opts, @custom_constraint_markers)}
    end)
  end

  defp strip_markers(_), do: []

  defp build_scope_map(tools) do
    Enum.reduce(tools, %{}, fn mod, acc ->
      case Keyword.get(mod.__component_opts__(), :scope) do
        nil -> acc
        scope -> Map.put(acc, mod.__component_name__(), scope)
      end
    end)
  end

  defp build_key_maps(components) do
    Map.new(components, fn mod ->
      fields =
        case mod.__validation_schema__() do
          schema when is_list(schema) ->
            Enum.map(schema, fn {atom_key, _opts} ->
              {Atom.to_string(atom_key), atom_key}
            end)
            |> Map.new()

          _ ->
            %{}
        end

      {mod.__component_name__(), fields}
    end)
  end

  defp build_capabilities(tools, resources, prompts) do
    caps = %{}

    caps =
      if tools != [] do
        Map.put(caps, "tools", %{"listChanged" => false})
      else
        caps
      end

    caps =
      if resources != [] do
        Map.put(caps, "resources", %{"listChanged" => false})
      else
        caps
      end

    if prompts != [] do
      Map.put(caps, "prompts", %{"listChanged" => false})
    else
      caps
    end
  end
end
