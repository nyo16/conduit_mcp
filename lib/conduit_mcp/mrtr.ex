defmodule ConduitMcp.MRTR do
  @moduledoc """
  Builders for Multi Round-Trip Request (MRTR) input requests.

  In MCP `2026-07-28` a server no longer sends requests to the client.
  Instead a tool call, resource read, or prompt get answers with an
  `input_required` result carrying an `inputRequests` map — keys are
  server-chosen identifiers, values are the maps these functions build — and
  the client retries the original request with the matching
  `inputResponses`. See
  [MRTR](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr).

  Each builder returns one `InputRequest` (`"method"` plus `"params"`, no
  `"jsonrpc"` or `"id"`):

      %{
        "approval" => ConduitMcp.MRTR.elicit("Approve deploy?", schema)
      }

  Sampling and roots are deprecated in `2026-07-28`; `sample/2` and
  `list_roots/0` remain available but carry `@deprecated` markers.
  Elicitation is not deprecated.

  The state carried between rounds is sealed by `ConduitMcp.MRTR.State`,
  which requires `config :conduit_mcp, :mrtr_keys`.
  """

  @doc """
  Builds an `elicitation/create` input request (form mode).

  `requested_schema` is the restricted JSON Schema the client renders as a
  form: a flat `"type" => "object"` with primitive `"properties"`.

  ## Example

      ConduitMcp.MRTR.elicit("Please provide your API key", %{
        "type" => "object",
        "properties" => %{"api_key" => %{"type" => "string"}},
        "required" => ["api_key"]
      })
  """
  @spec elicit(String.t(), map()) :: map()
  def elicit(message, requested_schema) when is_binary(message) and is_map(requested_schema) do
    %{
      "method" => "elicitation/create",
      "params" => %{"message" => message, "requestedSchema" => requested_schema}
    }
  end

  @doc """
  Builds a `sampling/createMessage` input request.

  `messages` is a list of `SamplingMessage` maps.

  ## Options

    * `:max_tokens` - **required**; the maximum tokens to sample
    * `:system_prompt` - system prompt for the LLM
    * `:model_preferences` - model selection preferences
    * `:temperature` - sampling temperature
    * `:stop_sequences` - list of stop sequences
    * `:tools` - tools the LLM may call
    * `:tool_choice` - tool selection map, e.g. `%{"mode" => "auto"}`

  Raises `KeyError` when `:max_tokens` is missing, since the spec requires it.
  """
  @deprecated "Sampling is deprecated in MCP 2026-07-28"
  @spec sample([map()], keyword()) :: map()
  def sample(messages, opts) when is_list(messages) do
    params =
      %{"messages" => messages, "maxTokens" => Keyword.fetch!(opts, :max_tokens)}
      |> maybe_put("systemPrompt", Keyword.get(opts, :system_prompt))
      |> maybe_put("modelPreferences", Keyword.get(opts, :model_preferences))
      |> maybe_put("temperature", Keyword.get(opts, :temperature))
      |> maybe_put("stopSequences", Keyword.get(opts, :stop_sequences))
      |> maybe_put("tools", Keyword.get(opts, :tools))
      |> maybe_put("toolChoice", Keyword.get(opts, :tool_choice))

    %{"method" => "sampling/createMessage", "params" => params}
  end

  @doc "Builds a `roots/list` input request."
  @deprecated "Roots are deprecated in MCP 2026-07-28"
  @spec list_roots() :: map()
  def list_roots, do: %{"method" => "roots/list"}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
