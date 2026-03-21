defmodule ConduitMcp.Client do
  @moduledoc """
  Server-to-client request helpers for bidirectional MCP communication.

  These functions allow MCP servers to send requests back to clients for:
  - **Sampling** — request LLM inference from the client
  - **Elicitation** — request user input via forms or URLs
  - **Roots** — query client filesystem boundaries

  ## Important

  Server-to-client requests require a bidirectional transport (SSE streaming or
  equivalent). The client must declare the corresponding capability during initialization.

  These are building blocks for advanced MCP features. They construct the
  JSON-RPC request messages that need to be sent to the client via the active
  transport connection.
  """

  alias ConduitMcp.Protocol

  @doc """
  Builds a `sampling/createMessage` request to send to the client.

  The client will use its LLM to generate a response based on the provided messages.

  ## Options

  - `:model_preferences` - Model selection preferences
  - `:system_prompt` - System prompt for the LLM
  - `:max_tokens` - Maximum tokens in the response
  - `:tools` - Tools available for the LLM to use
  - `:tool_choice` - Tool selection mode ("auto", "required", "none")

  ## Example

      request = ConduitMcp.Client.create_message_request(
        [%{"role" => "user", "content" => %{"type" => "text", "text" => "Hello"}}],
        max_tokens: 1000
      )
  """
  def create_message_request(messages, opts \\ []) do
    params =
      %{"messages" => messages}
      |> maybe_put("modelPreferences", Keyword.get(opts, :model_preferences))
      |> maybe_put("systemPrompt", Keyword.get(opts, :system_prompt))
      |> maybe_put("maxTokens", Keyword.get(opts, :max_tokens))
      |> maybe_put("tools", Keyword.get(opts, :tools))
      |> maybe_put("toolChoice", Keyword.get(opts, :tool_choice))

    %{
      "jsonrpc" => "2.0",
      "id" => generate_request_id(),
      "method" => "sampling/createMessage",
      "params" => params
    }
  end

  @doc """
  Builds an `elicitation/create` request (form mode) to send to the client.

  The client will display a form to the user based on the provided JSON schema.

  ## Example

      request = ConduitMcp.Client.elicit_request(
        "Please provide your API key",
        %{
          "type" => "object",
          "properties" => %{"api_key" => %{"type" => "string", "title" => "API Key"}},
          "required" => ["api_key"]
        }
      )
  """
  def elicit_request(message, schema) do
    %{
      "jsonrpc" => "2.0",
      "id" => generate_request_id(),
      "method" => "elicitation/create",
      "params" => %{
        "message" => message,
        "requestedSchema" => schema
      }
    }
  end

  @doc """
  Builds a `roots/list` request to send to the client.

  The client will respond with its filesystem root boundaries.
  """
  def list_roots_request do
    %{
      "jsonrpc" => "2.0",
      "id" => generate_request_id(),
      "method" => "roots/list"
    }
  end

  @doc """
  Builds a progress notification to send to the client.
  """
  def progress_notification(progress_token, progress, opts \\ []) do
    params =
      %{"progressToken" => progress_token, "progress" => progress}
      |> maybe_put("total", Keyword.get(opts, :total))
      |> maybe_put("message", Keyword.get(opts, :message))

    Protocol.notification("notifications/progress", params)
  end

  @doc """
  Builds a log message notification to send to the client.
  """
  def log_notification(level, data, opts \\ []) do
    params =
      %{"level" => level, "data" => data}
      |> maybe_put("logger", Keyword.get(opts, :logger))

    Protocol.notification("notifications/message", params)
  end

  @doc """
  Builds a resource updated notification to send to the client.
  """
  def resource_updated_notification(uri) do
    Protocol.notification("notifications/resources/updated", %{"uri" => uri})
  end

  @doc """
  Builds a resource list changed notification.
  """
  def resource_list_changed_notification do
    Protocol.notification("notifications/resources/list_changed")
  end

  @doc """
  Builds a tool list changed notification.
  """
  def tool_list_changed_notification do
    Protocol.notification("notifications/tools/list_changed")
  end

  @doc """
  Builds a prompt list changed notification.
  """
  def prompt_list_changed_notification do
    Protocol.notification("notifications/prompts/list_changed")
  end

  defp generate_request_id do
    :erlang.unique_integer([:positive, :monotonic])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
