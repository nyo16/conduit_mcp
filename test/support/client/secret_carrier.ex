defmodule ConduitMcp.Test.SecretCarrier do
  @moduledoc """
  A JSON-encodable struct for `ConduitMcp.Client.SecretTest`.

  It lives in `test/support` (compiled) rather than in the test file because
  protocols are consolidated in the test build, so a `@derive JSON.Encoder`
  inside a test module would never be dispatched to.
  """
  @derive JSON.Encoder
  defstruct [:name, :token]
end
