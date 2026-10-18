defmodule ConduitMcp.DSLResourceResultTest do
  # A DSL `read` handler answering with the tool-shaped helpers (`text/1`,
  # `json/1`, `image/2`, `audio/2`) must still put a `ReadResourceResult`
  # (`"contents"`, each with `"uri"`) on the wire. Strict clients reject a
  # `"content"` result (seen with @modelcontextprotocol/client 2.3.1:
  # "Invalid result for resources/read ... contents expected array").
  use ExUnit.Case, async: true

  import Plug.Test, only: [conn: 3]

  alias ConduitMcp.Handler
  alias ConduitMcp.Test.McpSchema

  defmodule Server do
    use ConduitMcp.Server

    resource "note://text" do
      mime_type("text/markdown")
      read(fn _conn, _params, _opts -> text("# Note") end)
    end

    resource "note://untyped" do
      read(fn _conn, _params, _opts -> text("plain") end)
    end

    resource "user://{id}" do
      mime_type("application/json")
      read(fn _conn, %{"id" => id}, _opts -> json(%{id: id}) end)
    end

    resource "media://image" do
      read(fn _conn, _params, _opts -> image("aGk=", "image/png") end)
    end

    resource "media://audio" do
      read(fn _conn, _params, _opts -> audio("aGk=", "audio/wav") end)
    end

    resource "raw://contents" do
      read(fn _conn, _params, _opts -> raw_resource("<x/>", "application/xml") end)
    end

    resource "static://mfa" do
      mime_type("text/plain")
      read(__MODULE__, :read_mfa)
    end

    def read_mfa(_conn, _params, _opts), do: text("from mfa")
  end

  @modern "2026-07-28"
  @legacy "2025-11-25"

  defp read(uri, :modern) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    reply(%{"uri" => uri, "_meta" => meta})
  end

  defp read(uri, :legacy), do: reply(%{"uri" => uri})

  defp reply(params) do
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "resources/read", "params" => params}

    assert {:reply, %{"result" => result}} =
             Handler.dispatch(request, Server, conn(:post, "/", ""))

    result
  end

  for era <- [:modern, :legacy] do
    @era era
    @version if era == :modern, do: @modern, else: @legacy

    test "#{era}: text/1 becomes TextResourceContents with the declared mimeType" do
      result = read("note://text", @era)

      assert :ok == McpSchema.validate(@version, "ReadResourceResult", result)
      refute Map.has_key?(result, "content")

      assert result["contents"] == [
               %{"uri" => "note://text", "mimeType" => "text/markdown", "text" => "# Note"}
             ]
    end

    test "#{era}: a resource without mime_type gets no mimeType" do
      result = read("note://untyped", @era)

      assert :ok == McpSchema.validate(@version, "ReadResourceResult", result)
      assert result["contents"] == [%{"uri" => "note://untyped", "text" => "plain"}]
    end

    test "#{era}: json/1 on a template carries the requested URI" do
      result = read("user://42", @era)

      assert :ok == McpSchema.validate(@version, "ReadResourceResult", result)

      assert [%{"uri" => "user://42", "mimeType" => "application/json", "text" => text}] =
               result["contents"]

      assert JSON.decode!(text) == %{"id" => "42"}
    end

    test "#{era}: image/2 and audio/2 become BlobResourceContents" do
      for {uri, mime} <- [{"media://image", "image/png"}, {"media://audio", "audio/wav"}] do
        result = read(uri, @era)

        assert :ok == McpSchema.validate(@version, "ReadResourceResult", result)
        assert result["contents"] == [%{"uri" => uri, "mimeType" => mime, "blob" => "aGk="}]
      end
    end

    test "#{era}: a result that already has contents is untouched" do
      result = read("raw://contents", @era)

      assert :ok == McpSchema.validate(@version, "ReadResourceResult", result)

      assert result["contents"] == [
               %{"uri" => "raw://contents", "mimeType" => "application/xml", "text" => "<x/>"}
             ]
    end

    test "#{era}: an MFA read handler is converted too" do
      result = read("static://mfa", @era)

      assert :ok == McpSchema.validate(@version, "ReadResourceResult", result)

      assert result["contents"] == [
               %{"uri" => "static://mfa", "mimeType" => "text/plain", "text" => "from mfa"}
             ]
    end
  end
end
