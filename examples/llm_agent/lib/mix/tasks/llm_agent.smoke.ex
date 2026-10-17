defmodule Mix.Tasks.LlmAgent.Smoke do
  @shortdoc "Checks the hub, policy and hooks without calling a model"
  @moduledoc "Runs `LlmAgent.Smoke.run/0`: `mix llm_agent.smoke`."

  use Mix.Task

  @impl Mix.Task
  def run(_argv) do
    Mix.Task.run("app.start")
    LlmAgent.Smoke.run()
  end
end
