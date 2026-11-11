defmodule ConduitMcp.Transport.BodyLimitTest do
  # Real sockets: Bandit on port 0 and a raw HTTP/1.1 client over `:gen_tcp`.
  # Bandit 1.14's `read_body` may return more than `:length` bytes, so the
  # body limit is only proven by a body that actually crosses it on the wire.
  use ExUnit.Case, async: true

  @moduletag :integration

  alias ConduitMcp.Transport.SSE
  alias ConduitMcp.Transport.StreamableHTTP

  @limit 1_000_000

  defmodule RecordingServer do
    use ConduitMcp.Server, dsl: false

    @impl true
    def handle_list_tools(_conn),
      do: {:ok, %{"tools" => [%{"name" => "record", "inputSchema" => %{"type" => "object"}}]}}

    @impl true
    def handle_call_tool(_conn, "record", %{"test" => test}) do
      send(:persistent_term.get({__MODULE__, test}), :handler_ran)
      {:ok, %{"content" => [%{"type" => "text", "text" => "ok"}]}}
    end
  end

  setup do
    test = "body-limit-#{System.unique_integer([:positive])}"
    :persistent_term.put({RecordingServer, test}, self())
    on_exit(fn -> :persistent_term.erase({RecordingServer, test}) end)
    {:ok, key: test}
  end

  for {transport, path} <- [{StreamableHTTP, "/"}, {SSE, "/message"}] do
    describe "#{inspect(transport)}" do
      test "a body one byte over the limit is 413 and reaches no handler", %{key: test} do
        port = start_server(unquote(transport))

        assert {413, _body} = post(port, unquote(path), body_of_size(test, @limit + 1))
        refute_received :handler_ran
      end

      test "a body of exactly the limit is handled", %{key: test} do
        port = start_server(unquote(transport))

        assert {status, _body} = post(port, unquote(path), body_of_size(test, @limit))
        assert status in [200, 202]
        assert_receive :handler_ran, 2_000
      end

      test "a chunked body over the limit is 413 and reaches no handler", %{key: test} do
        port = start_server(unquote(transport))
        body = body_of_size(test, @limit + 1)
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

        head = [
          "POST #{unquote(path)} HTTP/1.1\r\n",
          "host: localhost\r\n",
          "content-type: application/json\r\n",
          "accept: application/json, text/event-stream\r\n",
          "transfer-encoding: chunked\r\n\r\n"
        ]

        # Two chunks, then the terminating zero-length chunk.
        <<first::binary-size(500_000), second::binary>> = body

        chunks =
          for part <- [first, second],
              do: [Integer.to_string(byte_size(part), 16), "\r\n", part, "\r\n"]

        # The server may answer and close before it has read the whole body.
        _ = :gen_tcp.send(socket, [head, chunks, "0\r\n\r\n"])
        assert {413, _body} = read_response(socket, "")
        :gen_tcp.close(socket)
        refute_received :handler_ran
      end

      test "a custom :max_body_bytes is enforced at its own boundary", %{key: test} do
        port = start_server(unquote(transport), max_body_bytes: 200)

        assert {413, _body} = post(port, unquote(path), body_of_size(test, 201))
        refute_received :handler_ran

        assert {status, _body} = post(port, unquote(path), body_of_size(test, 200))
        assert status in [200, 202]
        assert_receive :handler_ran, 2_000
      end

      # Bandit reads an unread body to its end (up to 8 MB) before the next
      # request on a keep-alive connection. A request rejected before the body
      # is parsed must close the connection instead, or the rejection costs a
      # body read after all.
      test "a request rejected before parsing closes the connection, not drains it" do
        port = start_server(unquote(transport), auth: [strategy: :bearer_token, token: "t"])
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

        # Announce 4 MB, send 1 KB: a draining server waits for the rest.
        :ok =
          :gen_tcp.send(socket, [request_head(unquote(path), 4_000_000), :binary.copy("a", 1_000)])

        assert {401, headers} = read_head(socket, "")
        assert {"connection", "close"} in headers
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
      end

      test "a request rejected with no body keeps the connection" do
        port = start_server(unquote(transport), auth: [strategy: :bearer_token, token: "t"])
        {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

        :ok = :gen_tcp.send(socket, request_head(unquote(path), 0))

        assert {401, headers} = read_head(socket, "")
        refute {"connection", "close"} in headers
        :gen_tcp.close(socket)
      end
    end
  end

  defp request_head(path, content_length) do
    [
      "POST #{path} HTTP/1.1\r\n",
      "host: localhost\r\n",
      "content-type: application/json\r\n",
      "accept: application/json, text/event-stream\r\n",
      "content-length: #{content_length}\r\n\r\n"
    ]
  end

  # The status and downcased headers of a response, once its head arrived.
  defp read_head(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, _rest] ->
        [status_line | lines] = String.split(head, "\r\n")
        [_, status] = Regex.run(~r/^HTTP\/1\.1 (\d{3})/, status_line)

        headers =
          for line <- lines,
              [k, v] = String.split(line, ": ", parts: 2),
              do: {String.downcase(k), v}

        {String.to_integer(status), headers}

      _ ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, data} -> read_head(socket, acc <> data)
          {:error, reason} -> flunk("#{inspect(reason)}; received: #{inspect(acc)}")
        end
    end
  end

  defp start_server(transport, opts \\ []) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {transport, [server_module: RecordingServer, allowed_origins: "*"] ++ opts},
         port: 0,
         ip: :loopback,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  # A legacy `tools/call` whose JSON encoding is exactly `size` bytes.
  defp body_of_size(test, size) do
    envelope = fn pad ->
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => "record", "arguments" => %{"test" => test, "pad" => pad}}
      })
    end

    overhead = byte_size(envelope.(""))
    body = envelope.(String.duplicate("a", size - overhead))
    ^size = byte_size(body)
    body
  end

  defp post(port, path, body) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    head = request_head(path, byte_size(body))

    # The server may answer and close before it has read the whole body.
    _ = :gen_tcp.send(socket, [head, body])
    response = read_response(socket, "")
    :gen_tcp.close(socket)
    response
  end

  defp read_response(socket, acc) do
    case parse(acc) do
      {:ok, status, body} ->
        {status, body}

      :more ->
        case :gen_tcp.recv(socket, 0, 2_000) do
          {:ok, data} -> read_response(socket, acc <> data)
          {:error, reason} -> flunk("#{inspect(reason)}; received: #{inspect(acc)}")
        end
    end
  end

  defp parse(acc) do
    with [head, body] <- String.split(acc, "\r\n\r\n", parts: 2),
         [_, status] <- Regex.run(~r/^HTTP\/1\.1 (\d{3})/, head),
         [_, length] <- Regex.run(~r/content-length: (\d+)/i, head),
         true <- byte_size(body) >= String.to_integer(length) do
      {:ok, String.to_integer(status), body}
    else
      _ -> :more
    end
  end
end
