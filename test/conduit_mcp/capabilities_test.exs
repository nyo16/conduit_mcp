defmodule ConduitMcp.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Capabilities

  defmodule Bare do
    def handle_list_tools(_conn), do: {:ok, %{"tools" => []}}
  end

  defmodule WithBase do
    def __capabilities__, do: %{"tools" => %{"listChanged" => false}}
  end

  defmodule WithEverything do
    def handle_subscribe_resource(_conn, _uri), do: {:ok, %{}}
    def handle_complete(_conn, _ref, _argument), do: {:ok, %{}}
    def handle_set_log_level(_conn, _level), do: {:ok, %{}}
  end

  defmodule SubscribeWithoutResources do
    def __capabilities__, do: %{"tools" => %{"listChanged" => false}}
    def handle_subscribe_resource(_conn, _uri), do: {:ok, %{}}
  end

  defmodule SubscribeWithResources do
    def __capabilities__, do: %{"resources" => %{"listChanged" => false}}
    def handle_subscribe_resource(_conn, _uri), do: {:ok, %{}}
  end

  defmodule EchoTool do
    use ConduitMcp.Component, type: :tool, description: "Echo"

    @impl true
    def execute(_params, _conn), do: text("ok")
  end

  defmodule ToolsOnlyEndpoint do
    use ConduitMcp.Endpoint, name: "Caps", version: "1.0.0"

    component(EchoTool)
  end

  @base %{
    "tools" => %{"listChanged" => false},
    "resources" => %{"listChanged" => false},
    "prompts" => %{"listChanged" => false}
  }

  test "uses the tools/resources/prompts base set without __capabilities__/0" do
    assert Capabilities.build(Bare) == @base
  end

  test "uses __capabilities__/0 as the base when defined" do
    assert Capabilities.build(WithBase) == %{"tools" => %{"listChanged" => false}}
  end

  test "overlays subscribe, completions and logging from exported callbacks" do
    assert Capabilities.build(WithEverything) == %{
             "tools" => %{"listChanged" => false},
             "resources" => %{"listChanged" => false, "subscribe" => true},
             "prompts" => %{"listChanged" => false},
             "completions" => %{},
             "logging" => %{}
           }
  end

  test "adds subscribe only when the base advertises resources" do
    assert Capabilities.build(SubscribeWithoutResources) == %{
             "tools" => %{"listChanged" => false}
           }

    assert Capabilities.build(SubscribeWithResources) == %{
             "resources" => %{"listChanged" => false, "subscribe" => true}
           }
  end

  test "uses an Endpoint's generated base, advertising only what it registers" do
    assert Capabilities.build(ToolsOnlyEndpoint) == %{"tools" => %{"listChanged" => false}}
  end
end
