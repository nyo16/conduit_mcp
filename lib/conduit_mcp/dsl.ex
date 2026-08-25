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
      @mcp_current_scope nil
      @mcp_current_tool_meta nil
      @mcp_current_tool_title nil
      @mcp_current_tool_icons nil
      @mcp_current_tool_output_schema nil
      @mcp_current_tool_task_support nil

      unquote(block)

      # After block executes, store the complete tool definition
      @mcp_tools %{
        name: @mcp_current_tool_name,
        description: @mcp_current_tool_description,
        params: Enum.reverse(@mcp_current_tool_params),
        handler: @mcp_current_tool_handler,
        annotations: @mcp_current_tool_annotations,
        scope: @mcp_current_scope,
        meta: @mcp_current_tool_meta,
        title: @mcp_current_tool_title,
        icons: @mcp_current_tool_icons,
        output_schema: @mcp_current_tool_output_schema,
        task_support: @mcp_current_tool_task_support
      }

      # Clean up
      Module.delete_attribute(__MODULE__, :mcp_current_tool_name)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_description)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_params)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_handler)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_annotations)
      Module.delete_attribute(__MODULE__, :mcp_current_scope)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_meta)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_title)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_icons)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_output_schema)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_task_support)
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
  Sets a required OAuth scope for a tool, resource, or prompt.

  `ConduitMcp.Handler` checks the declared scope against
  `ConduitMcp.Principal.scopes/1` before dispatching. A request with no
  principal has no scopes, so a scoped declaration **fails closed**.

  Must be called inside a `tool`, `app`, `resource` or `prompt` block; calling
  it anywhere else raises at compile time rather than silently enforcing
  nothing.

  ## Examples

      tool "delete_user", "Deletes a user" do
        scope "users:write"
        param :id, :string, "User ID", required: true
        handle fn _conn, %{"id" => id} -> ... end
      end

      resource "vault://{id}" do
        scope "vault:read"
        read fn _conn, params, _opts -> ... end
      end

      prompt "code_review", "Reviews code" do
        scope "review:run"
        get fn _conn, args -> ... end
      end

  A scope declared on a URI template covers every URI that template serves.

  Multiple scopes are required by passing a space-separated string; **all**
  of them must be present:

      tool "admin_action", "Admin only" do
        scope "admin users:write"
        handle fn _conn, _params -> ... end
      end
  """
  defmacro scope(scope_string) do
    quote do
      ConduitMcp.DSL.__assert_in_declaration__(__MODULE__, :scope)
      @mcp_current_scope unquote(scope_string)
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
  Sets a human-readable display title for a tool.

  Distinct from `name` (the machine identifier used in `tools/call`),
  `title` is shown to end users by MCP clients. Added in MCP spec
  2025-11-25.

  ## Example

      tool "create_user", "Create a user account" do
        title "Create User"
        param :email, :string, "Email address", required: true
        handle MyUsers, :create
      end
  """
  defmacro title(value) do
    quote do
      @mcp_current_tool_title unquote(value)
    end
  end

  @doc """
  Sets icon descriptors for a tool. Added in MCP spec 2025-11-25.

  Accepts a list of icon maps, each with `src` (URL or data URI),
  optional `mimeType`, `width`, `height`. Clients use these to render
  the tool in their UI.

  ## Example

      tool "search", "Search the catalog" do
        icons [%{"src" => "https://example.com/search.svg", "mimeType" => "image/svg+xml"}]
        handle MyCatalog, :search
      end
  """
  defmacro icons(icon_list) do
    quote do
      @mcp_current_tool_icons unquote(icon_list)
    end
  end

  @doc """
  Sets the JSON Schema for the tool's structured output.

  When a tool returns a structured payload (via `structured/2` helper
  or by including `"structuredContent"` in the result map), this schema
  describes its shape so clients can render/validate it. Added in MCP
  spec 2025-11-25.

  ## Example

      tool "get_user", "Fetch a user" do
        param :id, :string, "User id", required: true
        output_schema %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "email" => %{"type" => "string"}
          },
          "required" => ["id", "email"]
        }
        handle MyUsers, :get
      end
  """
  defmacro output_schema(schema) do
    quote do
      @mcp_current_tool_output_schema unquote(schema)
    end
  end

  @doc """
  Declares the tool's support for asynchronous task execution.

  Values:

  - `:none` (default, not emitted) — tool always returns synchronously
  - `:supported` — tool MAY return a task id for long-running operations;
    clients can poll `tasks/get` and receive results via `tasks/result`
  - `:required` — tool ALWAYS returns a task id; the immediate response
    contains no result, only a task id to poll

  Added in MCP spec 2025-11-25.

  ## Example

      tool "render_video", "Render a video from a script" do
        task_support :supported
        param :script, :string, "Script source", required: true
        handle MyRenderer, :start
      end
  """
  defmacro task_support(level) when level in [:none, :supported, :required] do
    quote do
      @mcp_current_tool_task_support unquote(level)
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

  ## Object Options

  - `:additional_properties` - Whether keys the block did not declare are
    accepted. Defaults to `false` when the object declares fields and `true`
    when it does not. Also drives `"additionalProperties"` in the generated
    JSON Schema, so the published schema always matches what is enforced.

  ## Object and Array Parameters

  Pass a block to declare structure. Nested fields are enforced at runtime to
  any depth — required, types, and every constraint above — and undeclared keys
  are rejected. `opts` may be omitted; `param :bag, :object do ... end` and
  `param :bag, :object, "desc" do ... end` both work.

      # Nested object, enforced
      param :user, :object, "User data", required: true do
        field :name, :string, "Full name", required: true
        field :address, :object, "Address" do
          field :city, :string, "City", required: true
        end
      end

      # Open object — any keys, nothing enforced
      param :metadata, :object, "Arbitrary metadata"

      # Declared fields enforced, everything else passed through
      param :bag, :object, "Bag", additional_properties: true do
        field :name, :string, "Name", required: true
      end

      # Array item type
      param :rows, :array, "Rows" do
        items :object do
          field :id, :integer, "Row id", required: true
        end
      end

  Array item schemas are published for clients but not enforced server-side:
  NimbleOptions cannot attach a nested schema to a list element type.

  Handlers always receive string keys, at every depth.

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

  # Elixir appends a `do` block as a trailing `[do: ...]` keyword list, so
  # `param :bag, :object do ... end` and `param :bag, :object, "desc" do ... end`
  # both arrive as `param/4` with a list that satisfies `is_list(opts)`. Without
  # these two clauses they bind to the blockless clause below, which evaluates
  # the block into `:description`/`:opts` and silently drops the nested fields.
  defmacro param(name, type, [{:do, nested_block}], []) do
    build_block_param(name, type, nil, [], nested_block, __CALLER__)
  end

  defmacro param(name, type, description, [{:do, nested_block}]) do
    {description, opts} = split_description_opts(description)
    build_block_param(name, type, description, opts, nested_block, __CALLER__)
  end

  defmacro param(name, type, description, opts) when is_list(opts) do
    assert_no_block!(:param, name, description, opts, __CALLER__)

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
  defmacro param(name, type, description, opts, do: nested_block) do
    build_block_param(name, type, description, opts, nested_block, __CALLER__)
  end

  defp build_block_param(name, :object, description, opts, nested_block, _caller) do
    quote do
      parent_nested =
        ConduitMcp.DSL.FieldScope.open(__MODULE__, :mcp_current_nested_params)

      unquote(nested_block)

      param_def = %{
        name: unquote(name),
        type: :object,
        description: unquote(description),
        opts: unquote(opts),
        nested:
          ConduitMcp.DSL.FieldScope.close(
            __MODULE__,
            :mcp_current_nested_params,
            parent_nested
          ),
        items: nil
      }

      current_params = Module.get_attribute(__MODULE__, :mcp_current_tool_params) || []
      Module.put_attribute(__MODULE__, :mcp_current_tool_params, [param_def | current_params])
    end
  end

  defp build_block_param(name, :array, description, opts, nested_block, _caller) do
    quote do
      # Hide any enclosing field scope: an `:array` block collects an item type
      # through `items`, so a bare `field` here has nowhere to land and must be
      # rejected rather than silently absorbed.
      parent_nested =
        ConduitMcp.DSL.FieldScope.hide(__MODULE__, :mcp_current_nested_params)

      @mcp_current_array_items nil

      unquote(nested_block)

      items = Module.get_attribute(__MODULE__, :mcp_current_array_items)
      Module.delete_attribute(__MODULE__, :mcp_current_array_items)
      ConduitMcp.DSL.FieldScope.restore(__MODULE__, :mcp_current_nested_params, parent_nested)

      param_def = %{
        name: unquote(name),
        type: :array,
        description: unquote(description),
        opts: unquote(opts),
        nested: nil,
        items: items
      }

      current_params = Module.get_attribute(__MODULE__, :mcp_current_tool_params) || []
      Module.put_attribute(__MODULE__, :mcp_current_tool_params, [param_def | current_params])
    end
  end

  defp build_block_param(name, type, _description, _opts, _nested_block, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "param #{Macro.to_string(name)}: the block form is only supported for " <>
          ":object and :array params, got: #{Macro.to_string(type)}"
  end

  # `param :bag, :object, required: true do ... end` — description omitted.
  # Elixir collapses the trailing keywords into the third argument, so without
  # this the opts were silently dropped (the param became optional, and
  # `additional_properties` was ignored) *and* the keyword list landed in
  # `"description"`, which is not JSON-encodable — breaking `tools/list` for the
  # whole server. A description is a string, so a keyword list here is opts.
  defp split_description_opts([]), do: {nil, []}
  defp split_description_opts([{key, _} | _] = opts) when is_atom(key), do: {nil, opts}
  defp split_description_opts(description), do: {description, []}

  # The clauses that route a trailing `[do: ...]` to the block form depend on
  # argument positions that only the default-injecting header produces. Change a
  # default and they quietly stop matching, and a block silently falls through to
  # the blockless clause below — which evaluates it into `:description`/`:opts`,
  # exactly the bug this module was fixed for. Fail loudly instead.
  defp assert_no_block!(macro, name, description, opts, caller) do
    if block?(description) or block?(opts) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "#{macro} #{Macro.to_string(name)}: a `do` block reached the blockless clause. " <>
            "This is a bug in ConduitMcp's macro dispatch — please report it."
    end

    :ok
  end

  defp block?([{:do, _} | _]), do: true
  defp block?(_), do: false

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

  # Same trailing-`[do: ...]` trap as `param/4` — see the comment there.
  defmacro field(name, type, [{:do, nested_block}], []) do
    build_block_field(name, type, nil, [], nested_block, __CALLER__)
  end

  defmacro field(name, type, description, [{:do, nested_block}]) do
    {description, opts} = split_description_opts(description)
    build_block_field(name, type, description, opts, nested_block, __CALLER__)
  end

  defmacro field(name, type, description, opts) when is_list(opts) do
    assert_no_block!(:field, name, description, opts, __CALLER__)

    quote do
      field_def = %{
        name: unquote(name),
        type: unquote(type),
        description: unquote(description),
        opts: unquote(opts),
        nested: nil,
        items: nil
      }

      ConduitMcp.DSL.__push_nested_field__(__MODULE__, field_def, __ENV__)
    end
  end

  defmacro field(name, type, description, opts, do: nested_block) do
    build_block_field(name, type, description, opts, nested_block, __CALLER__)
  end

  defp build_block_field(name, :object, description, opts, nested_block, _caller) do
    quote do
      parent_nested =
        ConduitMcp.DSL.FieldScope.open(__MODULE__, :mcp_current_nested_params)

      unquote(nested_block)

      nested_fields =
        ConduitMcp.DSL.FieldScope.close(__MODULE__, :mcp_current_nested_params, parent_nested)

      field_def = %{
        name: unquote(name),
        type: :object,
        description: unquote(description),
        opts: unquote(opts),
        nested: nested_fields,
        items: nil
      }

      ConduitMcp.DSL.__push_nested_field__(__MODULE__, field_def, __ENV__)
    end
  end

  defp build_block_field(name, type, _description, _opts, _nested_block, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "field #{Macro.to_string(name)}: the block form is only supported for " <>
          ":object fields, got: #{Macro.to_string(type)}"
  end

  @doc """
  Defines the item type for an array parameter.

  Item schemas are published to clients in the JSON Schema but are **not**
  enforced server-side — NimbleOptions cannot attach a nested schema to a list
  element type. Validate item contents in your handler.

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
      ConduitMcp.DSL.__assert_in_array_block__(__MODULE__, __ENV__)
      @mcp_current_array_items %{type: unquote(type), nested: nil}
    end
  end

  defmacro items(type, do: nested_block), do: build_items(type, nested_block, __CALLER__)

  defp build_items(:object, nested_block, _caller) do
    quote do
      ConduitMcp.DSL.__assert_in_array_block__(__MODULE__, __ENV__)

      parent_nested =
        ConduitMcp.DSL.FieldScope.open(__MODULE__, :mcp_current_nested_params)

      unquote(nested_block)

      @mcp_current_array_items %{
        type: :object,
        nested:
          ConduitMcp.DSL.FieldScope.close(
            __MODULE__,
            :mcp_current_nested_params,
            parent_nested
          )
      }
    end
  end

  defp build_items(type, _nested_block, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description:
        "items: the block form is only supported for :object items, " <>
          "got: #{Macro.to_string(type)}"
  end

  @doc false
  # Single choke point for every `field` declaration. `field` is only meaningful
  # inside an `:object` block or an `items :object` block; anywhere else it used
  # to be silently absorbed and dropped.
  def __push_nested_field__(module, field_def, env) do
    cond do
      ConduitMcp.DSL.FieldScope.open?(module, :mcp_current_nested_params) ->
        ConduitMcp.DSL.FieldScope.prepend(module, :mcp_current_nested_params, field_def)

      ConduitMcp.DSL.FieldScope.open?(module, :mcp_current_array_items) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "field #{inspect(field_def.name)}: an :array param block declares its item " <>
              "type with `items`, not `field` — use `items :object do ... end`"

      true ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "field #{inspect(field_def.name)}: `field` is only valid inside an :object " <>
              "param block or an `items :object` block — did you mean `param`?"
    end
  end

  @doc false
  # An `:array` block hides any enclosing field scope, so "inside an array block"
  # is precisely "array open and no field scope open". The looser check also
  # accepted `items` nested inside `items :object do ... end`, where the inner
  # declaration was overwritten and silently vanished.
  def __assert_in_array_block__(module, env) do
    cond do
      not ConduitMcp.DSL.FieldScope.open?(module, :mcp_current_array_items) or
          ConduitMcp.DSL.FieldScope.open?(module, :mcp_current_nested_params) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "items is only valid directly inside an :array param block"

      Module.get_attribute(module, :mcp_current_array_items) != nil ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description:
            "items: an :array param block declares exactly one item type, " <>
              "and one is already declared here"

      true ->
        :ok
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
      @mcp_current_scope nil

      unquote(block)

      @mcp_prompts %{
        name: @mcp_current_prompt_name,
        description: @mcp_current_prompt_description,
        args: Enum.reverse(@mcp_current_prompt_args),
        handler: @mcp_current_prompt_handler,
        completions: @mcp_current_prompt_completions,
        scope: @mcp_current_scope
      }

      Module.delete_attribute(__MODULE__, :mcp_current_prompt_name)
      Module.delete_attribute(__MODULE__, :mcp_current_prompt_description)
      Module.delete_attribute(__MODULE__, :mcp_current_prompt_args)
      Module.delete_attribute(__MODULE__, :mcp_current_prompt_handler)
      Module.delete_attribute(__MODULE__, :mcp_current_prompt_completions)
      Module.delete_attribute(__MODULE__, :mcp_current_scope)
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
      @mcp_current_scope nil

      unquote(block)

      @mcp_resources %{
        uri: @mcp_current_resource_uri,
        description: @mcp_current_resource_description,
        mime_type: @mcp_current_resource_mime_type,
        handler: @mcp_current_resource_handler,
        completions: @mcp_current_resource_completions,
        scope: @mcp_current_scope
      }

      Module.delete_attribute(__MODULE__, :mcp_current_resource_uri)
      Module.delete_attribute(__MODULE__, :mcp_current_resource_description)
      Module.delete_attribute(__MODULE__, :mcp_current_resource_mime_type)
      Module.delete_attribute(__MODULE__, :mcp_current_resource_handler)
      Module.delete_attribute(__MODULE__, :mcp_current_resource_completions)
      Module.delete_attribute(__MODULE__, :mcp_current_scope)
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
      @mcp_current_scope nil
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
        scope: @mcp_current_scope,
        meta: @mcp_current_tool_meta
      }

      # Store the resource for the UI HTML — use :app_view handler type which
      # generate_resource_clauses expands into File.read! at compile time.
      # The UI resource inherits the app tool's scope: the HTML is part of the
      # same capability, so serving it unscoped would leak the surface the
      # scope exists to protect.
      @mcp_resources %{
        uri: app_resource_uri,
        description: "UI for #{unquote(name)}",
        mime_type: "text/html;profile=mcp-app",
        handler: {:app_view, app_view_path},
        completions: [],
        scope: @mcp_current_scope
      }

      # Clean up
      Module.delete_attribute(__MODULE__, :mcp_current_tool_name)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_description)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_params)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_handler)
      Module.delete_attribute(__MODULE__, :mcp_current_tool_annotations)
      Module.delete_attribute(__MODULE__, :mcp_current_scope)
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

    reversed_tools = Enum.reverse(tools)
    reversed_prompts = Enum.reverse(prompts)

    tool_schemas = Enum.map(reversed_tools, &ConduitMcp.DSL.SchemaBuilder.build_tool_schema/1)

    prompt_schemas =
      Enum.map(reversed_prompts, &ConduitMcp.DSL.SchemaBuilder.build_prompt_schema/1)

    {templated_resources, resource_schemas, resource_template_schemas} =
      partition_resources(resources)

    validation_lookup_functions =
      ConduitMcp.DSL.SchemaBuilder.generate_validation_lookup_functions(
        reversed_tools,
        reversed_prompts
      )

    log_schema_validation_warnings(reversed_tools, reversed_prompts)

    tool_clauses = generate_tool_clauses(tools)
    prompt_clauses = generate_prompt_clauses(prompts)
    resource_clauses = generate_resource_clauses(resources)

    tool_scopes = build_scope_map(reversed_tools, &to_string(&1.name))
    prompt_scopes = build_scope_map(reversed_prompts, &to_string(&1.name))
    # Handler-less resources are dropped: `generate_resource_clauses/1` filters
    # them out too (`:1583`), so including one here would put a template in
    # `__scope_for_resource__/1`'s ordered scan with no matching dispatch
    # clause. If it overlapped a later scoped-and-handled template, the scan
    # would stop at the handler-less one and enforce *its* scope while
    # `handle_read_resource/2` ran the other's handler — precisely the
    # order mismatch the comment on `build_scope_map/2` says this ordering
    # prevents. It fails closed, but it enforces the wrong scope.
    resource_scopes =
      resources
      |> Enum.reverse()
      |> Enum.filter(&(&1.handler != nil))
      |> build_scope_map(& &1.uri)

    templated_resource_clause? = templated_resource_clause?(resources)
    templated_uris = Enum.map(templated_resources, & &1.uri)

    quote do
      # Use pre-built schemas
      @tools unquote(Macro.escape(tool_schemas))
      @prompts unquote(Macro.escape(prompt_schemas))
      @resources unquote(Macro.escape(resource_schemas))
      @resource_templates unquote(Macro.escape(resource_template_schemas))

      # Eagerly compile templated-resource regexes into persistent_term at
      # module load. Avoids per-request Regex.recompile/1 (Macro.escape
      # strips the native re_pattern, so embedding the regex literal would
      # force a recompile in every Bandit request process).
      @on_load :__precompile_template_regexes__

      def __precompile_template_regexes__ do
        Enum.each(
          unquote(templated_uris),
          &ConduitMcp.DSL.precompile_template_regex(__MODULE__, &1)
        )

        :ok
      end

      # Inject validation schema lookup functions
      unquote(validation_lookup_functions)

      # Scope lookups for OAuth enforcement — tools, prompts and resources.
      # Each family ends in a `nil` catch-all so Elixir's type checker does
      # not flag a lookup against a compile-time empty map when no scopes are
      # declared.
      unquote(
        ConduitMcp.DSL.__generate_scope_clauses__(tool_scopes, prompt_scopes, resource_scopes)
      )

      # Always generate handle_list_tools (empty list if no tools)
      def handle_list_tools(_conn) do
        {:ok, %{"tools" => @tools}}
      end

      # Inject generated tool handler clauses
      unquote(tool_clauses)

      # Catch-all for unknown tools. `-32602` per the MCP specification
      # ("Unknown tool: invalid_tool_name"); the same code and message shape
      # is produced by `ConduitMcp.Handler` and by Endpoint mode.
      if unquote(length(tools)) > 0 do
        def handle_call_tool(_conn, tool_name, _params) do
          {:error,
           %{
             "code" => ConduitMcp.Errors.invalid_params(),
             "message" => "Unknown tool: #{ConduitMcp.Reflect.text(tool_name)}"
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
             "code" => ConduitMcp.Errors.invalid_params(),
             "message" => "Unknown prompt: #{ConduitMcp.Reflect.text(prompt_name)}"
           }}
        end
      end

      # Always generate handle_list_resources (empty list if no resources)
      def handle_list_resources(_conn) do
        {:ok, %{"resources" => @resources}}
      end

      def handle_list_resource_templates(_conn) do
        {:ok, %{"resourceTemplates" => @resource_templates}}
      end

      # Inject generated resource handler clauses
      unquote(resource_clauses)

      # Catch-all for unknown resources. Only needed when no templated-resource
      # clause was generated — that clause matches any URI and already returns
      # not-found when no template matches. Without this, a server whose
      # resources are all static raised FunctionClauseError on an unknown URI
      # and the client saw "Internal server error".
      if unquote(length(resources)) > 0 and unquote(not templated_resource_clause?) do
        def handle_read_resource(_conn, uri) do
          {:error,
           %{
             "code" => ConduitMcp.Errors.resource_not_found(),
             "message" => "Resource not found: #{ConduitMcp.Reflect.text(uri)}"
           }}
        end
      end
    end
  end

  defp partition_resources(resources) do
    {templated, static} =
      resources
      |> Enum.reverse()
      |> Enum.split_with(&ConduitMcp.DSL.SchemaBuilder.templated?/1)

    resource_schemas = Enum.map(static, &ConduitMcp.DSL.SchemaBuilder.build_resource_schema/1)

    template_schemas =
      Enum.map(templated, &ConduitMcp.DSL.SchemaBuilder.build_resource_template_schema/1)

    {templated, resource_schemas, template_schemas}
  end

  # True when a templated-resource dispatch clause was generated. That clause
  # matches any URI, so it doubles as the not-found catch-all; emitting another
  # one after it would be a redundant clause.
  defp templated_resource_clause?(resources) do
    resources
    |> Enum.filter(fn %{handler: handler} -> handler != nil end)
    |> Enum.any?(fn %{uri: uri} -> String.contains?(uri, "{") end)
  end

  # Order matters: the emitted `__scope_for_resource__/1` templated scan must
  # walk templates in the same order `handle_read_resource/2` dispatches them,
  # or two overlapping templates enforce one scope and run the other's handler.
  # `Enum.reduce` with a prepend silently reversed the list it was handed.
  defp build_scope_map(entries, name_fun) do
    entries
    |> Enum.flat_map(fn entry ->
      case Map.get(entry, :scope) do
        nil -> []
        scope -> [{name_fun.(entry), __validate_scope__!(scope, name_fun.(entry))}]
      end
    end)
    # De-duplicated because two entries with the same name would emit two
    # identical clause heads, and the second is dead code the reader has to
    # reason about. It is *not* a build fix: clauses injected via `unquote`
    # carry no line metadata, so the compiler emits no "this clause cannot
    # match" diagnostic for them (verified), and first-declaration-wins already
    # held. Keeping the emitted code minimal and the intent explicit is the
    # whole benefit. First declaration wins, matching dispatch order.
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc false
  # An empty or non-binary scope splits to `[]`, and `Enum.all?([], _)` is
  # true — an authorization control present in the source and absent at
  # runtime. Validated here rather than in the `scope/1` macro because the
  # macro only sees AST; by `@before_compile` the value is known.
  #
  # Shared with `ConduitMcp.Component`, so the two authoring modes cannot
  # disagree about whether `scope ""` is legal.
  def __validate_scope__!(scope, subject) when is_binary(scope) do
    if String.split(scope, " ", trim: true) == [] do
      raise CompileError,
        description:
          "#{inspect(subject)}: :scope must name at least one scope; got #{inspect(scope)}"
    end

    scope
  end

  def __validate_scope__!(scope, subject) do
    raise CompileError,
      description:
        "#{inspect(subject)}: :scope must be a space-separated string; got #{inspect(scope)}"
  end

  @doc false
  # Emits the scope lookups every authorization hook in `ConduitMcp.Handler`
  # consults: `__scope_for_tool__/1`, `__scope_for_prompt__/1` and
  # `__scope_for_resource__/1`, each with a `nil` catch-all.
  #
  # `resource_scopes` entries are `{uri_or_template, scope}`. Templated URIs
  # are matched with the same pre-compiled regex machinery the resource
  # dispatch uses, so a scope declared on `"user://{id}"` covers every URI
  # that clause would serve.
  #
  # Shared by `ConduitMcp.DSL` and `ConduitMcp.Endpoint` so a scope cannot be
  # enforced in one authoring mode and silently ignored in the other.
  def __generate_scope_clauses__(tool_scopes, prompt_scopes, resource_scopes) do
    {static_resources, templated_resources} =
      Enum.split_with(resource_scopes, fn {uri, _scope} -> not String.contains?(uri, "{") end)

    tool_clauses =
      Enum.map(tool_scopes, fn {name, scope} ->
        quote do: def(__scope_for_tool__(unquote(name)), do: unquote(scope))
      end)

    prompt_clauses =
      Enum.map(prompt_scopes, fn {name, scope} ->
        quote do: def(__scope_for_prompt__(unquote(name)), do: unquote(scope))
      end)

    static_clauses =
      Enum.map(static_resources, fn {uri, scope} ->
        quote do: def(__scope_for_resource__(unquote(uri)), do: unquote(scope))
      end)

    resource_fallback = generate_resource_scope_fallback(templated_resources)

    quote do
      unquote(tool_clauses)
      def __scope_for_tool__(_tool_name), do: nil

      unquote(prompt_clauses)
      def __scope_for_prompt__(_prompt_name), do: nil

      unquote(static_clauses)
      unquote(resource_fallback)
    end
  end

  # With no scoped templates the fallback is a plain `nil`. With them, the
  # scan *is* the fallback — it returns nil when no template matches, so a
  # separate catch-all would be a redundant clause.
  defp generate_resource_scope_fallback([]) do
    quote do: def(__scope_for_resource__(_uri), do: nil)
  end

  defp generate_resource_scope_fallback(templated) do
    quote do
      def __scope_for_resource__(uri) do
        Enum.find_value(unquote(Macro.escape(templated)), fn {template, scope} ->
          {param_names, regex} = ConduitMcp.DSL.template_regex(__MODULE__, template)

          case ConduitMcp.DSL.extract_uri_params_compiled(uri, param_names, regex) do
            {:ok, _params} -> scope
            :no_match -> nil
          end
        end)
      end
    end
  end

  @doc false
  # `scope/1` used to write `@mcp_current_tool_scope` unconditionally, with no
  # assertion it was inside a declaration — so `scope "admin"` at the top of a
  # module compiled clean and enforced nothing. A silently ignored
  # authorization control is worse than an unsupported one.
  def __assert_in_declaration__(module, macro) do
    unless Module.has_attribute?(module, :mcp_current_scope) do
      raise CompileError,
        description:
          "#{inspect(module)}: #{macro}/1 must be called inside a tool, resource, " <>
            "or prompt block"
    end

    :ok
  end

  defp log_schema_validation_warnings(reversed_tools, reversed_prompts) do
    case ConduitMcp.DSL.SchemaBuilder.validate_all_schemas(reversed_tools, reversed_prompts) do
      :ok ->
        :ok

      {:error, errors} ->
        require Logger
        Logger.warning("Validation schema compilation warnings: #{inspect(errors)}")
    end
  end

  # Generate tool handler clauses outside quote block
  defp generate_tool_clauses(tools) do
    Enum.reverse(tools)
    |> Enum.map(fn %{name: tool_name, handler: handler} ->
      case handler do
        {:fn_ast, handler_ast} ->
          quote do
            def handle_call_tool(conn, unquote(tool_name), params) do
              unquote(handler_ast).(conn, params)
            end
          end

        {:mfa, {mod, fun}} ->
          quote do
            def handle_call_tool(conn, unquote(tool_name), params) do
              apply(unquote(mod), unquote(fun), [conn, params])
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
            def handle_get_prompt(conn, unquote(prompt_name), args) do
              messages = unquote(handler_ast).(conn, args)
              {:ok, %{"messages" => messages}}
            end
          end

        {:mfa, {mod, fun}} ->
          quote do
            def handle_get_prompt(conn, unquote(prompt_name), args) do
              messages = apply(unquote(mod), unquote(fun), [conn, args])
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
                 "code" => ConduitMcp.Errors.resource_not_found(),
                 "message" => "Resource not found: #{ConduitMcp.Reflect.text(uri)}"
               }}

            result ->
              result
          end
        end
      end
    ]
  end

  defp generate_templated_resource_match(%{uri: res_uri, handler: {:fn_ast, handler_ast}}) do
    quote do
      {param_names, regex} = ConduitMcp.DSL.template_regex(__MODULE__, unquote(res_uri))

      case ConduitMcp.DSL.extract_uri_params_compiled(uri, param_names, regex) do
        {:ok, params} -> unquote(handler_ast).(conn, params, %{})
        :no_match -> nil
      end
    end
  end

  defp generate_templated_resource_match(%{uri: res_uri, handler: {:mfa, {mod, fun}}}) do
    quote do
      {param_names, regex} = ConduitMcp.DSL.template_regex(__MODULE__, unquote(res_uri))

      case ConduitMcp.DSL.extract_uri_params_compiled(uri, param_names, regex) do
        {:ok, params} -> apply(unquote(mod), unquote(fun), [conn, params, %{}])
        :no_match -> nil
      end
    end
  end

  defp generate_templated_resource_match(%{uri: res_uri, handler: {:app_view, view_path}}) do
    quote do
      {param_names, regex} = ConduitMcp.DSL.template_regex(__MODULE__, unquote(res_uri))

      case ConduitMcp.DSL.extract_uri_params_compiled(uri, param_names, regex) do
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

  @doc """
  Stores a compiled URI template regex in `:persistent_term` so that it can
  be looked up at request time without paying the per-process
  `Regex.recompile/1` cost incurred when a `Regex` struct is embedded via
  `Macro.escape/1`.

  Called at module load time from generated `@on_load` hooks.
  """
  def precompile_template_regex(module, template) do
    {param_names, regex} = compile_uri_template(template)
    :persistent_term.put({__MODULE__, module, template}, {param_names, regex})
    :ok
  end

  @doc """
  Fetches a `{param_names, regex}` tuple previously stored by
  `precompile_template_regex/2`, falling back to recompiling on cache miss
  (defensive — should not normally happen).
  """
  def template_regex(module, template) do
    case :persistent_term.get({__MODULE__, module, template}, nil) do
      nil ->
        result = compile_uri_template(template)
        :persistent_term.put({__MODULE__, module, template}, result)
        result

      cached ->
        cached
    end
  end
end
