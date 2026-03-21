defmodule ConduitMcp.SessionTest do
  use ExUnit.Case, async: false

  alias ConduitMcp.Session
  alias ConduitMcp.Session.EtsStore

  setup do
    # Clean ETS table between tests
    if :ets.whereis(:conduit_mcp_sessions) != :undefined do
      :ets.delete_all_objects(:conduit_mcp_sessions)
    end

    :ok
  end

  describe "generate_id/0" do
    test "generates unique session IDs" do
      id1 = Session.generate_id()
      id2 = Session.generate_id()

      assert is_binary(id1)
      assert is_binary(id2)
      assert id1 != id2
      assert String.length(id1) > 10
    end
  end

  describe "EtsStore" do
    test "create and get a session" do
      assert :ok = EtsStore.create("session-1", %{"protocol_version" => "2025-11-25"})
      assert {:ok, metadata} = EtsStore.get("session-1")
      assert metadata["protocol_version"] == "2025-11-25"
      assert is_integer(metadata["created_at"])
    end

    test "get returns error for non-existent session" do
      assert {:error, :not_found} = EtsStore.get("non-existent")
    end

    test "delete removes a session" do
      EtsStore.create("session-2", %{"protocol_version" => "2025-11-25"})
      assert {:ok, _} = EtsStore.get("session-2")

      assert :ok = EtsStore.delete("session-2")
      assert {:error, :not_found} = EtsStore.get("session-2")
    end

    test "update merges metadata" do
      EtsStore.create("session-3", %{"protocol_version" => "2025-11-25"})

      assert :ok = EtsStore.update("session-3", %{"client_info" => "test"})
      assert {:ok, metadata} = EtsStore.get("session-3")
      assert metadata["protocol_version"] == "2025-11-25"
      assert metadata["client_info"] == "test"
    end

    test "update returns error for non-existent session" do
      assert {:error, :not_found} = EtsStore.update("non-existent", %{"foo" => "bar"})
    end

    test "cleanup removes expired sessions" do
      EtsStore.create("old-session", %{"protocol_version" => "2025-11-25"})

      # Manually set created_at to the past
      [{_, metadata}] = :ets.lookup(:conduit_mcp_sessions, "old-session")
      old_metadata = Map.put(metadata, "created_at", System.system_time(:millisecond) - 100_000)
      :ets.insert(:conduit_mcp_sessions, {"old-session", old_metadata})

      EtsStore.create("new-session", %{"protocol_version" => "2025-11-25"})

      # Cleanup with 50 second TTL — should remove old-session
      removed = EtsStore.cleanup(50_000)
      assert removed == 1
      assert {:error, :not_found} = EtsStore.get("old-session")
      assert {:ok, _} = EtsStore.get("new-session")
    end
  end

  describe "Session facade" do
    test "create and get via facade" do
      session_id = Session.generate_id()
      assert :ok = Session.create(session_id, %{"version" => "test"})
      assert {:ok, metadata} = Session.get(session_id)
      assert metadata["version"] == "test"
    end

    test "delete via facade" do
      session_id = Session.generate_id()
      Session.create(session_id, %{"version" => "test"})
      assert :ok = Session.delete(session_id)
      assert {:error, :not_found} = Session.get(session_id)
    end

    test "update via facade" do
      session_id = Session.generate_id()
      Session.create(session_id, %{"version" => "test"})
      assert :ok = Session.update(session_id, %{"extra" => "data"})
      assert {:ok, metadata} = Session.get(session_id)
      assert metadata["extra"] == "data"
    end
  end
end
