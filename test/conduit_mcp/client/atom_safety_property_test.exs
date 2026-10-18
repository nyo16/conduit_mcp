defmodule ConduitMcp.Client.AtomSafetyPropertyTest do
  # MR-1..5: nothing a server sends grows the atom table. Random handshake
  # capabilities, notifications, server requests, `tools/list` results and
  # multi-round-trip `input_required` results go through a real client (the
  # test plays the server over `ConduitMcp.Test.Client.FakeHTTPTransport`,
  # so the HTTP-only `x-mcp-header` paths run too), with every handler
  # callback and both schema validations on.
  #
  # Every generated string starts with a prefix made at run time, so none
  # can already be an atom. A first pass with its own prefix loads every
  # module and runs every path once; the measured pass then asserts that
  # `:erlang.system_info(:atom_count)` is unchanged by each run.
  #
  # `async: false`: the atom table is node-wide, so no other test may run
  # alongside.
  use ExUnit.Case, async: false
  use ExUnitProperties

  import ConduitMcp.Test.Client.Harness

  alias ConduitMcp.Client
  alias ConduitMcp.Test.Client.FakeHTTPTransport
  alias ConduitMcp.Test.Client.FakeTransport

  defmodule EveryCallback do
    @behaviour ConduitMcp.Client.Handler

    @impl true
    def handle_sampling(_params, _ctx) do
      {:ok,
       %{"role" => "assistant", "content" => %{"type" => "text", "text" => "hi"}, "model" => "m"}}
    end

    @impl true
    def handle_elicitation(_params, _ctx), do: {:ok, %{"action" => "decline"}}

    @impl true
    def elicitation_modes, do: [:form, :url]

    @impl true
    def list_roots(_ctx), do: {:ok, %{"roots" => [%{"uri" => "file:///srv"}]}}

    @impl true
    def handle_notification(_method, _params, _ctx), do: :ok

    @impl true
    def handle_log(_level, _params, _ctx), do: :ok
  end

  @known_notifications [
    "notifications/message",
    "notifications/progress",
    "notifications/cancelled",
    "notifications/tools/list_changed",
    "notifications/prompts/list_changed",
    "notifications/resources/list_changed",
    "notifications/resources/updated",
    "notifications/subscriptions/acknowledged",
    "notifications/tasks/status"
  ]

  @known_params [
    "level",
    "logger",
    "data",
    "progressToken",
    "progress",
    "total",
    "message",
    "requestId",
    "reason",
    "uri",
    "taskId",
    "status",
    "_meta"
  ]

  @schema_keywords [
    "type",
    "format",
    "pattern",
    "enum",
    "const",
    "minimum",
    "maxLength",
    "default",
    "title",
    "x-mcp-header",
    "contentEncoding",
    "$ref"
  ]

  @annotations ["readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint", "title"]
  @content_types ["text", "image", "audio", "resource", "resource_link"]
  @types ["string", "integer", "boolean", "number", "object", "array", "null"]

  @complete %{"resultType" => "complete", "content" => [%{"type" => "text", "text" => "ok"}]}

  property "random server input through the client never creates an atom" do
    # Loading a module adds its literal atoms (bounded, never input-driven);
    # load them all now so only input can move the count below.
    for {app, _description, _version} <- Application.loaded_applications(),
        module <- Application.spec(app, :modules) || [],
        do: Code.ensure_loaded(module)

    run_pass(fresh_prefix(), 15, false)

    before = :erlang.system_info(:atom_count)
    run_pass(fresh_prefix(), 50, true)
    assert :erlang.system_info(:atom_count) == before, "created #{inspect(atoms_since(before))}"
  end

  # --- one pass ---------------------------------------------------------------

  defp fresh_prefix, do: "Zq#{System.unique_integer([:positive])}x"

  defp run_pass(prefix, runs, measure?) do
    check all(script <- script(prefix), max_runs: runs, max_shrinking_steps: 20) do
      before = :erlang.system_info(:atom_count)
      run(script)

      if measure? do
        assert :erlang.system_info(:atom_count) == before,
               "one run created #{inspect(atoms_since(before))}"
      end
    end
  end

  # The atoms created since the table held `count`, for the failure message:
  # the atom at index `i` decodes from an external-format atom cache
  # reference (tag 75) with that index.
  defp atoms_since(count) do
    for index <- count..(:erlang.system_info(:atom_count) - 1)//1,
        do: :erlang.binary_to_term(<<131, 75, index::24>>)
  end

  defp run(script) do
    name = {__MODULE__, make_ref()}

    start_supervised!(
      Supervisor.child_spec(
        {Client,
         name: name,
         transport: {FakeHTTPTransport, test_pid: self()},
         backoff: fn _attempt -> 0 end,
         max_reconnects: 0,
         handler: EveryCallback,
         sampling: [context: true, tools: true],
         validate: [arguments: true, structured_content: true]},
        id: name
      )
    )

    assert_receive {:fake_transport, conn, :connect}
    FakeTransport.push(conn, {:connected, %{}})
    {id, _discover, _opts} = expect_request(conn, "server/discover")
    reply(conn, id, discover_result(script.capabilities))
    assert :ok = Client.await_ready(name)
    :ok = Client.subscribe_notifications(name)

    for event <- script.events, do: FakeTransport.push(conn, event)

    serve(conn, Task.async(fn -> Client.list_tools(name) end), script)

    {tool_name, args} = call_target(script.tools)

    serve(
      conn,
      Task.async(fn -> Client.call_tool(name, tool_name, args, timeout: 2_000) end),
      script
    )

    # Everything pushed has been handled once the connection answers.
    _ = state(conn)
    stop_supervised!(name)
    flush()
  end

  # Plays the server until `task` returns: `tools/list` gets the script's
  # tools, `tools/call` its `input_required` rounds and then its result.
  # Anything else (a listen, a response to a server request) is left for
  # `flush/0`.
  defp serve(conn, %Task{ref: ref} = task, script) do
    receive do
      {:fake_transport, ^conn, {:request, %{"method" => "tools/list", "id" => id}, _}} ->
        reply(conn, id, %{"tools" => script.tools})
        serve(conn, task, script)

      {:fake_transport, ^conn, {:request, %{"method" => "tools/call", "id" => id}, _}} ->
        case script.rounds do
          [round | rest] ->
            reply(conn, id, round)
            serve(conn, task, %{script | rounds: rest})

          [] ->
            reply(conn, id, script.result)
            serve(conn, task, script)
        end

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result
    after
      5_000 -> flunk("the client stalled")
    end
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  # The first listed tool, with arguments its schema accepts, so the call
  # reaches the wire (and its `x-mcp-header` mirroring) as often as not.
  defp call_target([%{"name" => name, "inputSchema" => %{"properties" => properties}} | _]) do
    args =
      Map.new(properties, fn {key, property} ->
        value =
          case property["type"] do
            "integer" -> 7
            "boolean" -> true
            "number" -> 1.5
            _other -> "v" <> key
          end

        {key, value}
      end)

    {name, args}
  end

  # --- generators -------------------------------------------------------------

  defp script(prefix) do
    gen all(
          capabilities <- capabilities(prefix),
          events <- list_of(event(prefix), max_length: 6),
          tools <- list_of(tool(prefix), min_length: 1, max_length: 3),
          rounds <- list_of(input_required(prefix), min_length: 1, max_length: 2),
          result <- call_result(prefix)
        ) do
      %{capabilities: capabilities, events: events, tools: tools, rounds: rounds, result: result}
    end
  end

  # Strings that cannot already be atoms: the run's prefix, then anything.
  defp text(prefix) do
    one_of([string(:alphanumeric, max_length: 6), string(:utf8, max_length: 6)])
    |> map(&(prefix <> &1))
  end

  defp token(prefix), do: map(string(:alphanumeric, max_length: 6), &(prefix <> &1))

  # Mostly a name the client knows (so the run goes deep), sometimes not.
  defp key(prefix, known), do: frequency([{3, member_of(known)}, {1, text(prefix)}])

  # Mostly `valid`, sometimes `hostile`.
  defp mostly(valid, hostile), do: frequency([{4, valid}, {1, hostile}])

  defp json(prefix) do
    leaf = one_of([text(prefix), integer(), boolean(), constant(nil), float()])

    tree(leaf, fn child ->
      one_of([list_of(child, max_length: 3), map_of(text(prefix), child, max_length: 3)])
    end)
  end

  defp extra(prefix), do: map_of(text(prefix), json(prefix), max_length: 2)

  defp with_extra(fixed, prefix) do
    bind(fixed, fn map -> map(extra(prefix), &Map.merge(&1, map)) end)
  end

  defp capabilities(prefix) do
    map(
      fixed_map(%{
        "experimental" => map_of(text(prefix), extra(prefix), max_length: 2),
        "logging" => constant(%{})
      }),
      &Map.merge(&1, %{"tools" => %{"listChanged" => true}, "resources" => %{"subscribe" => true}})
    )
  end

  defp event(prefix) do
    one_of([
      map(
        {key(prefix, @known_notifications),
         map_of(key(prefix, @known_params), json(prefix), max_length: 4)},
        fn {method, params} -> {:notification, method, params} end
      ),
      map(
        {key(prefix, @known_notifications), log_params(prefix)},
        fn {method, params} -> {:notification, method, params} end
      ),
      map(
        {integer(1..1_000), key(prefix, ["roots/list", "sampling/createMessage"]), extra(prefix)},
        fn {id, method, params} ->
          message = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
          {:server_request, id, message, nil}
        end
      )
    ])
  end

  defp log_params(prefix) do
    fixed_map(%{
      "level" => key(prefix, ["debug", "info", "notice", "warning", "error", "emergency"]),
      "logger" => text(prefix),
      "data" => json(prefix)
    })
  end

  defp tool(prefix) do
    with_extra(
      fixed_map(%{
        "name" => mostly(token(prefix), text(prefix)),
        "title" => text(prefix),
        "description" => text(prefix),
        "inputSchema" => schema(prefix),
        "outputSchema" => mostly(constant(%{"type" => "object"}), schema(prefix)),
        "annotations" => map_of(key(prefix, @annotations), json(prefix), max_length: 3),
        "_meta" => extra(prefix)
      }),
      prefix
    )
  end

  defp schema(prefix) do
    fixed_map(%{
      "type" => constant("object"),
      "properties" => map_of(token(prefix), schema_property(prefix), max_length: 3),
      "required" => mostly(constant([]), list_of(token(prefix), max_length: 1))
    })
  end

  # A primitive property, usually with a valid `x-mcp-header` or none, and
  # sometimes with random keywords, a random type or a hostile header name.
  defp schema_property(prefix) do
    gen all(
          random <-
            mostly(
              constant(%{}),
              map_of(key(prefix, @schema_keywords), json(prefix), max_length: 2)
            ),
          type <- mostly(member_of(["string", "integer", "boolean"]), key(prefix, @types)),
          header <- frequency([{2, constant(nil)}, {2, token(prefix)}, {1, text(prefix)}])
        ) do
      fixed = if header, do: %{"type" => type, "x-mcp-header" => header}, else: %{"type" => type}
      Map.merge(random, fixed)
    end
  end

  defp input_required(prefix) do
    with_extra(
      fixed_map(%{
        "resultType" => mostly(constant("input_required"), text(prefix)),
        "inputRequests" => map_of(text(prefix), input_request(prefix), max_length: 3),
        "requestState" => text(prefix)
      }),
      prefix
    )
  end

  defp input_request(prefix) do
    frequency([
      {3,
       fixed_map(%{
         "method" => constant("sampling/createMessage"),
         "params" =>
           with_extra(
             fixed_map(%{
               "messages" => list_of(json(prefix), max_length: 2),
               "maxTokens" => integer(1..100),
               "includeContext" => key(prefix, ["none", "thisServer", "allServers"])
             }),
             prefix
           )
       })},
      {3,
       fixed_map(%{
         "method" => constant("elicitation/create"),
         "params" =>
           with_extra(
             fixed_map(%{
               "mode" => key(prefix, ["form", "url"]),
               "message" => text(prefix),
               "requestedSchema" => schema(prefix),
               "url" => map(text(prefix), &("https://example.com/" <> &1)),
               "elicitationId" => text(prefix)
             }),
             prefix
           )
       })},
      {3, constant(%{"method" => "roots/list"})},
      {1, fixed_map(%{"method" => text(prefix), "params" => extra(prefix)})}
    ])
  end

  defp call_result(prefix) do
    content =
      with_extra(
        fixed_map(%{
          "type" => key(prefix, @content_types),
          "text" => text(prefix),
          "mimeType" => text(prefix)
        }),
        prefix
      )

    one_of([
      constant(@complete),
      with_extra(
        fixed_map(%{
          "resultType" => key(prefix, ["complete"]),
          "content" => list_of(content, max_length: 2),
          "structuredContent" => map_of(text(prefix), json(prefix), max_length: 2),
          "isError" => boolean(),
          "_meta" => extra(prefix)
        }),
        prefix
      )
    ])
  end
end
