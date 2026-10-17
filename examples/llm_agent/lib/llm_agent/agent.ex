defmodule LlmAgent.Agent do
  @moduledoc """
  An agent loop over the Anthropic Messages API and `LlmAgent.Hub`.

  Each turn lists the hub's tools in Anthropic's format
  (`ConduitMcp.Client.Adapters.tools/3`), sends the conversation, and when
  the model stops with `tool_use`, runs its calls through the hub
  (`ConduitMcp.Client.Adapters.execute_tool_calls/4`: policy, hooks,
  routing to the owning server) and answers with the `tool_result` blocks.
  """

  alias ConduitMcp.Client.{Adapters, Hub}
  alias ConduitMcp.Client.Adapters.Anthropic

  @hub LlmAgent.Hub
  @max_turns 10
  @anthropic_version "2023-06-01"

  @doc """
  Waits until every hub server is `:ready` (or `timeout` ms pass) and
  returns the hub's status.
  """
  @spec await_servers(timeout()) :: {:ok, [Hub.server_status()]} | {:error, [Hub.server_status()]}
  def await_servers(timeout \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_servers_until(deadline)
  end

  defp await_servers_until(deadline) do
    {:ok, status} = Hub.status(@hub)

    cond do
      status != [] and Enum.all?(status, &(&1.state == :ready)) ->
        {:ok, status}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, status}

      true ->
        Process.sleep(100)
        await_servers_until(deadline)
    end
  end

  @doc """
  Runs `prompt` to completion and returns the model's final text.
  Needs `ANTHROPIC_API_KEY` and `ANTHROPIC_MODEL`.
  """
  @spec ask(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def ask(prompt, opts \\ []) do
    config = %{
      key: fetch_config!(:anthropic_api_key, "ANTHROPIC_API_KEY"),
      model: fetch_config!(:anthropic_model, "ANTHROPIC_MODEL"),
      url: Application.fetch_env!(:llm_agent, :anthropic_url),
      principal: Keyword.get(opts, :principal, "example-user")
    }

    loop([%{"role" => "user", "content" => prompt}], MapSet.new(), config, @max_turns)
  end

  defp loop(_messages, _taint, _config, 0), do: {:error, :max_turns}

  defp loop(messages, taint, config, turns_left) do
    # Listed every turn: a server that went down (or came back) since the
    # last turn drops out of (or rejoins) the offered tools.
    {:ok, listing} = Adapters.tools(@hub, :anthropic, principal: config.principal)

    body = %{
      "model" => config.model,
      "max_tokens" => 1024,
      "messages" => messages,
      "tools" => listing.tools
    }

    with {:ok, response} <- post(body, config) do
      messages = messages ++ [%{"role" => "assistant", "content" => response["content"]}]

      case response["stop_reason"] do
        "tool_use" ->
          case run_tools(response, listing, taint, config) do
            {:ok, results, taint} ->
              loop(
                messages ++ [%{"role" => "user", "content" => results}],
                taint,
                config,
                turns_left - 1
              )

            {:halt, _results} ->
              {:error, :halted_by_approver}

            {:error, error} ->
              {:error, error}
          end

        _end_turn ->
          {:ok, text_of(response)}
      end
    end
  end

  @doc """
  Runs the `tool_use` blocks of an Anthropic `response` through the hub.
  Returns the `tool_result` blocks for the next user turn and the taint
  (servers whose output is now in the model's context) for the turn after.
  """
  @spec run_tools(map(), Adapters.listing(), MapSet.t(String.t()), map()) ::
          {:ok, [map()], MapSet.t(String.t())}
          | {:halt, [map()]}
          | {:error, ConduitMcp.Client.Error.t()}
  def run_tools(response, listing, taint, config) do
    opts = [
      toolset: listing.toolset,
      principal: config.principal,
      taint: MapSet.to_list(taint)
    ]

    case Adapters.execute_tool_calls(@hub, :anthropic, response, opts) do
      {:ok, results} -> {:ok, results, MapSet.union(taint, servers_called(response, listing))}
      other -> other
    end
  end

  defp servers_called(response, listing) do
    {calls, _rejected} = Anthropic.tool_calls(response, listing.toolset)
    MapSet.new(calls, & &1.server_id)
  end

  defp post(body, config) do
    case Req.post(config.url,
           json: body,
           headers: [{"x-api-key", config.key}, {"anthropic-version", @anthropic_version}],
           receive_timeout: 120_000,
           retry: :transient
         ) do
      {:ok, %Req.Response{status: 200, body: response}} -> {:ok, response}
      {:ok, %Req.Response{status: status, body: error}} -> {:error, {:http, status, error}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp text_of(%{"content" => blocks}) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp fetch_config!(key, env) do
    case Application.get_env(:llm_agent, key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise ArgumentError, "set #{env} (see examples/llm_agent/README.md)"
    end
  end
end
