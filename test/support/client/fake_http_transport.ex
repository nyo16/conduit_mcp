defmodule ConduitMcp.Test.Client.FakeHTTPTransport do
  @moduledoc """
  `ConduitMcp.Test.Client.FakeTransport` with `kind/0` = `:http`, for
  behaviour the client applies to HTTP transports only (for example
  dropping tools with invalid `x-mcp-header` annotations). Events are
  injected with `ConduitMcp.Test.Client.FakeTransport.push/2`.
  """

  @behaviour ConduitMcp.Client.Transport

  alias ConduitMcp.Test.Client.FakeTransport

  @impl true
  def kind, do: :http

  @impl true
  defdelegate init(opts, context), to: FakeTransport

  @impl true
  defdelegate connect(state), to: FakeTransport

  @impl true
  defdelegate request(state, message, reply_to, wire_opts), to: FakeTransport

  @impl true
  defdelegate notify(state, message), to: FakeTransport

  @impl true
  defdelegate respond(state, message), to: FakeTransport

  @impl true
  defdelegate cancel(state, id, handle, reason), to: FakeTransport

  @impl true
  defdelegate set_session(state, session), to: FakeTransport

  @impl true
  defdelegate handle_info(message, state), to: FakeTransport

  @impl true
  defdelegate close(state, reason), to: FakeTransport
end
