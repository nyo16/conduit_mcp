defmodule ConduitMcp.Client.SecretTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  require Logger

  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Test.SecretCarrier, as: Carrier

  doctest ConduitMcp.Client.Secret

  @value "sk-live-TOPSECRET-123"

  defmodule Holder do
    @moduledoc false
    use GenServer

    def init(secret), do: {:ok, %{token: secret}}
    def handle_call(:crash, _from, state), do: raise("boom with #{inspect(state)}")
  end

  test "inspect never shows the value, also nested and with custom opts" do
    secret = Secret.new(@value)

    for rendered <- [
          inspect(secret),
          inspect(%{auth: secret}, pretty: true, limit: :infinity),
          inspect(%Carrier{token: secret}, structs: true),
          Exception.message(%MatchError{term: secret})
        ] do
      refute rendered =~ @value
      assert rendered =~ "#Secret<redacted>"
    end
  end

  test "has no String.Chars: interpolation raises without leaking" do
    secret = Secret.new(@value)
    assert String.Chars.impl_for(secret) == nil

    # Interpolate a value the type checker cannot see through (it arrives as
    # a message), so the deliberate failure is not flagged at compile time.
    send(self(), {:secret, secret})
    assert_received {:secret, opaque}

    error = assert_raise Protocol.UndefinedError, fn -> "Bearer #{opaque}" end

    refute Exception.message(error) =~ @value
  end

  test "Logger metadata holding a Secret is not rendered" do
    log =
      capture_log([metadata: :all], fn ->
        Logger.metadata(token: Secret.new(@value))
        Logger.error("request failed")
        Logger.metadata(token: nil)
      end)

    assert log =~ "request failed"
    refute log =~ @value
  end

  test "JSON-encoding a struct or map containing a Secret raises without the value" do
    for term <- [
          %Carrier{name: "x", token: Secret.new(@value)},
          %{"headers" => [%{"authorization" => Secret.new(@value)}]}
        ] do
      error = assert_raise ArgumentError, fn -> JSON.encode!(term) end
      refute Exception.message(error) =~ @value
      assert Exception.message(error) =~ "expose/1"
    end
  end

  test "a GenServer crash report with the Secret in its state does not leak it" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = GenServer.start_link(Holder, Secret.new(@value))

    log =
      capture_log(fn ->
        catch_exit(GenServer.call(pid, :crash))
        assert_receive {:EXIT, ^pid, _reason}
      end)

    assert log =~ "boom"
    refute log =~ @value
  end

  test "new/1 is idempotent and expose/1 round-trips any term" do
    secret = Secret.new(%{"refresh" => @value})
    assert Secret.new(secret) == secret
    assert Secret.expose(secret) == %{"refresh" => @value}
    assert Secret.secret?(secret)
    refute Secret.secret?(@value)
  end
end
