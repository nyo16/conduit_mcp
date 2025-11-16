defmodule ConduitMcp.DSL.Helpers do
  @moduledoc """
  Helper macros for building MCP responses in the DSL.

  These helpers provide a convenient way to construct properly formatted
  MCP responses without manually building the response maps.

  ## Response Helpers

  - `text/1` - Returns a text content response
  - `json/1` - Returns JSON-encoded text content
  - `error/1` or `error/2` - Returns an error response
  - `image/1` - Returns an image content response

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
      {:ok, %{
        "content" => [%{
          "type" => "text",
          "text" => unquote(content)
        }]
      }}
    end
  end

  @doc """
  Creates a JSON-encoded text content response.

  The data will be encoded to JSON using Jason.

  ## Example

      def handle_call_tool(_conn, "get_user", %{"id" => id}) do
        user = MyApp.Users.get!(id)
        json(%{id: user.id, name: user.name, email: user.email})
      end
  """
  defmacro json(data) do
    quote do
      {:ok, %{
        "content" => [%{
          "type" => "text",
          "text" => Jason.encode!(unquote(data))
        }]
      }}
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
  defmacro error(message, code \\ -32000) do
    quote do
      {:error, %{
        "code" => unquote(code),
        "message" => unquote(message)
      }}
    end
  end

  @doc """
  Creates an image content response.

  ## Example

      def handle_call_tool(_conn, "generate_chart", params) do
        image_url = MyCharts.generate(params)
        image(image_url)
      end
  """
  defmacro image(url) do
    quote do
      {:ok, %{
        "content" => [%{
          "type" => "image",
          "data" => unquote(url)
        }]
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
