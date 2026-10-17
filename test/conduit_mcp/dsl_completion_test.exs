defmodule ConduitMcp.DSLCompletionTest do
  use ExUnit.Case, async: true

  alias ConduitMcp.Capabilities
  alias ConduitMcp.Handler

  @version "2026-07-28"

  defmodule Paths do
    def complete(_conn, prefix),
      do: Enum.filter(["lib/", "test/", "mix.exs"], &String.starts_with?(&1, prefix))

    def user_ids(_conn, prefix), do: Enum.map(1..3, &(prefix <> Integer.to_string(&1)))
  end

  defmodule CompletionServer do
    use ConduitMcp.Server

    prompt "code_review", "Code review" do
      arg(:language, :string, "Language")
      arg(:style, :string, "Style")
      get(fn _conn, _args -> [user("review")] end)

      complete(:language, fn _conn, prefix ->
        Enum.filter(~w(elixir erlang python), &String.starts_with?(&1, prefix))
      end)

      complete(:style, fn _conn, _prefix -> ["terse", "thorough"] end)
    end

    prompt "many", "Many values" do
      arg(:n, :string, "A number")
      get(fn _conn, _args -> [user("many")] end)
      complete(:n, fn _conn, _prefix -> Enum.map(1..150, &Integer.to_string/1) end)
    end

    resource "file:///{path}" do
      read(fn _conn, _params, _opts -> text("file") end)
      complete(:path, &Paths.complete/2)
    end

    resource "vault://{id}" do
      scope("vault:read")
      read(fn _conn, _params, _opts -> text("secret") end)
      complete(:id, fn _conn, _prefix -> ["one", "two"] end)
    end

    resource "user://{id}/{tab}" do
      read(fn _conn, _params, _opts -> text("user") end)
      complete(:id, Paths, :user_ids)
    end
  end

  defp request(ref, argument, era) do
    params = %{"ref" => ref, "argument" => argument}

    params =
      if era == :modern,
        do:
          Map.put(params, "_meta", %{
            "io.modelcontextprotocol/protocolVersion" => @version,
            "io.modelcontextprotocol/clientCapabilities" => %{}
          }),
        else: params

    %{"jsonrpc" => "2.0", "id" => 1, "method" => "completion/complete", "params" => params}
  end

  defp complete(ref, argument, era, conn \\ %Plug.Conn{}) do
    assert {:reply, response} =
             Handler.dispatch(request(ref, argument, era), CompletionServer, conn)

    response
  end

  defp prompt_ref(name), do: %{"type" => "ref/prompt", "name" => name}
  defp resource_ref(uri), do: %{"type" => "ref/resource", "uri" => uri}

  for era <- [:legacy, :modern] do
    describe "completion/complete (#{era})" do
      test "completes a prompt argument by name, with the typed prefix" do
        response =
          complete(
            prompt_ref("code_review"),
            %{"name" => "language", "value" => "e"},
            unquote(era)
          )

        assert %{"values" => ["elixir", "erlang"], "total" => 2, "hasMore" => false} =
                 response["result"]["completion"]

        response =
          complete(prompt_ref("code_review"), %{"name" => "style", "value" => ""}, unquote(era))

        assert response["result"]["completion"]["values"] == ["terse", "thorough"]
      end

      test "completes a resource template parameter" do
        response =
          complete(
            resource_ref("file:///{path}"),
            %{"name" => "path", "value" => "t"},
            unquote(era)
          )

        assert %{"values" => ["test/"], "total" => 1, "hasMore" => false} =
                 response["result"]["completion"]
      end

      test "caps values at 100, with the full total and hasMore" do
        response = complete(prompt_ref("many"), %{"name" => "n", "value" => ""}, unquote(era))
        completion = response["result"]["completion"]

        assert length(completion["values"]) == 100
        assert completion["values"] == Enum.map(1..100, &Integer.to_string/1)
        assert completion["total"] == 150
        assert completion["hasMore"] == true
      end

      test "an argument without a completion is empty; an unknown ref is -32602" do
        response =
          complete(prompt_ref("code_review"), %{"name" => "other", "value" => ""}, unquote(era))

        assert response["result"]["completion"] == %{
                 "values" => [],
                 "total" => 0,
                 "hasMore" => false
               }

        for ref <- [prompt_ref("nope"), resource_ref("nope://{x}")] do
          response = complete(ref, %{"name" => "x", "value" => ""}, unquote(era))
          assert %{"error" => %{"code" => -32602}} = response
        end
      end

      test "a scoped resource's completion requires its scope" do
        argument = %{"name" => "id", "value" => ""}

        assert %{"error" => %{"data" => %{"error" => "insufficient_scope"}}} =
                 complete(resource_ref("vault://{id}"), argument, unquote(era))

        scoped = Plug.Conn.assign(%Plug.Conn{}, :oauth_scopes, ["vault:read"])
        response = complete(resource_ref("vault://{id}"), argument, unquote(era), scoped)
        assert response["result"]["completion"]["values"] == ["one", "two"]
      end
    end
  end

  test "the completions capability is advertised in both eras" do
    assert Capabilities.build(CompletionServer)["completions"] == %{}
    assert Capabilities.build(CompletionServer, era: :modern)["completions"] == %{}
  end

  test "a module and function name is called with the conn and the value" do
    response =
      complete(
        resource_ref("user://{id}/{tab}"),
        %{"name" => "id", "value" => "u"},
        :modern
      )

    assert response["result"]["completion"]["values"] == ["u1", "u2", "u3"]
    assert response["result"]["resultType"] == "complete"
  end

  defp compile(body) do
    name = Module.concat(__MODULE__, "Bad#{System.unique_integer([:positive])}")

    Code.compile_quoted(
      quote do
        defmodule unquote(name) do
          use ConduitMcp.Server
          unquote(body)
        end
      end
    )
  end

  describe "compile errors" do
    test "a name that is not an argument of the prompt or template" do
      assert_raise CompileError, ~r/"nope", which is not an argument of ref\/prompt "p"/, fn ->
        compile(
          quote do
            prompt "p", "P" do
              arg(:a, :string, "A")
              get(fn _conn, _args -> [] end)
              complete(:nope, fn _conn, _value -> [] end)
            end
          end
        )
      end

      assert_raise CompileError, ~r/"path", which is not an argument of ref\/resource/, fn ->
        compile(
          quote do
            resource "doc://{id}" do
              read(fn _conn, _params, _opts -> text("") end)
              complete(:path, fn _conn, _value -> [] end)
            end
          end
        )
      end
    end

    test "the same name twice, or outside a prompt or resource" do
      assert_raise CompileError, ~r/declared twice/, fn ->
        compile(
          quote do
            prompt "p", "P" do
              arg(:a, :string, "A")
              get(fn _conn, _args -> [] end)
              complete(:a, fn _conn, _value -> [] end)
              complete(:a, fn _conn, _value -> [] end)
            end
          end
        )
      end

      assert_raise CompileError, ~r/inside a prompt or resource block/, fn ->
        compile(
          quote do
            tool "t", "T" do
              handle(fn _conn, _params -> text("") end)
              complete(:a, fn _conn, _value -> [] end)
            end
          end
        )
      end
    end
  end
end
