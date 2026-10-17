defmodule ConduitMcp.Client.Transport.StdioTest do
  # The stdio transport driven directly from the test process (which plays
  # the connection) against cheap POSIX fixtures: `cat` loopback, `/bin/sh`
  # scripts. The Elixir MCP fixture runs in `ConduitMcp.Client.StdioClientTest`.
  use ExUnit.Case, async: true

  alias ConduitMcp.Client.Config
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.Transport.Stdio
  alias ConduitMcp.Test.Client.StdioFixture

  @moduletag :stdio

  if Stdio.windows?(), do: @moduletag(skip: "the stdio fixtures are POSIX scripts")

  # --- helpers -------------------------------------------------------------

  defp open!(opts) do
    assert {:ok, state} = Stdio.init(opts, %{owner: self(), task_sup: nil, key: :test})
    {:ok, state} = Stdio.connect(state)
    assert {[{:connected, %{os_pid: os_pid}}], state} = events(state)
    {state, os_pid}
  end

  defp events(state, timeout \\ 2_000) do
    ref = state.ref
    assert_receive {Stdio, ^ref, _events} = message, timeout
    {:ok, events, state} = Stdio.handle_info(message, state)
    {events, state}
  end

  defp sh(script, opts \\ []),
    do: [command: "/bin/sh", args: ["-c", script | Keyword.get(opts, :argv, [])]]

  # Closes the transport and asserts the server process is gone.
  defp close_and_assert_reaped(state, os_pid) do
    owner = state.port_owner
    :ok = Stdio.close(state, :test_done)
    StdioFixture.await_reaped(owner)
    refute StdioFixture.os_alive?(os_pid)
  end

  defp request(id, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call", "params" => params}

  # --- options -------------------------------------------------------------

  describe "option validation" do
    test "a command with whitespace raises naming the key (ST-1)" do
      error =
        assert_raise ArgumentError, fn ->
          Config.new!(name: :x, transport: {Stdio, command: "npx -y foo"})
        end

      assert error.message =~ ":transport"
      assert error.message =~ ":command"
      assert error.message =~ "pass arguments in :args"
    end

    test "a relative or missing cd raises (ST-9)", %{} do
      for cd <- ["relative/dir", "/definitely/not/a/dir"] do
        assert_raise ArgumentError, ~r/:cd/, fn ->
          Config.new!(name: :x, transport: {Stdio, command: "cat", cd: cd})
        end
      end
    end

    test "a relative command path, a bad stderr or bad args raise" do
      for opts <- [
            [command: "bin/server"],
            [command: "cat", stderr: {:file, "relative.log"}],
            [command: "cat", stderr: :pipe],
            [command: "cat", args: "--flag"]
          ] do
        assert_raise ArgumentError, fn -> Config.new!(name: :x, transport: {Stdio, opts}) end
      end
    end

    test "an invalid env value is refused without echoing any value" do
      error =
        assert_raise ArgumentError, fn ->
          Config.new!(
            name: :x,
            transport: {Stdio, command: "cat", env: %{"TOKEN" => "s3cr3t\0", "N" => 1}}
          )
        end

      assert error.message =~ ":env"
      refute error.message =~ "s3cr3t"

      assert {:ok, opts} = Stdio.validate_options(command: "cat", env: [{"T", Secret.new("x")}])
      assert [{"T", %Secret{}}] = opts[:env]
    end

    test "batch files are refused unless allowed, and then unsafe args still are (ST-7)" do
      assert Stdio.batch_file?("C:\\tools\\server.CMD")
      assert Stdio.batch_file?("/opt/run.bat")
      refute Stdio.batch_file?("/usr/bin/node")
      assert Stdio.batch_unsafe_arg?("a&b")
      refute Stdio.batch_unsafe_arg?("--port=3000")

      assert {:error, message} = Stdio.validate_options(command: "/opt/run.bat")
      assert message =~ "allow_batch_files"

      assert {:ok, _opts} =
               Stdio.validate_options(command: "/opt/run.bat", allow_batch_files: true)

      assert {:error, message} =
               Stdio.validate_options(
                 command: "/opt/run.bat",
                 allow_batch_files: true,
                 args: ["x|calc"]
               )

      assert message =~ ":args"
    end

    test "an executable that is not found fails init" do
      assert {:error, {:command_not_found, "conduit-mcp-no-such-command"}} =
               Stdio.init([command: "conduit-mcp-no-such-command"], %{owner: self()})
    end
  end

  describe "child_env/3 (ST-2)" do
    test "keeps only allowlisted inherited variables and layers :env on top" do
      inherited = %{
        "PATH" => "/bin",
        "HOME" => "/home/me",
        "AWS_SECRET_ACCESS_KEY" => "leak",
        "TERM" => "() { :; }; echo pwned"
      }

      env =
        Stdio.child_env(
          inherited,
          [{"API_KEY", Secret.new("k")}, {"HOME", "/srv"}],
          :unix
        )
        |> Map.new(fn {name, value} -> {to_string(name), value && to_string(value)} end)

      assert env == %{
               "PATH" => "/bin",
               "HOME" => "/srv",
               "AWS_SECRET_ACCESS_KEY" => false,
               "TERM" => false,
               "API_KEY" => "k"
             }
    end

    test "Windows names are compared case-insensitively" do
      env =
        Stdio.child_env(%{"Path" => "C:\\bin", "ComSpec" => "cmd.exe"}, [], :win32)
        |> Map.new(fn {name, value} -> {to_string(name), value && to_string(value)} end)

      assert env == %{"Path" => "C:\\bin", "ComSpec" => false}
    end
  end

  # --- the process ---------------------------------------------------------

  describe "cat loopback" do
    test "requests, notifications, responses and cancellations frame both ways" do
      {state, os_pid} = open!(command: "cat")

      assert {:ok, nil, state} = Stdio.request(state, request(1, %{"text" => "a\nb"}), nil, [])

      assert {[{:server_request, 1, %{"params" => %{"text" => "a\nb"}}, nil}], state} =
               events(state)

      assert {:ok, state} = Stdio.notify(state, %{"jsonrpc" => "2.0", "method" => "n/x"})
      assert {[{:notification, "n/x", %{}}], state} = events(state)

      assert {:ok, state} =
               Stdio.respond(state, %{"jsonrpc" => "2.0", "id" => 9, "result" => %{"ok" => 1}})

      assert {[{:response, 9, %{"result" => %{"ok" => 1}}}], state} = events(state)

      assert {:ok, state} = Stdio.cancel(state, 7, nil, :timeout)

      assert {[
                {:notification, "notifications/cancelled",
                 %{"requestId" => 7, "reason" => "timeout"}}
              ], state} = events(state)

      close_and_assert_reaped(state, os_pid)
    end

    test "a 2 MB message arriving in many chunks is reassembled" do
      {state, os_pid} = open!(command: "cat")
      big = String.duplicate("0123456789", 200_000)

      {:ok, nil, state} = Stdio.request(state, request(2, %{"big" => big}), nil, [])
      {events, state} = collect(state, 1)
      assert [{:server_request, 2, %{"params" => %{"big" => ^big}}, nil}] = events

      close_and_assert_reaped(state, os_pid)
    end

    test "a value that cannot be encoded fails that request only" do
      {state, os_pid} = open!(command: "cat")

      assert {:error, :unencodable, state} =
               Stdio.request(state, request(3, %{"bad" => {:tuple}}), nil, [])

      assert {:error, :unencodable, state} =
               Stdio.request(state, request(4, %{"s" => Secret.new("x")}), nil, [])

      {:ok, nil, state} = Stdio.request(state, request(5), nil, [])
      assert {[{:server_request, 5, _, nil}], state} = events(state)
      close_and_assert_reaped(state, os_pid)
    end

    test "a line over max_message_bytes closes and stops the server (ST-4)" do
      {state, os_pid} = open!(command: "cat", max_message_bytes: 100)
      owner = state.port_owner

      {:ok, nil, state} =
        Stdio.request(state, request(1, %{"pad" => String.duplicate("x", 200)}), nil, [])

      assert {[{:closed, :message_too_large}], state} = events(state)
      assert state.port_owner == nil
      assert {:error, :not_connected, _state} = Stdio.request(state, request(2), nil, [])

      StdioFixture.await_reaped(owner)
      refute StdioFixture.os_alive?(os_pid)
    end
  end

  defp collect(state, count, acc \\ [])
  defp collect(state, count, acc) when length(acc) >= count, do: {acc, state}

  defp collect(state, count, acc) do
    {events, state} = events(state)
    collect(state, count, acc ++ events)
  end

  describe "server output" do
    test "junk lines within the budget are dropped" do
      {state, os_pid} =
        open!(
          sh(
            ~s(echo junk; echo "{not json"; echo '[1]'; echo '{"jsonrpc":"2.0","method":"hi"}'; exec cat)
          )
        )

      assert {[{:notification, "hi", %{}}], state} = events(state)
      close_and_assert_reaped(state, os_pid)
    end

    test "more junk lines in a row than max_junk_lines restart the server" do
      {state, _os_pid} =
        open!(sh(~s|i=0; while [ $i -lt 11 ]; do echo junk; i=$((i+1)); done; exec cat|))

      owner = state.port_owner
      assert {[{:closed, :junk_output}], _state} = events(state)
      StdioFixture.await_reaped(owner)
    end

    test "the server exiting reports its exit status" do
      {state, _os_pid} = open!(sh("exit 7"))
      assert {[{:closed, {:exit_status, 7}}], state} = events(state)
      assert state.port_owner == nil
    end

    test "an executable that cannot be run reports spawn_failed", %{} do
      path =
        Path.join(
          System.tmp_dir!(),
          "conduit_mcp_not_executable_#{System.unique_integer([:positive])}"
        )

      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)

      {:ok, state} = Stdio.init([command: path], %{owner: self()})
      {:ok, state} = Stdio.connect(state)
      assert {[{:closed, {:spawn_failed, :eacces}}], _state} = events(state)
    end
  end

  describe "the child process" do
    @describetag :tmp_dir

    test "inherits only the allowlisted environment plus :env (ST-2)", %{tmp_dir: dir} do
      System.put_env("CONDUIT_TEST_SECRET", "must-not-leak")
      on_exit(fn -> System.delete_env("CONDUIT_TEST_SECRET") end)
      log = Path.join(dir, "env.log")

      {state, _os_pid} =
        open!(sh("env >&2") ++ [env: %{"EXTRA" => Secret.new("given")}, stderr: {:file, log}])

      assert {[{:closed, {:exit_status, 0}}], _state} = events(state)

      env =
        log
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Map.new(&List.to_tuple(String.split(&1, "=", parts: 2)))

      refute Map.has_key?(env, "CONDUIT_TEST_SECRET")
      assert env["PATH"] == System.get_env("PATH")
      assert env["EXTRA"] == "given"

      # What the shell itself sets is allowed besides the allowlist.
      allowed = ~w(HOME LOGNAME PATH SHELL TERM USER EXTRA PWD OLDPWD SHLVL _)
      assert Map.keys(env) -- allowed == []
    end

    test "arguments arrive literally, never through a shell (ST-1)", %{tmp_dir: dir} do
      log = Path.join(dir, "args.log")
      args = ["; touch x", "$(touch y)", "a b", "*"]

      {state, _os_pid} =
        open!(
          sh(~s(printf '%s\\n' "$@" >&2), argv: ["sh" | args]) ++
            [cd: dir, stderr: {:file, log}]
        )

      assert {[{:closed, {:exit_status, 0}}], _state} = events(state)
      assert File.read!(log) == Enum.map_join(args, &(&1 <> "\n"))
      refute File.exists?(Path.join(dir, "x"))
      refute File.exists?(Path.join(dir, "y"))
    end

    test "stderr: :discard keeps stdout framing intact" do
      {state, os_pid} =
        open!(
          sh(~s(echo noise >&2; echo '{"jsonrpc":"2.0","method":"up"}'; exec cat)) ++
            [stderr: :discard]
        )

      assert {[{:notification, "up", %{}}], state} = events(state)
      close_and_assert_reaped(state, os_pid)
    end
  end

  describe "shutdown escalation (ST-3)" do
    @describetag :tmp_dir

    test "a server that exits on EOF is reaped without signals" do
      {state, os_pid} = open!(command: "cat", stdin_grace: 5_000)
      owner = state.port_owner
      :ok = Stdio.close(state, :done)
      assert StdioFixture.await_reaped(owner) < 2_000
      refute StdioFixture.os_alive?(os_pid)
    end

    test "a server that ignores EOF gets TERM after stdin_grace" do
      {state, os_pid} =
        open!(sh("while :; do sleep 1; done") ++ [stdin_grace: 200, term_grace: 5_000])

      owner = state.port_owner
      :ok = Stdio.close(state, :done)
      elapsed = StdioFixture.await_reaped(owner)
      assert elapsed >= 200 and elapsed < 2_000
      refute StdioFixture.os_alive?(os_pid)
    end

    test "a server that ignores EOF and TERM is KILLed within ~4 s by default", %{tmp_dir: dir} do
      log = Path.join(dir, "signals.log")

      {state, os_pid} =
        open!(
          sh(~s(trap 'echo TERM >&2' TERM; while :; do sleep 1; done)) ++ [stderr: {:file, log}]
        )

      owner = state.port_owner
      :ok = Stdio.close(state, :done)
      elapsed = StdioFixture.await_reaped(owner)

      assert elapsed >= 4_000 and elapsed < 5_500
      refute StdioFixture.os_alive?(os_pid)
      assert File.read!(log) =~ "TERM"
    end

    test "the port owner reaps the server when its parent is killed" do
      parent = self()

      {:ok, opener} =
        Task.start(fn ->
          {:ok, state} = Stdio.init([command: "cat"], %{owner: self()})
          {:ok, state} = Stdio.connect(state)
          send(parent, {:opened, state.port_owner})
          Process.sleep(:infinity)
        end)

      assert_receive {:opened, owner}
      # `:sys.get_state/1` is served after the port is open.
      os_pid = StdioFixture.os_pid(owner)
      Process.exit(opener, :kill)

      StdioFixture.await_reaped(owner)
      refute StdioFixture.os_alive?(os_pid)
    end
  end

  test "lib/conduit_mcp/client never spawns through a shell (ST-1 source scan)" do
    offenders =
      for file <- Path.wildcard("lib/conduit_mcp/client/**/*.ex"),
          source = File.read!(file),
          pattern <- ["{:spawn,", ":os.cmd", "System.shell"],
          String.contains?(source, pattern),
          do: {file, pattern}

    assert offenders == []
  end
end
