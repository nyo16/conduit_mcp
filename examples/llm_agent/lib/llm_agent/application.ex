defmodule LlmAgent.Application do
  @moduledoc """
  Starts the example's MCP hub (`LlmAgent.Hub`) and, unless `MCP_HTTP_URL`
  points elsewhere, the `examples/simple_tools_server` server on
  `MCP_HTTP_PORT` (default 4101) for the hub's HTTP server.

  ## The hub

    * `notes` - `priv/notes_server.exs` over stdio (`list_notes`,
      `read_note`, `delete_note`);
    * `tools` - `Examples.SimpleToolsServer` over Streamable HTTP (`echo`,
      `reverse_string`).

  The policy allows reading notes and every `tools` tool and denies any
  `delete_*`; with no `:on_ask` approver, a tool no rule allows is denied
  too. A pre-hook logs every call (`LlmAgent.Hooks.audit/2`) and a post-hook
  redacts API keys from every result (`LlmAgent.Hooks.redact/3`) before the
  model sees it.
  """

  use Application

  alias ConduitMcp.Client.Transport.{Stdio, StreamableHTTP}

  @impl true
  def start(_type, _args) do
    {http_children, http_url} = http_server()

    hub =
      {
        ConduitMcp.Client.Hub,
        # Required: a hub refuses to start without a policy.
        name: LlmAgent.Hub,
        policy: [
          allow: ["notes/list_notes", "notes/read_note", "tools/*"],
          deny: ["*/delete_*"]
        ],
        hooks: [
          pre_tool_call: [{:all, {LlmAgent.Hooks, :audit}, id: :audit}],
          post_tool_call: [{:all, {LlmAgent.Hooks, :redact}, id: :redact}]
        ],
        servers: [
          notes: [transport: {Stdio, notes_server()}],
          tools: [transport: {StreamableHTTP, url: http_url}]
        ]
      }

    Supervisor.start_link(http_children ++ [hub],
      strategy: :one_for_one,
      name: LlmAgent.Supervisor
    )
  end

  defp http_server do
    case Application.get_env(:llm_agent, :http_server_url) do
      nil ->
        port = Application.fetch_env!(:llm_agent, :http_port)

        bandit =
          {Bandit,
           plug: {ConduitMcp.Transport.StreamableHTTP, server_module: Examples.SimpleToolsServer},
           port: port,
           ip: :loopback}

        {[bandit], "http://127.0.0.1:#{port}/"}

      url ->
        {[], url}
    end
  end

  # `elixir -pa <ebin...> priv/notes_server.exs`, run with the Elixir and
  # OTP of this VM so the server loads the beams this project compiled.
  # The stdio transport passes the server only an allowlisted environment,
  # so PATH is given explicitly with this VM's `erl` first.
  defp notes_server do
    elixir = Path.expand("../../bin/elixir", to_string(:code.lib_dir(:elixir)))
    ebins = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
    erts_bin = Path.join(to_string(:code.root_dir()), "bin")

    [
      command: if(File.regular?(elixir), do: elixir, else: "elixir"),
      args:
        Enum.flat_map(ebins, &["-pa", &1]) ++
          [Application.app_dir(:llm_agent, "priv/notes_server.exs")],
      env: %{"PATH" => erts_bin <> ":" <> System.get_env("PATH", "")}
    ]
  end
end
