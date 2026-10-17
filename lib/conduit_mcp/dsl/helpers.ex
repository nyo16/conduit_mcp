defmodule ConduitMcp.DSL.Helpers do
  @moduledoc """
  Helper macros for building MCP responses in the DSL.

  These helpers provide a convenient way to construct properly formatted
  MCP responses without manually building the response maps.

  ## Response Helpers

  - `text/1` - Returns a text content response
  - `json/1` - Returns JSON-encoded text content
  - `raw/1` - Returns raw data directly (bypasses MCP content wrapping)
  - `error/1` or `error/2` - Returns an error response
  - `image/2` - Returns an image content response (base64 data + MIME type)
  - `image/1` - Returns a link to an image URL, or image content for base64
    PNG/JPEG/GIF/WebP data

  ## Prompt Message Helpers

  - `system/1` - Creates a system role message
  - `user/1` - Creates a user role message
  - `assistant/1` - Creates an assistant role message

  ## Examples

      # Text response
      text("Hello, world!")
      # => {:ok, %{"content" => [%{"type" => "text", "text" => "Hello, world!"}]}}

      # JSON response
      json(%{status: "ok", count: 42})
      # => {:ok, %{"content" => [%{"type" => "text", "text" => "{\\"status\\":\\"ok\\",\\"count\\":42}"}]}}

      # Raw response (bypasses MCP wrapping)
      raw(%{status: "ok", count: 42})
      # => {:ok, %{"status" => "ok", "count" => 42}}

      # Error response
      error("Not found")
      # => {:error, %{"code" => -32000, "message" => "Not found"}}

      # Custom error code
      error("Invalid params", -32602)
      # => {:error, %{"code" => -32602, "message" => "Invalid params"}}

      # Prompt messages
      [
        system("You are a helpful assistant"),
        user("What is 2+2?")
      ]
  """

  @doc """
  Creates a text content response.

  ## Example

      def handle_call_tool(_conn, "greet", %{"name" => name}) do
        text("Hello, \#{name}!")
      end
  """
  defmacro text(content) do
    quote do
      {:ok,
       %{
         "content" => [
           %{
             "type" => "text",
             "text" => unquote(content)
           }
         ]
       }}
    end
  end

  @doc """
  Creates a JSON-encoded text content response.

  The data will be encoded to JSON using the built-in JSON module.

  ## Example

      def handle_call_tool(_conn, "get_user", %{"id" => id}) do
        user = MyApp.Users.get!(id)
        json(%{id: user.id, name: user.name, email: user.email})
      end
  """
  defmacro json(data) do
    quote do
      {:ok,
       %{
         "content" => [
           %{
             "type" => "text",
             "text" => JSON.encode!(unquote(data))
           }
         ]
       }}
    end
  end

  @doc """
  Returns raw data directly without MCP content wrapping.

  This bypasses the standard MCP content structure and returns the data
  as-is. Useful for debugging or special cases where you need direct
  JSON output without the content array wrapper.

  **Warning**: This breaks MCP compatibility and should only be used
  for debugging or non-MCP endpoints.

  ## Example

      def handle_call_tool(_conn, "debug_user", %{"id" => id}) do
        user = MyApp.Users.get!(id)
        raw(%{id: user.id, name: user.name, email: user.email})
      end

      # Returns: {:ok, %{"id" => 123, "name" => "John", "email" => "john@example.com"}}
      # Instead of: {:ok, %{"content" => [%{"type" => "text", "text" => "{\\"id\\":123,...}"}]}}
  """
  defmacro raw(data) do
    quote do
      {:ok, unquote(data)}
    end
  end

  @doc """
  Creates an error response.

  ## Examples

      error("User not found")
      # => {:error, %{"code" => -32000, "message" => "User not found"}}

      error("Invalid parameters", -32602)
      # => {:error, %{"code" => -32602, "message" => "Invalid parameters"}}
  """
  defmacro error(message, code \\ ConduitMcp.Errors.server_error()) do
    quote do
      {:error,
       %{
         "code" => unquote(code),
         "message" => unquote(message)
       }}
    end
  end

  @doc """
  Reports a tool *execution* error to the client.

  Per MCP spec, tool execution errors (the operation ran but failed in a way
  the LLM can interpret and possibly recover from) are distinct from protocol
  errors. They are returned as a successful result with `"isError" => true`,
  not as a JSON-RPC error. Use `error/2` for protocol errors (bad params,
  internal failures, etc.) and `execution_error/1` for "the call ran but
  this is what went wrong" so the LLM can self-correct.

  ## Example

      tool "fetch_user", "Fetch a user by id" do
        param :id, :string, "User id", required: true

        handle fn _conn, %{"id" => id} ->
          case MyUsers.fetch(id) do
            {:ok, user} -> json(user)
            {:error, :not_found} -> execution_error("User \#{id} not found")
          end
        end
      end
  """
  defmacro execution_error(message) do
    quote do
      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => unquote(message)}],
         "isError" => true
       }}
    end
  end

  @doc """
  Returns a tool response with structured output.

  Per MCP spec 2025-11-25, tools can declare an `outputSchema` and return
  structured data alongside the human-readable `content` array. Clients
  that understand the schema can render/validate the payload; clients
  that don't fall back to the text content.

  Accepts the structured payload (any JSON-encodable map) and an optional
  human-readable message that becomes the text content. If you omit the
  message, the JSON encoding of the payload is used.

  ## Example

      tool "get_user", "Fetch a user" do
        param :id, :string, "User id", required: true

        output_schema %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "email" => %{"type" => "string"}
          }
        }

        handle fn _conn, %{"id" => id} ->
          user = MyUsers.get!(id)
          structured(%{"id" => user.id, "email" => user.email}, "Fetched user \#{id}")
        end
      end
  """
  defmacro structured(payload, message \\ nil) do
    quote do
      text =
        case unquote(message) do
          nil -> JSON.encode!(unquote(payload))
          msg -> msg
        end

      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => text}],
         "structuredContent" => unquote(payload)
       }}
    end
  end

  @doc """
  Creates an MCP `tools/call` response that hands a long-running operation
  off to a task.

  The tool returns immediately with a `task_id`; the client polls
  `tasks/get` / `tasks/result` to retrieve progress and the final result.
  The task itself is tracked by `ConduitMcp.Tasks` — the tool author is
  responsible for spawning the actual work (e.g., via `Task.Supervisor`)
  and updating the task's status with `ConduitMcp.Tasks.update/2`.

  Requires the tool's `task_support` to be `:supported` or `:required`.

  ## Example

      tool "render_video", "Render a video" do
        task_support :supported
        param :script, :string, "Script", required: true

        handle fn _conn, params ->
          task_id = ConduitMcp.Tasks.generate_id()
          {:ok, _} = ConduitMcp.Tasks.create(task_id, %{"tool" => "render_video"})

          Task.Supervisor.start_child(MyApp.Workers, fn ->
            result = MyRenderer.render(params)
            ConduitMcp.Tasks.update(task_id,
              %{"status" => "completed", "result" => result})
          end)

          task(task_id, "Rendering started")
        end
      end
  """
  defmacro task(task_id, message \\ "Task started") do
    quote do
      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => unquote(message)}],
         "_meta" => %{"task" => %{"id" => unquote(task_id)}}
       }}
    end
  end

  @doc """
  Creates an image content response from base64-encoded `data` and its
  `mime_type`, the two fields MCP's `ImageContent` requires.

  ## Example

      handle fn _conn, _params ->
        png = MyCharts.render_png() |> Base.encode64()
        image(png, "image/png")
      end
  """
  defmacro image(data, mime_type) do
    quote do
      {:ok,
       %{
         "content" => [
           %{
             "type" => "image",
             "data" => unquote(data),
             "mimeType" => unquote(mime_type)
           }
         ]
       }}
    end
  end

  @doc """
  Creates an image response from either a URL or base64 image data.

  MCP's `ImageContent` requires base64 `data` **and** a `mimeType`, so:

    * a URL (anything with a URI scheme, e.g. `"https://..."`) becomes a
      `resource_link` content block whose `uri` and `name` are the URL — a
      URL cannot go in `data`, and a link is how a tool result points at
      content it does not embed;
    * base64 PNG, JPEG, GIF or WebP data becomes `ImageContent`, with the
      `mimeType` read from the image's leading bytes;
    * anything else raises `ArgumentError` naming `image/2`, which takes the
      MIME type explicitly.

  ## Example

      def handle_call_tool(_conn, "generate_chart", params) do
        image_url = MyCharts.generate(params)
        image(image_url)
      end
  """
  defmacro image(url_or_data) do
    quote do
      {:ok, %{"content" => [ConduitMcp.DSL.Helpers.__image_content__(unquote(url_or_data))]}}
    end
  end

  @doc false
  # The content block behind `image/1`; see its doc for the three outcomes.
  @spec __image_content__(term()) :: map()
  def __image_content__(url_or_data) when is_binary(url_or_data) do
    case URI.new(url_or_data) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) ->
        %{"type" => "resource_link", "uri" => url_or_data, "name" => url_or_data}

      _ ->
        %{"type" => "image", "data" => url_or_data, "mimeType" => sniff_image_type!(url_or_data)}
    end
  end

  def __image_content__(other) do
    raise ArgumentError,
          "image/1 expects a URL or base64 image data, got: " <>
            inspect(other, limit: 5, printable_limit: 40)
  end

  # 24 base64 characters decode to the 18 leading bytes, enough for every
  # signature below.
  defp sniff_image_type!(data) do
    with <<prefix::binary-size(24), _::binary>> <- data,
         {:ok, bytes} <- Base.decode64(prefix),
         {:ok, mime_type} <- image_signature(bytes) do
      mime_type
    else
      _ ->
        raise ArgumentError,
              "image/1 could not tell the image type of its data (PNG, JPEG, GIF and WebP " <>
                "are recognised); use image(data, mime_type)"
    end
  end

  defp image_signature(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: {:ok, "image/png"}
  defp image_signature(<<0xFF, 0xD8, 0xFF, _::binary>>), do: {:ok, "image/jpeg"}
  defp image_signature(<<"GIF8", v, "a", _::binary>>) when v in ~c"79", do: {:ok, "image/gif"}
  defp image_signature(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: {:ok, "image/webp"}
  defp image_signature(_bytes), do: :error

  @doc """
  Creates an audio content response.

  ## Example

      handle fn _conn, %{"file" => file} ->
        data = File.read!(file) |> Base.encode64()
        audio(data, "audio/wav")
      end
  """
  defmacro audio(data, mime_type) do
    quote do
      {:ok,
       %{
         "content" => [
           %{
             "type" => "audio",
             "data" => unquote(data),
             "mimeType" => unquote(mime_type)
           }
         ]
       }}
    end
  end

  @doc """
  Creates a system role message for prompts.

  ## Example

      def handle_get_prompt(_conn, "assistant", _args) do
        {:ok, %{
          "messages" => [
            system("You are a helpful coding assistant")
          ]
        }}
      end
  """
  defmacro system(content) do
    quote do
      %{
        "role" => "system",
        "content" => %{"type" => "text", "text" => unquote(content)}
      }
    end
  end

  @doc """
  Creates a user role message for prompts.

  ## Example

      def handle_get_prompt(_conn, "question", args) do
        {:ok, %{
          "messages" => [
            user("What is \#{args["topic"]}?")
          ]
        }}
      end
  """
  defmacro user(content) do
    quote do
      %{
        "role" => "user",
        "content" => %{"type" => "text", "text" => unquote(content)}
      }
    end
  end

  @doc """
  Creates an assistant role message for prompts.

  ## Example

      def handle_get_prompt(_conn, "example", _args) do
        {:ok, %{
          "messages" => [
            user("Show me an example"),
            assistant("Here's an example: ...")
          ]
        }}
      end
  """
  defmacro assistant(content) do
    quote do
      %{
        "role" => "assistant",
        "content" => %{"type" => "text", "text" => unquote(content)}
      }
    end
  end

  @doc """
  Creates a resource content response with a specified MIME type.

  Useful for returning raw HTML, XML, or other content types from
  resource `read` handlers. For MCP Apps `ui://` resources, prefer
  `app_html/1` which uses the correct MIME type automatically.

  ## Example

      resource "config://settings.xml" do
        mime_type "application/xml"

        read fn _conn, _params, _opts ->
          xml = File.read!("priv/settings.xml")
          raw_resource(xml, "application/xml")
        end
      end
  """
  defmacro raw_resource(content, mime_type) do
    quote do
      {:ok,
       %{
         "contents" => [
           %{
             "mimeType" => unquote(mime_type),
             "text" => unquote(content)
           }
         ]
       }}
    end
  end

  @doc """
  Creates a resource content response for MCP Apps UI.

  Shortcut for `raw_resource(content, "text/html;profile=mcp-app")`.
  The `text/html;profile=mcp-app` MIME type is required by MCP Apps hosts
  to render the HTML as a sandboxed iframe.

  ## Example

      resource "ui://dashboard/app.html" do
        mime_type "text/html;profile=mcp-app"

        read fn _conn, _params, _opts ->
          html = File.read!("priv/mcp_apps/dashboard.html")
          app_html(html)
        end
      end
  """
  defmacro app_html(content) do
    quote do
      {:ok,
       %{
         "contents" => [
           %{
             "mimeType" => "text/html;profile=mcp-app",
             "text" => unquote(content)
           }
         ]
       }}
    end
  end

  @doc """
  Creates multiple text content items.

  Useful for returning multiple pieces of content in a single response.

  ## Example

      def handle_call_tool(_conn, "analyze", params) do
        results = MyAnalyzer.run(params)

        {:ok, %{
          "content" => texts([
            "Analysis Results:",
            "Score: \#{results.score}",
            "Details: \#{results.details}"
          ])
        }}
      end
  """
  def texts(string_list) when is_list(string_list) do
    Enum.map(string_list, fn text ->
      %{"type" => "text", "text" => text}
    end)
  end
end
