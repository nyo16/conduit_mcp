defmodule ConduitMcp.Session do
  @moduledoc """
  Session management facade for MCP protocol sessions.

  MCP sessions track the negotiated protocol version and client state
  across requests. The session store is pluggable via the `ConduitMcp.Session.Store`
  behaviour.

  ## Configuration

  Session configuration is passed through the transport options:

      {ConduitMcp.Transport.StreamableHTTP,
        server_module: MyServer,
        session: [store: ConduitMcp.Session.EtsStore]}  # the default store

  Set `session: false` to disable session management entirely. How long an
  idle session lives is set on the session janitor, not here:
  `config :conduit_mcp, :session_janitor, ttl: :timer.minutes(60)` (default
  30 minutes).
  """

  @default_store ConduitMcp.Session.EtsStore

  @doc """
  Generates a unique session ID.
  """
  def generate_id do
    Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  @doc """
  Creates a new session.
  """
  def create(session_id, metadata, store \\ @default_store) do
    store.create(session_id, metadata)
  end

  @doc """
  Retrieves a session by ID.
  """
  def get(session_id, store \\ @default_store) do
    store.get(session_id)
  end

  @doc """
  Deletes a session.
  """
  def delete(session_id, store \\ @default_store) do
    store.delete(session_id)
  end

  @doc """
  Updates session metadata.
  """
  def update(session_id, metadata, store \\ @default_store) do
    store.update(session_id, metadata)
  end
end
