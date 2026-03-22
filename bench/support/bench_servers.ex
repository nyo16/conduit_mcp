# Benchmark server modules for performance testing.
# These are compiled at runtime by bench_helper.exs.

# --- DSL Mode Server ---

defmodule Bench.DSLServer do
  use ConduitMcp.Server

  import ConduitMcp.DSL.Helpers

  tool "echo", "Echo back a message" do
    param(:message, :string, "The message to echo", required: true)
    handle(fn _conn, %{"message" => msg} -> text(msg) end)
  end

  tool "create_user", "Create a user with multiple fields" do
    param(:name, :string, "Full name", required: true, min_length: 1, max_length: 100)
    param(:email, :string, "Email address", required: true)
    param(:age, :integer, "Age", required: true, min: 0, max: 150)
    param(:role, :string, "User role", required: true, enum: ["admin", "user", "moderator"])
    param(:active, :boolean, "Is active", required: true)
    handle(fn _conn, params -> text("Created user: #{params["name"]}") end)
  end

  tool "bulk_import", "Import many fields for benchmarking" do
    param(:field_1, :string, "Field 1", required: true)
    param(:field_2, :string, "Field 2", required: true)
    param(:field_3, :string, "Field 3", required: true)
    param(:field_4, :string, "Field 4", required: true)
    param(:field_5, :string, "Field 5", required: true)
    param(:field_6, :string, "Field 6")
    param(:field_7, :string, "Field 7")
    param(:field_8, :string, "Field 8")
    param(:field_9, :string, "Field 9")
    param(:field_10, :string, "Field 10")
    param(:field_11, :string, "Field 11")
    param(:field_12, :string, "Field 12")
    param(:field_13, :string, "Field 13")
    param(:field_14, :string, "Field 14")
    param(:field_15, :string, "Field 15")
    param(:field_16, :string, "Field 16")
    param(:field_17, :string, "Field 17")
    param(:field_18, :string, "Field 18")
    param(:field_19, :string, "Field 19")
    param(:field_20, :string, "Field 20")
    handle(fn _conn, _params -> text("Imported") end)
  end

  resource "user://{id}" do
    description("Read user by ID")
    mime_type("text/plain")

    read(fn _conn, params, _opts ->
      id = params["id"]

      {:ok,
       %{
         "contents" => [
           %{"uri" => "user://#{id}", "mimeType" => "text/plain", "text" => "User #{id}"}
         ]
       }}
    end)
  end

  resource "project://{org}/{repo}" do
    description("Read project")
    mime_type("text/plain")

    read(fn _conn, params, _opts ->
      org = params["org"]
      repo = params["repo"]

      {:ok,
       %{
         "contents" => [
           %{
             "uri" => "project://#{org}/#{repo}",
             "mimeType" => "text/plain",
             "text" => "Project #{org}/#{repo}"
           }
         ]
       }}
    end)
  end

  prompt "code_review", "Review code" do
    arg(:code, :string, "Code to review", required: true)
    arg(:language, :string, "Programming language")
    arg(:style, :string, "Review style", enum: ["brief", "detailed"])

    get(fn _conn, %{"code" => code} ->
      {:ok,
       %{
         "messages" => [
           %{"role" => "user", "content" => %{"type" => "text", "text" => "Review: #{code}"}}
         ]
       }}
    end)
  end
end

# --- Manual Mode Server ---

