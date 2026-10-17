defmodule Mix.Tasks.LlmAgent.Ask do
  @shortdoc "Runs one prompt through the agent loop"
  @moduledoc """
  `mix llm_agent.ask "Summarise my deploy note"`

  Needs `ANTHROPIC_API_KEY` and `ANTHROPIC_MODEL` (see README.md).
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    prompt =
      case argv do
        [] -> Mix.raise(~s(usage: mix llm_agent.ask "your prompt"))
        words -> Enum.join(words, " ")
      end

    Mix.Task.run("app.start")

    with {:error, status} <- LlmAgent.Agent.await_servers() do
      Mix.raise("servers not ready: #{inspect(status)}")
    end

    case LlmAgent.Agent.ask(prompt) do
      {:ok, answer} -> Mix.shell().info(answer)
      {:error, reason} -> Mix.raise("agent failed: #{inspect(reason)}")
    end
  end
end
