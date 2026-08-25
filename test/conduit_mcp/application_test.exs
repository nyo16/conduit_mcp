defmodule ConduitMcp.ApplicationTest do
  # async: false — reads and writes the global application env.
  use ExUnit.Case, async: false

  alias ConduitMcp.Application, as: App
  alias ConduitMcp.Session

  @key :janitor_test_config
  @defaults [store: Session.EtsStore, ttl: 1_000, name: :janitor_default_name]
  @id :janitor_test_id

  setup do
    on_exit(fn -> Application.delete_env(:conduit_mcp, @key) end)
    :ok
  end

  describe "janitor config shapes" do
    test "unset means run with the defaults" do
      Application.delete_env(:conduit_mcp, @key)

      assert [%{id: @id, start: {Session.Janitor, :start_link, [opts]}}] =
               App.janitor(@key, @defaults, @id)

      assert opts == @defaults
    end

    test "false disables it" do
      Application.put_env(:conduit_mcp, @key, false)
      assert App.janitor(@key, @defaults, @id) == []
    end

    test "true is the symmetric spelling of yes, not a boot crash" do
      # `false` disables, so `true` is the obvious way to spell "yes". Without
      # a clause for it this raised CaseClauseError inside Application.start/2,
      # which the consumer sees as an opaque {:conduit_mcp, {:bad_return, ...}}
      # with nothing pointing at their config line.
      Application.put_env(:conduit_mcp, @key, true)

      assert [%{id: @id, start: {Session.Janitor, :start_link, [opts]}}] =
               App.janitor(@key, @defaults, @id)

      assert opts == @defaults
    end

    test "a keyword list is merged over the defaults" do
      Application.put_env(:conduit_mcp, @key, ttl: 9_999)

      assert [%{start: {Session.Janitor, :start_link, [opts]}}] =
               App.janitor(@key, @defaults, @id)

      assert Keyword.fetch!(opts, :ttl) == 9_999
      assert Keyword.fetch!(opts, :store) == Session.EtsStore
    end

    test "any other value raises a message naming the key and the accepted shapes" do
      Application.put_env(:conduit_mcp, @key, :yes_please)

      error =
        assert_raise ArgumentError, fn -> App.janitor(@key, @defaults, @id) end

      assert error.message =~ ":janitor_test_config"
      assert error.message =~ "true, false or a keyword"
      assert error.message =~ ":yes_please"
    end
  end

  describe "supervised children" do
    test "the cancellation janitor reports its own telemetry event, not the session's" do
      # Cancellation.cleanup/1 already emits [:conduit_mcp, :cancellation,
      # :cleanup]. If this janitor also used the session default, a consumer's
      # session-cleanup handler would receive cancellation evictions once a
      # minute and the same count would publish under two names.
      pid = Process.whereis(ConduitMcp.Cancellation.Janitor)
      assert is_pid(pid), "the cancellation janitor is not running"

      state = :sys.get_state(pid)

      assert state.store == ConduitMcp.Cancellation
      assert state.event == [:conduit_mcp, :cancellation, :janitor]
      refute state.event == [:conduit_mcp, :session, :cleanup]
    end

    test "the session janitor keeps the documented session event" do
      pid = Process.whereis(ConduitMcp.Session.Janitor.Default)
      assert is_pid(pid), "the session janitor is not running"

      state = :sys.get_state(pid)

      assert state.store == Session.EtsStore
      assert state.event == [:conduit_mcp, :session, :cleanup]
    end
  end
end
