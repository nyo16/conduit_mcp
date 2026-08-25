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

  alias ConduitMcp.Validation.SchemaConverter

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

    {tools, resources, prompts} = group_and_validate_components(components, module)

    tool_schemas = Enum.map(tools, & &1.__component_schema__())
    prompt_schemas = Enum.map(prompts, & &1.__component_schema__())
    {resource_schemas, resource_template_schemas} = partition_resource_schemas(resources)

    tool_clauses = generate_tool_clauses(tools)
    prompt_clauses = generate_prompt_clauses(prompts)
    resource_clause = generate_resource_clause(resources)

    tool_validation_clauses = generate_tool_validation_clauses(tools)
    prompt_validation_clauses = generate_prompt_validation_clauses(prompts)

    scope_clauses =
      ConduitMcp.DSL.__generate_scope_clauses__(
        component_scopes(tools, & &1.__component_name__()),
        component_scopes(prompts, & &1.__component_name__()),
        component_scopes(resources, &Keyword.fetch!(&1.__component_opts__(), :uri))
      )

    key_conversion =
      generate_key_conversion(build_key_maps(tools), build_key_maps(prompts))

    capabilities = build_capabilities(tools, resources, prompts)

    endpoint_config =
      Keyword.take(opts, [:name, :version, :rate_limit, :message_rate_limit, :auth])

    templated_uris = collect_templated_uris(resources)

    generate_endpoint_ast(%{
      templated_uris: templated_uris,
      tool_schemas: tool_schemas,
      tool_clauses: tool_clauses,
      resource_schemas: resource_schemas,
      resource_template_schemas: resource_template_schemas,
      resource_clause: resource_clause,
      prompt_schemas: prompt_schemas,
      prompt_clauses: prompt_clauses,
      tool_validation_clauses: tool_validation_clauses,
      prompt_validation_clauses: prompt_validation_clauses,
      scope_clauses: scope_clauses,
      key_conversion: key_conversion,
      endpoint_config: endpoint_config,
      capabilities: capabilities
    })
  end

  defp generate_endpoint_ast(parts) do
    quote do
      @on_load :__precompile_template_regexes__

      def __precompile_template_regexes__ do
        Enum.each(
          unquote(parts.templated_uris),
          &ConduitMcp.DSL.precompile_template_regex(__MODULE__, &1)
        )

        :ok
      end

      # --- Tool callbacks ---

      def handle_list_tools(_conn) do
        {:ok, %{"tools" => unquote(Macro.escape(parts.tool_schemas))}}
      end

      unquote(parts.tool_clauses)

      def handle_call_tool(_conn, tool_name, _params) do
        {:error,
         %{
           "code" => ConduitMcp.Errors.invalid_params(),
           "message" => "Unknown tool: #{ConduitMcp.Reflect.text(tool_name)}"
         }}
      end

      # --- Resource callbacks ---

      def handle_list_resources(_conn) do
        {:ok, %{"resources" => unquote(Macro.escape(parts.resource_schemas))}}
      end

      def handle_list_resource_templates(_conn) do
        {:ok, %{"resourceTemplates" => unquote(Macro.escape(parts.resource_template_schemas))}}
      end

      unquote(parts.resource_clause)

      # Only generate catch-all if no resources defined their own handler
      if unquote(is_nil(parts.resource_clause)) do
        def handle_read_resource(_conn, uri) do
          {:error,
           %{
             "code" => ConduitMcp.Errors.resource_not_found(),
             "message" => "Resource not found: #{ConduitMcp.Reflect.text(uri)}"
           }}
        end
      end

      # --- Prompt callbacks ---

      def handle_list_prompts(_conn) do
        {:ok, %{"prompts" => unquote(Macro.escape(parts.prompt_schemas))}}
      end

      unquote(parts.prompt_clauses)

      def handle_get_prompt(_conn, prompt_name, _args) do
        {:error,
         %{
           "code" => ConduitMcp.Errors.invalid_params(),
           "message" => "Unknown prompt: #{ConduitMcp.Reflect.text(prompt_name)}"
         }}
      end

      # --- Validation schema lookups ---

      unquote(parts.tool_validation_clauses)

      def __validation_schema_for_tool__(_name), do: nil

      unquote(parts.prompt_validation_clauses)

      def __validation_schema_for_prompt__(_name), do: nil

      # --- Scope lookup ---
      unquote(parts.scope_clauses)

      # --- Key maps for atom conversion ---

      unquote(parts.key_conversion)

      # --- Endpoint config ---

      def __endpoint_config__ do
        unquote(parts.endpoint_config)
      end

      # --- Capabilities ---

      def __capabilities__ do
        unquote(Macro.escape(parts.capabilities))
      end
    end
  end

  # --- Compile-time helpers ---

  defp group_and_validate_components(components, module) do
    components = Enum.reverse(components)
    validate_components!(components, module)

    tools = Enum.filter(components, &(&1.__component_type__() == :tool))
    resources = Enum.filter(components, &(&1.__component_type__() == :resource))
    prompts = Enum.filter(components, &(&1.__component_type__() == :prompt))

    validate_no_name_conflicts!(tools, :tool, module)
    validate_no_name_conflicts!(prompts, :prompt, module)

    {tools, resources, prompts}
  end

  defp partition_resource_schemas(resources) do
    {static, templated} =
      resources
      |> Enum.map(& &1.__component_schema__())
      |> Enum.split_with(fn schema -> not String.contains?(schema["uri"] || "", "{") end)

    {static, Enum.map(templated, &ConduitMcp.DSL.SchemaBuilder.to_resource_template_schema/1)}
  end

  defp collect_templated_uris(resources) do
    resources
    |> Enum.map(fn mod -> Keyword.fetch!(mod.__component_opts__(), :uri) end)
    |> Enum.filter(&String.contains?(&1, "{"))
  end

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

    # Templated URIs use pre-compiled regex scan; store {template, mod} pairs
    # and look up the regex from persistent_term at request time to avoid
    # per-process Regex.recompile/1 (Macro.escape strips re_pattern).
    templated_template_mod_pairs =
      Enum.map(templated_resources, fn mod ->
        {Keyword.fetch!(mod.__component_opts__(), :uri), mod}
      end)

    templated_clause =
      if templated_resources != [] do
        quote do
          @__resource_template_pairs unquote(Macro.escape(templated_template_mod_pairs))

          def handle_read_resource(conn, uri) do
            Enum.find_value(@__resource_template_pairs, fn {template, mod} ->
              {param_names, regex} = ConduitMcp.DSL.template_regex(__MODULE__, template)

              case ConduitMcp.DSL.extract_uri_params_compiled(uri, param_names, regex) do
                {:ok, params} ->
                  case ConduitMcp.Endpoint.atomize_uri_params(params) do
                    {:ok, atom_params} -> mod.execute(atom_params, conn)
                    :error -> nil
                  end

                :no_match ->
                  nil
              end
            end) ||
              {:error,
               %{
                 "code" => ConduitMcp.Errors.resource_not_found(),
                 "message" => "Resource not found: #{ConduitMcp.Reflect.text(uri)}"
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
               "message" => "Resource not found: #{ConduitMcp.Reflect.text(uri)}"
             }}
          end
        end
      end

    quote do
      unquote(static_clauses)
      unquote(templated_clause)
    end
  end

  @doc false
  # URI template param names are compile-time-defined atoms; an unknown name
  # means the URI matched a different shape — treat as no-match, don't crash.
  def atomize_uri_params(params) do
    {:ok, Map.new(params, fn {k, v} -> {String.to_existing_atom(k), v} end)}
  rescue
    ArgumentError -> :error
  end

  defp generate_tool_validation_clauses(tools) do
    Enum.map(tools, fn mod ->
      name = mod.__component_name__()
      schema = mod.__validation_schema__()
      clean_schema = SchemaConverter.strip_markers(schema)

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
      clean_schema = SchemaConverter.strip_markers(schema)

      quote do
        def __validation_schema_for_prompt__(unquote(name)) do
          {unquote(Macro.escape(schema)), unquote(Macro.escape(clean_schema))}
        end
      end
    end)
  end

  # `:scope` is documented as a general component option, so it must be
  # collected for resources and prompts too — not only tools. Building the map
  # from tools alone is what made `use ConduitMcp.Component, type: :resource,
  # scope: "admin:read"` compile clean and enforce nothing.
  # `Enum.flat_map`, not a prepending reduce: the emitted templated-resource
  # scope scan must walk templates in the same order `handle_read_resource/2`
  # dispatches them, or two overlapping templates enforce one scope and run the
  # other's handler.
  defp component_scopes(components, key_fun) do
    components
    |> Enum.flat_map(fn mod ->
      case Keyword.get(mod.__component_opts__(), :scope) do
        nil -> []
        scope -> [{key_fun.(mod), scope}]
      end
    end)
    # De-duplicated because two components sharing a name would emit two
    # identical `__scope_for_*__` clause heads, and the second is unreachable
    # code the reader has to reason about. It is *not* a build fix: clauses
    # injected via `unquote` carry no line metadata, so the compiler emits no
    # "this clause cannot match" diagnostic for them (verified), and
    # first-declaration-wins already held without this. First declaration wins,
    # matching dispatch order.
    |> Enum.uniq_by(&elem(&1, 0))
  end

  # Emit one `__key_map__(name)` clause per component with a non-empty key
  # map, plus the conversion helper that consults it.
  #
  # When no component declares a schema there is nothing to convert, so the
  # helper is the identity. Emitting the lookup regardless would leave
  # `Map.get/2` reading a provably empty map — dead work that the type
  # checker correctly flags as always returning nil.
  defp generate_key_conversion(tool_key_maps, prompt_key_maps) do
    clauses =
      tool_key_maps
      |> Map.merge(prompt_key_maps)
      |> Enum.reject(fn {_name, km} -> km == %{} end)
      |> Enum.map(fn {name, km} ->
        quote do
          defp __key_map__(unquote(name)), do: unquote(Macro.escape(km))
        end
      end)

    if clauses == [] do
      quote do
        defp __convert_to_atom_keys__(_component_name, params), do: params
      end
    else
      quote do
        unquote(clauses)

        # Components without aliases fall through to this catch-all.
        defp __key_map__(_component_name), do: %{}

        defp __convert_to_atom_keys__(component_name, params) do
          key_map = __key_map__(component_name)

          Map.new(params, fn {k, v} ->
            case Map.get(key_map, k) do
              nil -> {k, v}
              atom_key -> {atom_key, v}
            end
          end)
        end
      end
    end
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
