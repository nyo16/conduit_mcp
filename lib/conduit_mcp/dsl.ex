defmodule ConduitMcp.DSL do
  @moduledoc """
  DSL for defining MCP servers with a clean, declarative syntax.

  The DSL provides macros for defining tools, prompts, and resources
  without manually building JSON schemas and callback functions.

  ## Example

      defmodule MyApp.MCPServer do
        use ConduitMcp.Server

        tool "greet", "Greets a person" do
          param :name, :string, "Name to greet", required: true
          param :style, :string, "Greeting style", enum: ["formal", "casual"]

          handle fn _conn, params ->
            name = params["name"]
            style = params["style"] || "casual"
            greeting = if style == "formal", do: "Good day", else: "Hey"
            text("\#{greeting}, \#{name}!")
          end
        end

        tool "calculate", "Math operations" do
          param :op, :string, "Operation", enum: ~w(add sub mul div), required: true
          param :a, :number, "First number", required: true
          param :b, :number, "Second number", required: true

          handle MyMath, :calculate  # MFA
        end

        prompt "code_review", "Code review assistant" do
          arg :code, :string, "Code to review", required: true
          arg :language, :string, "Language", default: "elixir"

          get fn _conn, args ->
            [
              system("You are a code reviewer"),
              user("Review this \#{args["language"]} code:\\n\#{args["code"]}")
            ]
          end
        end

        resource "user://{id}" do
          description "User profile"
          mime_type "application/json"

          read fn _conn, params, _opts ->
            user = MyApp.Users.get!(params["id"])
            json(user)
          end
        end
      end

  The DSL automatically generates:
  - Tool/prompt/resource schemas
  - Input validation (JSON Schema)
  - handle_list_* callbacks
  - handle_call_tool/handle_get_prompt/handle_read_resource callbacks
  """


  @doc false
  defmacro __using__(_opts) do
    quote do
      import ConduitMcp.DSL
      import ConduitMcp.DSL.Helpers

      Module.register_attribute(__MODULE__, :mcp_tools, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_prompts, accumulate: true)
      Module.register_attribute(__MODULE__, :mcp_resources, accumulate: true)

      @before_compile ConduitMcp.DSL
    end
  end

  @doc """
  Defines an MCP tool.

  ## Examples

      # Simple tool with inline handler
      tool "greet", "Greets someone" do
        param :name, :string, "Name", required: true
        handle fn _conn, %{"name" => n} -> text("Hello \#{n}!") end
      end

      # Tool with MFA handler
      tool "calculate", "Calculator" do
        param :a, :number, required: true
        param :b, :number, required: true
        handle MyMath, :add
      end

      # Tool with nested object
      tool "create_user", "Creates user" do
        param :user, :object, "User data", required: true do
          field :name, :string, "Full name", required: true
          field :email, :string, "Email", required: true
        end
        handle MyUsers, :create
      end
  """
  defmacro tool(name, description, do: block) do
    quote do
      @mcp_current_tool_name unquote(name)
      @mcp_current_tool_description unquote(description)
      @mcp_current_tool_params []
      @mcp_current_tool_handler nil

      unquote(block)

      # After block executes, store the complete tool definition
      @mcp_tools %{
        name: @mcp_current_tool_name,
        description: @mcp_current_tool_description,
        params: Enum.reverse(@mcp_current_tool_params),
        handler: @mcp_current_tool_handler
      }

      # Clean up
      Module.delete_attribute(__MODULE__, :mcp_current_tool_name)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_description)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_params)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_handler)
    end
  end

  @doc """
  Defines a parameter for a tool.

  ## Options

  - `:required` - Mark parameter as required (default: false)
  - `:enum` - List of allowed values
  - `:default` - Default value if not provided

  ## Examples

      param :name, :string, "User name", required: true
      param :age, :number, "Age in years"
      param :role, :string, "User role", enum: ["admin", "user", "guest"]
      param :active, :boolean, "Active status", default: true
  """
  defmacro param(name, type, description \\ nil, opts \\ [])

  defmacro param(name, type, description, opts) when is_list(opts) do
    quote do
      param_def = %{
        name: unquote(name),
        type: unquote(type),
        description: unquote(description),
        opts: unquote(opts),
        nested: nil,
        items: nil
      }

      current_params = Module.get_attribute(__MODULE__, :mcp_current_tool_params) || []
      Module.put_attribute(__MODULE__, :mcp_current_tool_params, [param_def | current_params])
    end
  end

  @doc """
  Defines a parameter with nested fields (for objects) or items (for arrays).
  """
  defmacro param(name, type, description, opts, do: nested_block) when type == :object do
    quote do
      @mcp_current_nested_params []

      unquote(nested_block)

      param_def = %{
        name: unquote(name),
        type: :object,
        description: unquote(description),
        opts: unquote(opts),
        nested: Enum.reverse(@mcp_current_nested_params),
        items: nil
      }

      @mcp_current_tool_params param_def

      Module.delete_attribute(__MODULE__, :mcp_current_nested_params)
    end
  end

  defmacro param(name, type, description, opts, do: nested_block) when type == :array do
    quote do
      @mcp_current_array_items nil

      unquote(nested_block)

      param_def = %{
        name: unquote(name),
        type: :array,
        description: unquote(description),
        opts: unquote(opts),
        nested: nil,
        items: @mcp_current_array_items
      }

      @mcp_current_tool_params param_def

      Module.delete_attribute(__MODULE__, :mcp_current_array_items)
    end
  end

  @doc """
  Defines a nested field within an object parameter.

  ## Examples

      param :user, :object, "User data" do
        field :name, :string, "Name", required: true
        field :email, :string, "Email", required: true
        field :address, :object, "Address" do
          field :city, :string, "City"
          field :zip, :string, "Zip code"
        end
      end
  """
  defmacro field(name, type, description \\ nil, opts \\ [])

  defmacro field(name, type, description, opts) when is_list(opts) do
    quote do
      field_def = %{
        name: unquote(name),
        type: unquote(type),
        description: unquote(description),
        opts: unquote(opts),
        nested: nil,
        items: nil
      }

      @mcp_current_nested_params field_def
    end
  end

  defmacro field(name, type, description, opts, do: nested_block) when type == :object do
    quote do
      # Save current nested params
      parent_nested = Module.get_attribute(__MODULE__, :mcp_current_nested_params) || []

      # Start new nested params for this object
      Module.put_attribute(__MODULE__, :mcp_current_nested_params, [])

      unquote(nested_block)

      # Get the nested fields we just accumulated
      nested_fields = Module.get_attribute(__MODULE__, :mcp_current_nested_params)

      # Restore parent nested params
      Module.put_attribute(__MODULE__, :mcp_current_nested_params, parent_nested)

      # Add this field with its nested fields
      field_def = %{
        name: unquote(name),
        type: :object,
        description: unquote(description),
        opts: unquote(opts),
        nested: Enum.reverse(nested_fields),
        items: nil
      }

      @mcp_current_nested_params field_def
    end
  end

  @doc """
  Defines the item type for an array parameter.

  ## Examples

      param :tags, :array, "Tags" do
        items :string
      end

      param :users, :array, "Users" do
        items :object do
          field :name, :string, "Name"
          field :email, :string, "Email"
        end
      end
  """
  defmacro items(type) when is_atom(type) do
    quote do
      @mcp_current_array_items %{type: unquote(type), nested: nil}
    end
  end

  defmacro items(type, do: nested_block) when type == :object do
    quote do
      @mcp_current_nested_params []

      unquote(nested_block)

      @mcp_current_array_items %{
        type: :object,
        nested: Enum.reverse(@mcp_current_nested_params)
      }

      Module.delete_attribute(__MODULE__, :mcp_current_nested_params)
    end
  end

  @doc """
  Defines the handler function for a tool.

  Accepts either an anonymous function or an MFA tuple.

  ## Examples

      # Anonymous function
      handle fn _conn, params ->
        text("Result: \#{params["input"]}")
      end

      # Module, function
      handle MyModule, :my_function

      # Function capture
      handle &MyModule.my_function/2
  """
  defmacro handle({:fn, _, _} = fun) do
    # Capture the AST of the anonymous function
    quote do
      @mcp_current_tool_handler {:fn_ast, unquote(Macro.escape(fun))}
    end
  end

  defmacro handle({:&, _, _} = fun) do
    # Function capture like &MyModule.func/2
    quote do
      @mcp_current_tool_handler {:fn_ast, unquote(Macro.escape(fun))}
    end
  end

  defmacro handle(module, function) do
    quote do
      @mcp_current_tool_handler {:mfa, {unquote(module), unquote(function)}}
    end
  end

  # ============ PROMPTS ============

  @doc """
  Defines an MCP prompt.

  ## Example

      prompt "code_review", "Code review assistant" do
        arg :code, :string, "Code to review", required: true
        arg :language, :string, "Language", default: "elixir"

        get fn _conn, args ->
          [
            system("You are a code reviewer"),
            user("Review this code: \#{args["code"]}")
          ]
        end

        complete :language, fn _conn, prefix ->
          ~w(elixir python javascript) |> Enum.filter(&String.starts_with?(&1, prefix))
        end
      end
  """
  defmacro prompt(name, description, do: block) do
    quote do
      @mcp_current_prompt_name unquote(name)
      @mcp_current_prompt_description unquote(description)
      @mcp_current_prompt_args []
      @mcp_current_prompt_handler nil
      @mcp_current_prompt_completions []

      unquote(block)

      @mcp_prompts %{
        name: @mcp_current_prompt_name,
        description: @mcp_current_prompt_description,
        args: Enum.reverse(@mcp_current_prompt_args),
        handler: @mcp_current_prompt_handler,
        completions: @mcp_current_prompt_completions
      }

      Module.delete_attribute(__MODULE__, :mcp_current_prompt_name)
      Module.delete_attribute(__MODULE__, :mcp_current_prompt_description)
      Module.delete_attribute(__MODULE__, :mcp_current_prompt_args)
      Module.delete_attribute(__MODULE__, :mcp_current_prompt_handler)
      Module.delete_attribute(__MODULE__, :mcp_current_prompt_completions)
    end
  end

  @doc """
  Defines a prompt argument.

  ## Examples

      arg :code, :string, "Code to review", required: true
      arg :language, :string, "Programming language", default: "elixir"
  """
  defmacro arg(name, type, description \\ nil, opts \\ []) do
    quote do
      arg_def = %{
        name: unquote(name),
        type: unquote(type),
        description: unquote(description),
        opts: unquote(opts)
      }

      current_args = Module.get_attribute(__MODULE__, :mcp_current_prompt_args) || []
      Module.put_attribute(__MODULE__, :mcp_current_prompt_args, [arg_def | current_args])
    end
  end

  @doc """
  Defines the get handler for a prompt.

  The handler should return a list of message objects.

  ## Examples

      get fn _conn, args ->
        [
          system("You are helpful"),
          user("Question: \#{args["question"]}")
        ]
      end

      get MyPrompts, :get_review
  """
  defmacro get({:fn, _, _} = fun) do
    quote do
      @mcp_current_prompt_handler {:fn_ast, unquote(Macro.escape(fun))}
    end
  end

  defmacro get({:&, _, _} = fun) do
    quote do
      @mcp_current_prompt_handler {:fn_ast, unquote(Macro.escape(fun))}
    end
  end

  defmacro get(module, function) do
    quote do
      @mcp_current_prompt_handler {:mfa, {unquote(module), unquote(function)}}
    end
  end

  @doc """
  Defines an autocomplete handler for a prompt argument.

  ## Example

      complete :language, fn _conn, prefix ->
        ~w(elixir python javascript rust)
        |> Enum.filter(&String.starts_with?(&1, prefix))
      end
  """
  defmacro complete(arg_name, fun) do
    quote do
      completion_def = %{
        arg: unquote(arg_name),
        handler: unquote(fun)
      }

      @mcp_current_prompt_completions completion_def
    end
  end

  # ============ RESOURCES ============

  @doc """
  Defines an MCP resource.

  ## Examples

      resource "user://{id}" do
        description "User profile data"
        mime_type "application/json"

        read fn _conn, params, _opts ->
          user = MyApp.Users.get!(params["id"])
          json(user)
        end
      end

      resource "file://{path}" do
        mime_type "text/plain"
        read MyFiles, :read
        complete :path, &MyFiles.autocomplete/2
      end
  """
  defmacro resource(uri, do: block) do
    quote do
      @mcp_current_resource_uri unquote(uri)
      @mcp_current_resource_description nil
      @mcp_current_resource_mime_type nil
      @mcp_current_resource_handler nil
      @mcp_current_resource_completions []

      unquote(block)

      @mcp_resources %{
        uri: @mcp_current_resource_uri,
        description: @mcp_current_resource_description,
        mime_type: @mcp_current_resource_mime_type,
        handler: @mcp_current_resource_handler,
        completions: @mcp_current_resource_completions
      }

      Module.delete_attribute(__MODULE__, :mcp_current_resource_uri)
      Module.delete_attribute(__MODULE__, :mcp_current_resource_description)
      Module.delete_attribute(__MODULE__, :mcp_current_resource_mime_type)
      Module.delete_attribute(__MODULE__, :mcp_current_resource_handler)
      Module.delete_attribute(__MODULE__, :mcp_current_resource_completions)
    end
  end

  @doc """
  Sets the description for a resource.

  ## Example

      resource "user://{id}" do
        description "User profile information"
        read MyUsers, :read
      end
  """
  defmacro description(desc) do
    quote do
      @mcp_current_resource_description unquote(desc)
    end
  end

  @doc """
  Sets the MIME type for a resource.

  ## Example

      resource "file://{path}" do
        mime_type "text/plain"
        read MyFiles, :read
      end
  """
  defmacro mime_type(type) do
    quote do
      @mcp_current_resource_mime_type unquote(type)
    end
  end

  @doc """
  Defines the read handler for a resource.

  Handler signature: `(conn, uri_params, opts) -> result`

  ## Examples

      read fn _conn, %{"id" => id}, _opts ->
        user = MyApp.Users.get!(id)
        json(user)
      end

      read MyFiles, :read
  """
  defmacro read({:fn, _, _} = fun) do
    quote do
      @mcp_current_resource_handler {:fn_ast, unquote(Macro.escape(fun))}
    end
  end

  defmacro read({:&, _, _} = fun) do
    quote do
      @mcp_current_resource_handler {:fn_ast, unquote(Macro.escape(fun))}
    end
  end

  defmacro read(module, function) do
    quote do
      @mcp_current_resource_handler {:mfa, {unquote(module), unquote(function)}}
    end
  end

  # ============ CODE GENERATION (@before_compile) ============

  @doc false
  defmacro __before_compile__(env) do
    tools = Module.get_attribute(env.module, :mcp_tools) || []
    prompts = Module.get_attribute(env.module, :mcp_prompts) || []
    resources = Module.get_attribute(env.module, :mcp_resources) || []

    # Build schemas at compile time (outside quote block)
    tool_schemas = tools |> Enum.reverse() |> Enum.map(&ConduitMcp.DSL.SchemaBuilder.build_tool_schema/1)
    prompt_schemas = prompts |> Enum.reverse() |> Enum.map(&ConduitMcp.DSL.SchemaBuilder.build_prompt_schema/1)
    resource_schemas = resources |> Enum.reverse() |> Enum.map(&ConduitMcp.DSL.SchemaBuilder.build_resource_schema/1)

    tool_clauses = generate_tool_clauses(tools)
    prompt_clauses = generate_prompt_clauses(prompts)
    resource_clauses = generate_resource_clauses(resources)

    quote do
      # Use pre-built schemas
      @tools unquote(Macro.escape(tool_schemas))
      @prompts unquote(Macro.escape(prompt_schemas))
      @resources unquote(Macro.escape(resource_schemas))

      # Always generate handle_list_tools (empty list if no tools)
      def handle_list_tools(_conn) do
        {:ok, %{"tools" => @tools}}
      end

      # Inject generated tool handler clauses
      unquote(tool_clauses)

      # Catch-all for unknown tools
      if unquote(length(tools)) > 0 do
        def handle_call_tool(_conn, tool_name, _params) do
          {:error, %{"code" => -32601, "message" => "Tool not found: #{tool_name}"}}
        end
      end

      # Always generate handle_list_prompts (empty list if no prompts)
      def handle_list_prompts(_conn) do
        {:ok, %{"prompts" => @prompts}}
      end

      # Inject generated prompt handler clauses
      unquote(prompt_clauses)

      # Catch-all for unknown prompts
      if unquote(length(prompts)) > 0 do
        def handle_get_prompt(_conn, prompt_name, _args) do
          {:error, %{"code" => -32601, "message" => "Prompt not found: #{prompt_name}"}}
        end
      end

      # Always generate handle_list_resources (empty list if no resources)
      def handle_list_resources(_conn) do
        {:ok, %{"resources" => @resources}}
      end

      # Inject generated resource handler clauses
      unquote(resource_clauses)

      # Catch-all for unknown resources (only if no resources with handlers were generated)
      if unquote(length(resources)) > 0 and unquote(Enum.empty?(resource_clauses)) do
        def handle_read_resource(_conn, uri) do
          {:error, %{"code" => -32601, "message" => "Resource not found: #{uri}"}}
        end
      end
    end
  end

  # Generate tool handler clauses outside quote block
  defp generate_tool_clauses(tools) do
    Enum.reverse(tools)
    |> Enum.map(fn %{name: tool_name, handler: handler} ->
      case handler do
        {:fn_ast, handler_ast} ->
          quote do
            def handle_call_tool(_conn, unquote(tool_name), params) do
              unquote(handler_ast).(_conn, params)
            end
          end

        {:mfa, {mod, fun}} ->
          quote do
            def handle_call_tool(_conn, unquote(tool_name), params) do
              apply(unquote(mod), unquote(fun), [_conn, params])
            end
          end

        nil ->
          raise CompileError,
            description: "Tool '#{tool_name}' has no handler defined. Use 'handle fn ... end' or 'handle Module, :function'"
      end
    end)
  end

  # Generate prompt handler clauses outside quote block
  defp generate_prompt_clauses(prompts) do
    Enum.reverse(prompts)
    |> Enum.map(fn %{name: prompt_name, handler: handler} ->
      case handler do
        {:fn_ast, handler_ast} ->
          quote do
            def handle_get_prompt(_conn, unquote(prompt_name), args) do
              messages = unquote(handler_ast).(_conn, args)
              {:ok, %{"messages" => messages}}
            end
          end

        {:mfa, {mod, fun}} ->
          quote do
            def handle_get_prompt(_conn, unquote(prompt_name), args) do
              messages = apply(unquote(mod), unquote(fun), [_conn, args])
              {:ok, %{"messages" => messages}}
            end
          end

        nil ->
          raise CompileError,
            description: "Prompt '#{prompt_name}' has no get handler defined. Use 'get fn ... end' or 'get Module, :function'"
      end
    end)
  end

  # Generate resource handler clauses outside quote block
  defp generate_resource_clauses(resources) do
    # Generate a single comprehensive handler that tries all resources
    resources_with_handlers = resources
    |> Enum.reverse()
    |> Enum.filter(fn %{handler: handler} -> handler != nil end)

    if Enum.empty?(resources_with_handlers) do
      []
    else
      # Generate a single function that tries each resource
      template_clauses = Enum.map(resources_with_handlers, fn %{uri: res_uri, handler: handler} ->
        case handler do
          {:fn_ast, handler_ast} ->
            quote do
              case ConduitMcp.DSL.extract_uri_params(unquote(res_uri), uri) do
                {:ok, params} ->
                  unquote(handler_ast).(conn, params, %{})

                :no_match ->
                  nil
              end
            end

          {:mfa, {mod, fun}} ->
            quote do
              case ConduitMcp.DSL.extract_uri_params(unquote(res_uri), uri) do
                {:ok, params} ->
                  apply(unquote(mod), unquote(fun), [conn, params, %{}])

                :no_match ->
                  nil
              end
            end
        end
      end)

      # Create a function that tries each template in sequence
      [quote do
        def handle_read_resource(conn, uri) do
          # Try each resource template in order
          result = unquote(template_clauses)
          |> Enum.find_value(fn clause_result ->
            case clause_result do
              nil -> false
              other -> other
            end
          end)

          case result do
            nil ->
              # No match found, fall through to catch-all
              {:error, %{"code" => -32601, "message" => "Resource not found: #{uri}"}}

            result ->
              result
          end
        end
      end]
    end
  end

  @doc false
  def extract_uri_params(template, uri) do
    # Parse template to extract parameter names and create regex pattern
    # Template: "user://{id}/posts/{post_id}"
    # URI: "user://123/posts/456"
    # Result: %{"id" => "123", "post_id" => "456"}

    # Extract parameter names first (before escaping)
    param_names = Regex.scan(~r/\{([^}]+)\}/, template)
    |> Enum.map(fn [_full, name] -> name end)

    # Replace {param} with a placeholder token before escaping
    template_with_tokens = Regex.replace(~r/\{[^}]+\}/, template, "<<<PARAM>>>")

    # Escape special regex characters
    escaped_template = Regex.escape(template_with_tokens)

    # Replace placeholder tokens with capture groups
    pattern = String.replace(escaped_template, "<<<PARAM>>>", "([^/]+)")

    # Try to match the URI against the pattern
    case Regex.run(~r/^#{pattern}$/, uri) do
      nil ->
        :no_match

      [_full | captured_values] ->
        params = Enum.zip(param_names, captured_values)
        |> Enum.into(%{})

        {:ok, params}
    end
  end
end
