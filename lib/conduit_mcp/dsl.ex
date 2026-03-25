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
      @mcp_current_tool_annotations nil
      @mcp_current_tool_scope nil
      @mcp_current_tool_meta nil

      unquote(block)

      # After block executes, store the complete tool definition
      @mcp_tools %{
        name: @mcp_current_tool_name,
        description: @mcp_current_tool_description,
        params: Enum.reverse(@mcp_current_tool_params),
        handler: @mcp_current_tool_handler,
        annotations: @mcp_current_tool_annotations,
        scope: @mcp_current_tool_scope,
        meta: @mcp_current_tool_meta
      }

      # Clean up
      Module.delete_attribute(__MODULE__, :mcp_current_tool_name)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_description)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_params)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_handler)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_annotations)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_scope)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_meta)
    end
  end

  @doc """
  Sets annotations for a tool.

  Annotations provide hints about tool behavior to clients.

  ## Options

  - `:read_only` - Tool doesn't modify state (default: not set)
  - `:destructive` - Tool may perform destructive operations (default: not set)
  - `:idempotent` - Calling multiple times has same effect (default: not set)
  - `:open_world` - Tool may interact with external systems (default: not set)

  ## Example

      tool "delete_user", "Deletes a user" do
        annotations destructive: true, idempotent: true
        param :id, :string, "User ID", required: true
        handle fn _conn, %{"id" => id} -> ... end
      end
  """
  defmacro annotations(opts) do
    quote do
      annotation_map = %{}

      annotation_map =
        case Keyword.get(unquote(opts), :read_only) do
          nil -> annotation_map
          val -> Map.put(annotation_map, "readOnlyHint", val)
        end

      annotation_map =
        case Keyword.get(unquote(opts), :destructive) do
          nil -> annotation_map
          val -> Map.put(annotation_map, "destructiveHint", val)
        end

      annotation_map =
        case Keyword.get(unquote(opts), :idempotent) do
          nil -> annotation_map
          val -> Map.put(annotation_map, "idempotentHint", val)
        end

      annotation_map =
        case Keyword.get(unquote(opts), :open_world) do
          nil -> annotation_map
          val -> Map.put(annotation_map, "openWorldHint", val)
        end

      @mcp_current_tool_annotations annotation_map
    end
  end

  @doc """
  Sets a required OAuth scope for a tool.

  When OAuth authentication is enabled, the handler will check that the
  token contains the required scope before executing the tool.

  ## Example

      tool "delete_user", "Deletes a user" do
        scope "users:write"
        param :id, :string, "User ID", required: true
        handle fn _conn, %{"id" => id} -> ... end
      end

  Multiple scopes can be required by calling scope multiple times or
  passing a space-separated string:

      tool "admin_action", "Admin only" do
        scope "admin users:write"
        handle fn _conn, _params -> ... end
      end
  """
  defmacro scope(scope_string) do
    quote do
      @mcp_current_tool_scope unquote(scope_string)
    end
  end

  @doc """
  Attaches arbitrary `_meta` metadata to a tool definition.

  The `_meta` field is an open extension point in the MCP spec. Any map
  can be passed — atom keys are automatically converted to string keys
  in the JSON output.

  ## Example

      tool "dashboard", "Health dashboard" do
        meta %{ui: %{resourceUri: "ui://dashboard/app.html"}}
        handle fn _conn, _params -> json(%{ok: true}) end
      end

  The tool's `tools/list` entry will include:

      %{
        "name" => "dashboard",
        "_meta" => %{"ui" => %{"resourceUri" => "ui://dashboard/app.html"}}
      }
  """
  defmacro meta(meta_map) do
    quote do
      @mcp_current_tool_meta unquote(meta_map)
    end
  end

  @doc """
  Shortcut for declaring a UI resource URI on a tool (MCP Apps).

  This is sugar for `meta %{ui: %{resourceUri: uri}}`. It links the tool
  to an interactive HTML resource that MCP Apps-compatible hosts will
  render as a sandboxed iframe.

  ## Example

      tool "dashboard", "Health dashboard" do
        ui "ui://dashboard/app.html"
        handle fn _conn, _params -> json(%{ok: true}) end
      end

  See the [MCP Apps guide](guides/mcp_apps.md) for full details.
  """
  defmacro ui(resource_uri) do
    quote do
      @mcp_current_tool_meta %{
        ui: %{resourceUri: unquote(resource_uri)},
        "ui/resourceUri": unquote(resource_uri)
      }
    end
  end

  @doc """
  Defines a parameter for a tool.

  ## Basic Options

  - `:required` - Mark parameter as required (default: false)
  - `:enum` - List of allowed values
  - `:default` - Default value if not provided

  ## Enhanced Validation Options (NimbleOptions)

  - `:min` - Minimum value for numbers (inclusive)
  - `:max` - Maximum value for numbers (inclusive)
  - `:min_length` - Minimum string length
  - `:max_length` - Maximum string length
  - `:validator` - Custom validation function `fn(value) -> boolean()`

  ## Examples

      # Basic validation
      param :name, :string, "User name", required: true
      param :role, :string, "User role", enum: ["admin", "user", "guest"]
      param :active, :boolean, "Active status", default: true

      # Enhanced validation
      param :age, :integer, "Age in years", min: 0, max: 150, required: true
      param :username, :string, "Username", min_length: 3, max_length: 30
      param :score, :number, "Score", min: 0.0, max: 100.0, default: 50.0
      param :email, :string, "Email", validator: &ConduitMcp.Validation.Validators.email/1

      # Complex validation with multiple constraints
      param :priority, :string, "Task priority",
        required: true,
        enum: ["low", "medium", "high", "critical"],
        validator: &MyApp.validate_priority/1

      # Array with validation
      param :tags, {:array, :string}, "Tags", max_length: 10
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

  # ============ MCP APPS ============

  @doc """
  Defines an MCP App — a tool with a linked UI resource.

  The `app` macro is a convenience that registers both:
  1. A **tool** with `_meta.ui.resourceUri` pointing to a `ui://` resource
  2. A **resource** that serves the HTML file at that URI

  Use `view/1` inside the block to specify the HTML file path.
  The `ui://` URI is derived automatically from the tool name and filename.

  ## Example

      app "dashboard", "Health dashboard" do
        param :format, :string, "Output format", default: "json"
        view "priv/mcp_apps/dashboard.html"

        handle fn _conn, params ->
          json(%{cpu: 42, memory: 128})
        end
      end

  This is equivalent to:

      tool "dashboard", "Health dashboard" do
        ui "ui://dashboard/dashboard.html"
        param :format, :string, "Output format", default: "json"
        handle fn _conn, params -> json(%{cpu: 42, memory: 128}) end
      end

      resource "ui://dashboard/dashboard.html" do
        description "UI for dashboard"
        mime_type "text/html;profile=mcp-app"
        read fn _conn, _params, _opts ->
          app_html(File.read!("priv/mcp_apps/dashboard.html"))
        end
      end

  > **Note:** The `view` path is read with `File.read!/1` at runtime. For OTP
  > releases where the working directory differs, use a manual `tool` + `resource`
  > pair with `Application.app_dir/2` instead.
  """
  defmacro app(name, description, do: block) do
    quote do
      # Initialize tool attributes
      @mcp_current_tool_name unquote(name)
      @mcp_current_tool_description unquote(description)
      @mcp_current_tool_params []
      @mcp_current_tool_handler nil
      @mcp_current_tool_annotations nil
      @mcp_current_tool_scope nil
      @mcp_current_tool_meta nil
      @mcp_current_app_view nil

      unquote(block)

      # Derive the UI resource URI from tool name and view filename
      app_view_path = @mcp_current_app_view

      if is_nil(app_view_path) do
        raise CompileError,
          description:
            "App '#{unquote(name)}' has no view defined. Use 'view \"priv/mcp_apps/file.html\"'"
      end

      app_filename = Path.basename(app_view_path)
      app_resource_uri = "ui://#{unquote(name)}/#{app_filename}"

      # Store the tool with _meta.ui (both nested and flat key for compatibility)
      @mcp_current_tool_meta %{
        ui: %{resourceUri: app_resource_uri},
        "ui/resourceUri": app_resource_uri
      }

      @mcp_tools %{
        name: @mcp_current_tool_name,
        description: @mcp_current_tool_description,
        params: Enum.reverse(@mcp_current_tool_params),
        handler: @mcp_current_tool_handler,
        annotations: @mcp_current_tool_annotations,
        scope: @mcp_current_tool_scope,
        meta: @mcp_current_tool_meta
      }

      # Store the resource for the UI HTML — use :app_view handler type
      # which generate_resource_clauses will expand into File.read! at compile time
      @mcp_resources %{
        uri: app_resource_uri,
        description: "UI for #{unquote(name)}",
        mime_type: "text/html;profile=mcp-app",
        handler: {:app_view, app_view_path},
        completions: []
      }

      # Clean up
      Module.delete_attribute(__MODULE__, :mcp_current_tool_name)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_description)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_params)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_handler)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_annotations)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_scope)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_meta)
      Module.delete_attribute(__MODULE__, :mcp_current_app_view)
    end
  end

  @doc """
  Specifies the HTML file path for an MCP App.

  Used inside an `app` block to set the HTML file that will be served
  as the `ui://` resource.

  ## Example

      app "dashboard", "Health dashboard" do
        view "priv/mcp_apps/dashboard.html"
        handle fn _conn, _params -> json(%{ok: true}) end
      end
  """
  defmacro view(path) do
    quote do
      @mcp_current_app_view unquote(path)
    end
  end

  # ============ CODE GENERATION (@before_compile) ============

  @doc false
  defmacro __before_compile__(env) do
    tools = Module.get_attribute(env.module, :mcp_tools) || []
    prompts = Module.get_attribute(env.module, :mcp_prompts) || []
    resources = Module.get_attribute(env.module, :mcp_resources) || []

    # Build schemas at compile time (outside quote block)
    tool_schemas =
      tools |> Enum.reverse() |> Enum.map(&ConduitMcp.DSL.SchemaBuilder.build_tool_schema/1)

    prompt_schemas =
      prompts |> Enum.reverse() |> Enum.map(&ConduitMcp.DSL.SchemaBuilder.build_prompt_schema/1)

    resource_schemas =
      resources
      |> Enum.reverse()
      |> Enum.map(&ConduitMcp.DSL.SchemaBuilder.build_resource_schema/1)

    # Generate validation schema lookup functions
    validation_lookup_functions =
      ConduitMcp.DSL.SchemaBuilder.generate_validation_lookup_functions(
        tools |> Enum.reverse(),
        prompts |> Enum.reverse()
      )

    # Validate all schemas at compile time
    case ConduitMcp.DSL.SchemaBuilder.validate_all_schemas(
           tools |> Enum.reverse(),
           prompts |> Enum.reverse()
         ) do
      :ok ->
        :ok

      {:error, errors} ->
        require Logger
        Logger.warning("Validation schema compilation warnings: #{inspect(errors)}")
    end

    tool_clauses = generate_tool_clauses(tools)
    prompt_clauses = generate_prompt_clauses(prompts)
    resource_clauses = generate_resource_clauses(resources)

    # Build scope map at compile time: %{"tool_name" => "scope string"}
    scope_map =
      tools
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn tool, acc ->
        case Map.get(tool, :scope) do
          nil -> acc
          scope -> Map.put(acc, to_string(tool.name), scope)
        end
      end)

    quote do
      # Use pre-built schemas
      @tools unquote(Macro.escape(tool_schemas))
      @prompts unquote(Macro.escape(prompt_schemas))
      @resources unquote(Macro.escape(resource_schemas))

      # Inject validation schema lookup functions
      unquote(validation_lookup_functions)

      # Scope lookup for OAuth enforcement
      def __scope_for_tool__(tool_name) do
        Map.get(unquote(Macro.escape(scope_map)), tool_name)
      end

      # Always generate handle_list_tools (empty list if no tools)
      def handle_list_tools(_conn) do
        {:ok, %{"tools" => @tools}}
      end

      # Inject generated tool handler clauses
      unquote(tool_clauses)

      # Catch-all for unknown tools
      if unquote(length(tools)) > 0 do
        def handle_call_tool(_conn, tool_name, _params) do
          {:error,
           %{
             "code" => ConduitMcp.Errors.method_not_found(),
             "message" => "Tool not found: #{tool_name}"
           }}
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
          {:error,
           %{
             "code" => ConduitMcp.Errors.method_not_found(),
             "message" => "Prompt not found: #{prompt_name}"
           }}
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
          {:error,
           %{
             "code" => ConduitMcp.Errors.method_not_found(),
             "message" => "Resource not found: #{uri}"
           }}
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
            description:
              "Tool '#{tool_name}' has no handler defined. Use 'handle fn ... end' or 'handle Module, :function'"
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
            description:
              "Prompt '#{prompt_name}' has no get handler defined. Use 'get fn ... end' or 'get Module, :function'"
      end
    end)
  end

  # Generate resource handler clauses outside quote block
  defp generate_resource_clauses(resources) do
    resources_with_handlers =
      resources
      |> Enum.reverse()
      |> Enum.filter(fn %{handler: handler} -> handler != nil end)

    if Enum.empty?(resources_with_handlers) do
      []
    else
      # Separate static URIs (no {param}) from templated URIs
      {static, templated} =
        Enum.split_with(resources_with_handlers, fn %{uri: uri} ->
          not String.contains?(uri, "{")
        end)

      static_clauses = Enum.map(static, &generate_static_resource_clause/1)
      templated_clause = generate_templated_resource_clauses(templated)

      static_clauses ++ templated_clause
    end
  end

  # Static URIs get direct pattern-match clauses — O(1) dispatch
  defp generate_static_resource_clause(%{uri: res_uri, handler: {:fn_ast, handler_ast}}) do
    quote do
      def handle_read_resource(conn, unquote(res_uri)) do
        unquote(handler_ast).(conn, %{}, %{})
      end
    end
  end

  defp generate_static_resource_clause(%{uri: res_uri, handler: {:mfa, {mod, fun}}}) do
    quote do
      def handle_read_resource(conn, unquote(res_uri)) do
        apply(unquote(mod), unquote(fun), [conn, %{}, %{}])
      end
    end
  end

  defp generate_static_resource_clause(%{uri: res_uri, handler: {:app_view, view_path}}) do
    quote do
      def handle_read_resource(_conn, unquote(res_uri)) do
        {:ok,
         %{
           "contents" => [
             %{
               "mimeType" => "text/html;profile=mcp-app",
               "text" => File.read!(unquote(view_path))
             }
           ]
         }}
      end
    end
  end

  # Templated URIs use pre-compiled regex scan
  defp generate_templated_resource_clauses([]), do: []

  defp generate_templated_resource_clauses(templated) do
    template_clauses = Enum.map(templated, &generate_templated_resource_match/1)

    [
      quote do
        def handle_read_resource(conn, uri) do
          result =
            unquote(template_clauses)
            |> Enum.find_value(fn clause_result ->
              case clause_result do
                nil -> false
                other -> other
              end
            end)

          case result do
            nil ->
              {:error,
               %{
                 "code" => ConduitMcp.Errors.method_not_found(),
                 "message" => "Resource not found: #{uri}"
               }}

            result ->
              result
          end
        end
      end
    ]
  end

  defp generate_templated_resource_match(%{uri: res_uri, handler: {:fn_ast, handler_ast}}) do
    {param_names, regex} = ConduitMcp.DSL.compile_uri_template(res_uri)

    quote do
      case ConduitMcp.DSL.extract_uri_params_compiled(
             uri,
             unquote(param_names),
             unquote(Macro.escape(regex))
           ) do
        {:ok, params} -> unquote(handler_ast).(conn, params, %{})
        :no_match -> nil
      end
    end
  end

  defp generate_templated_resource_match(%{uri: res_uri, handler: {:mfa, {mod, fun}}}) do
    {param_names, regex} = ConduitMcp.DSL.compile_uri_template(res_uri)

    quote do
      case ConduitMcp.DSL.extract_uri_params_compiled(
             uri,
             unquote(param_names),
             unquote(Macro.escape(regex))
           ) do
        {:ok, params} -> apply(unquote(mod), unquote(fun), [conn, params, %{}])
        :no_match -> nil
      end
    end
  end

  defp generate_templated_resource_match(%{uri: res_uri, handler: {:app_view, view_path}}) do
    {param_names, regex} = ConduitMcp.DSL.compile_uri_template(res_uri)

    quote do
      case ConduitMcp.DSL.extract_uri_params_compiled(
             uri,
             unquote(param_names),
             unquote(Macro.escape(regex))
           ) do
        {:ok, _params} ->
          {:ok,
           %{
             "contents" => [
               %{
                 "mimeType" => "text/html;profile=mcp-app",
                 "text" => File.read!(unquote(view_path))
               }
             ]
           }}

        :no_match ->
          nil
      end
    end
  end

  @doc false
  def extract_uri_params(template, uri) do
    {param_names, regex} = compile_uri_template(template)
    extract_uri_params_compiled(uri, param_names, regex)
  end

  @doc """
  Pre-compiles a URI template into a regex and parameter name list.

  Returns `{param_names, compiled_regex}` suitable for passing to
  `extract_uri_params_compiled/3`. Call this at compile time and store
  the result to avoid re-compiling the regex on every request.
  """
  def compile_uri_template(template) do
    param_names =
      Regex.scan(~r/\{([^}]+)\}/, template)
      |> Enum.map(fn [_full, name] -> name end)

    template_with_tokens = Regex.replace(~r/\{[^}]+\}/, template, "<<<PARAM>>>")
    escaped_template = Regex.escape(template_with_tokens)
    pattern = String.replace(escaped_template, "<<<PARAM>>>", "([^/]+)")
    {:ok, regex} = Regex.compile("^#{pattern}$")

    {param_names, regex}
  end

  @doc """
  Matches a URI against a pre-compiled template regex.

  Uses the output of `compile_uri_template/1` to avoid runtime regex compilation.
  """
  def extract_uri_params_compiled(uri, param_names, regex) do
    case Regex.run(regex, uri) do
      nil ->
        :no_match

      [_full | captured_values] ->
        {:ok, Map.new(Enum.zip(param_names, captured_values))}
    end
  end
end
