import Config

# Nothing here is hard-coded: the model, the key and the HTTP server's URL
# come from the environment (see README.md).
config :llm_agent,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  anthropic_model: System.get_env("ANTHROPIC_MODEL"),
  anthropic_url: System.get_env("ANTHROPIC_URL", "https://api.anthropic.com/v1/messages"),
  # Unset: serve examples/simple_tools_server locally on :http_port.
  http_server_url: System.get_env("MCP_HTTP_URL"),
  http_port: String.to_integer(System.get_env("MCP_HTTP_PORT", "4101"))
