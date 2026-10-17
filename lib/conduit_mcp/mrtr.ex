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

  ## Returning input requests

  `handle_call_tool/3`, `handle_read_resource/2` and `handle_get_prompt/3`
  (and the DSL and `ConduitMcp.Component` handlers behind them) return
  `{:input_required, input_requests, state}` to ask for input. The library
  checks every request against the client's declared capabilities
  (`missing_capabilities/2`; a gap is answered with `-32021` and
  `data.requiredCapabilities`), seals `state` into `requestState` with
  `ConduitMcp.MRTR.State`, and answers with an `InputRequiredResult`. On
  the retry the callback finds the restored state and the client's
  `inputResponses` in `conn.assigns[:mcp_input]`; see `ConduitMcp.Server`.

  The state carried between rounds is sealed by `ConduitMcp.MRTR.State`,
  which requires `config :conduit_mcp, :mrtr_keys`. MRTR exists only in the
  modern era: a legacy-era request whose callback returns
  `{:input_required, ...}` gets `-32603`.
  """

  @doc """
  Returns the client capabilities `input_requests` need that
  `client_capabilities` does not declare, as a `ClientCapabilities`-shaped
  map (`%{}` when every request can be sent).

    * `elicitation/create` needs `elicitation.url` for `"mode" => "url"`,
      otherwise form mode: `elicitation.form`, or an `elicitation` that
      declares neither mode (the spec's backwards-compatible form-only
      declaration).
    * `sampling/createMessage` needs `sampling`; `sampling.tools` when it
      carries `tools` or `toolChoice`; `sampling.context` when its
      `includeContext` is anything but `"none"`.
    * `roots/list` needs `roots`.

  Other methods impose no requirement.

  ## Example

      iex> ConduitMcp.MRTR.missing_capabilities(
      ...>   %{"approval" => ConduitMcp.MRTR.elicit("Approve?", %{"type" => "object"})},
      ...>   %{"roots" => %{}}
      ...> )
      %{"elicitation" => %{"form" => %{}}}
  """
  @spec missing_capabilities(%{optional(String.t()) => map()}, map()) :: map()
  def missing_capabilities(input_requests, client_capabilities)
      when is_map(input_requests) and is_map(client_capabilities) do
    input_requests
    |> Map.values()
    |> Enum.flat_map(&requirements/1)
    |> Enum.reject(&declared?(client_capabilities, &1))
    |> Enum.reduce(%{}, &put_path/2)
  end

  defp requirements(%{"method" => "elicitation/create"} = request) do
    case get_in(request, ["params", "mode"]) do
      "url" -> [["elicitation", "url"]]
      _form -> [["elicitation", "form"]]
    end
  end

  defp requirements(%{"method" => "sampling/createMessage"} = request) do
    params = Map.get(request, "params") || %{}
    tools? = Map.has_key?(params, "tools") or Map.has_key?(params, "toolChoice")
    context? = Map.get(params, "includeContext") not in [nil, "none"]

    Enum.reject(
      [["sampling"], tools? && ["sampling", "tools"], context? && ["sampling", "context"]],
      &(&1 == false)
    )
  end

  defp requirements(%{"method" => "roots/list"}), do: [["roots"]]
  defp requirements(_request), do: []

  # An `elicitation` declaring neither mode supports form only.
  defp declared?(%{"elicitation" => elicitation}, ["elicitation", "form"])
       when is_map(elicitation),
       do: Map.has_key?(elicitation, "form") or not Map.has_key?(elicitation, "url")

  defp declared?(capabilities, path) do
    Enum.reduce_while(path, capabilities, fn key, level ->
      case level do
        %{^key => next} when is_map(next) -> {:cont, next}
        _ -> {:halt, nil}
      end
    end) != nil
  end

  defp put_path([key], acc), do: Map.put_new(acc, key, %{})

  defp put_path([key | rest], acc),
    do: Map.put(acc, key, put_path(rest, Map.get(acc, key, %{})))

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