defmodule Bench.ManualServer do
  use ConduitMcp.Server, dsl: false

  @tools [
    %{
      "name" => "echo",
      "description" => "Echo back a message",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"message" => %{"type" => "string"}},
        "required" => ["message"]
      }
    },
    %{
      "name" => "create_user",
      "description" => "Create a user",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "email" => %{"type" => "string"},
          "age" => %{"type" => "integer"},
          "role" => %{"type" => "string"},
          "active" => %{"type" => "boolean"}
        },
        "required" => ["name", "email", "age", "role", "active"]
      }
    }
  ]

  @resources [
    %{"uri" => "user://{id}", "name" => "User", "mimeType" => "text/plain"}
  ]

  @prompts [
    %{"name" => "code_review", "description" => "Review code"}
  ]

  @impl true
  def handle_list_tools(_conn), do: {:ok, %{"tools" => @tools}}

  @impl true
  def handle_call_tool(_conn, "echo", %{"message" => msg}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => msg}]}}
  end

  def handle_call_tool(_conn, "create_user", %{"name" => name}) do
    {:ok, %{"content" => [%{"type" => "text", "text" => "Created: #{name}"}]}}
  end

  def handle_call_tool(_conn, name, _params) do
    {:error, %{"code" => -32601, "message" => "Tool not found: #{name}"}}
  end

  @impl true
  def handle_list_resources(_conn), do: {:ok, %{"resources" => @resources}}

  @impl true
  def handle_read_resource(_conn, "user://" <> id) do
    {:ok,
     %{
       "contents" => [
         %{"uri" => "user://#{id}", "mimeType" => "text/plain", "text" => "User #{id}"}
       ]
     }}
  end

  def handle_read_resource(_conn, uri) do
    {:error, %{"code" => -32002, "message" => "Not found: #{uri}"}}
  end

  @impl true
  def handle_list_prompts(_conn), do: {:ok, %{"prompts" => @prompts}}

  @impl true
  def handle_get_prompt(_conn, "code_review", %{"code" => code}) do
    {:ok,
     %{
       "messages" => [
         %{"role" => "user", "content" => %{"type" => "text", "text" => "Review: #{code}"}}
       ]
     }}
  end

  def handle_get_prompt(_conn, name, _args) do
    {:error, %{"code" => -32601, "message" => "Prompt not found: #{name}"}}
  end
end

# --- Component Mode ---

defmodule Bench.EchoComponent do
  use ConduitMcp.Component, type: :tool, description: "Echo text back"

  schema do
    field(:message, :string, "The message to echo", required: true)
  end

  @impl true
  def execute(%{message: msg}, _conn) do
    text(msg)
  end
end

defmodule Bench.UserComponent do
  use ConduitMcp.Component,
    type: :tool,
    name: "create_user",
    description: "Create a user"

  schema do
    field(:name, :string, "Full name", required: true, min_length: 1, max_length: 100)
    field(:email, :string, "Email address", required: true)
    field(:age, :integer, "Age", required: true, min: 0, max: 150)
    field(:role, :string, "User role", required: true, enum: ["admin", "user", "moderator"])
    field(:active, :boolean, "Is active", required: true)
  end

  @impl true
  def execute(%{name: name}, _conn) do
    text("Created user: #{name}")
  end
end

defmodule Bench.UserResource do
  use ConduitMcp.Component,
    type: :resource,
    uri: "user://{id}",
    description: "Read user by ID",
    mime_type: "text/plain"

  @impl true
  def execute(%{id: id}, _conn) do
    {:ok,
     %{
       "contents" => [
         %{"uri" => "user://#{id}", "mimeType" => "text/plain", "text" => "User #{id}"}
       ]
     }}
  end
end

defmodule Bench.CodeReviewPrompt do
  use ConduitMcp.Component, type: :prompt, description: "Review code"

  schema do
    field(:code, :string, "Code to review", required: true)
    field(:language, :string, "Programming language")
  end

  @impl true
  def execute(%{code: code}, _conn) do
    {:ok,
     %{
       "messages" => [
         %{"role" => "user", "content" => %{"type" => "text", "text" => "Review: #{code}"}}
       ]
     }}
  end
end

# --- Endpoint Mode Server ---

defmodule Bench.EndpointServer do
  use ConduitMcp.Endpoint,
    name: "Bench Endpoint",
    version: "1.0.0"

  component(Bench.EchoComponent)
  component(Bench.UserComponent)
  component(Bench.UserResource)
  component(Bench.CodeReviewPrompt)
end
