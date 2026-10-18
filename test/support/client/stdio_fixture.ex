defmodule ConduitMcp.Test.Client.StdioFixture do
  @moduledoc """
  Launch options and process probes for the stdio transport tests.

  `server/2` starts `test/support/fixtures/stdio_server.exs` with the Elixir
  that runs the tests (its `bin/elixir`, with this VM's `erl` first in
  `PATH`), `-pa` for every `_build/test/lib/*/ebin` so the fixture loads
  this library, its dependencies and the compiled test support modules.
  """

  alias ConduitMcp.Client.Registry
  alias ConduitMcp.Client.Transport.Stdio

  @script Path.expand("../fixtures/stdio_server.exs", __DIR__)

  @doc "`{Stdio, opts}` running the Elixir fixture in `mode` (see the script)."
  @spec server(String.t(), keyword()) :: {module(), keyword()}
  def server(mode \\ "normal", opts \\ []) do
    {server_args, opts} =
      case Keyword.pop(opts, :server) do
        {nil, opts} -> {[], opts}
        {module, opts} -> {["--server", inspect(module)], opts}
      end

    {extra_env, opts} = Keyword.pop(opts, :env, %{})

    {Stdio,
     [
       command: elixir(),
       args: Enum.flat_map(ebin_dirs(), &["-pa", &1]) ++ [@script, mode | server_args],
       env: Map.merge(base_env(), Map.new(extra_env))
     ] ++ opts}
  end

  # The fixture must run on the same Elixir and OTP as the compiled beams.
  defp elixir do
    path = Path.expand("../../bin/elixir", to_string(:code.lib_dir(:elixir)))
    if File.regular?(path), do: path, else: System.find_executable("elixir")
  end

  defp ebin_dirs, do: Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

  # `bin/elixir` runs the first `erl` in PATH; the locale keeps the VM on a
  # UTF-8 filename encoding.
  defp base_env do
    erts_bin = Path.join(to_string(:code.root_dir()), "bin")
    locale = Map.take(System.get_env(), ["LANG", "LC_ALL", "LC_CTYPE"])
    Map.put(locale, "PATH", erts_bin <> ":" <> System.get_env("PATH", ""))
  end

  @doc "The port owner of client `name`'s current connection attempt."
  @spec port_owner(term()) :: pid()
  def port_owner(name) do
    {:ok, conn, _view} = Registry.lookup({:client, name})
    {_state, data} = :sys.get_state(conn)
    %{port_owner: pid} = data.tstate
    pid
  end

  @doc "The OS pid of the server process behind a port owner."
  @spec os_pid(pid()) :: pos_integer()
  def os_pid(port_owner) do
    %{os_pid: os_pid} = :sys.get_state(port_owner)
    os_pid
  end

  @doc "Whether an OS process exists (`kill -0`)."
  @spec os_alive?(pos_integer()) :: boolean()
  def os_alive?(os_pid),
    do: match?({_, 0}, System.cmd("kill", ["-0", to_string(os_pid)], stderr_to_stdout: true))

  @doc """
  Waits for `port_owner` to stop - it stops only after the server process
  is gone or was killed - and returns how long that took, in ms.

  Options: `:since`, a `System.monotonic_time(:millisecond)` reading to
  measure from (take it before the call that starts the shutdown, so the
  time that call itself blocks is counted); `:timeout` (default 6 000 ms).
  """
  @spec await_reaped(pid(), keyword()) :: non_neg_integer()
  def await_reaped(port_owner, opts \\ []) do
    started = Keyword.get_lazy(opts, :since, fn -> System.monotonic_time(:millisecond) end)
    timeout = Keyword.get(opts, :timeout, 6_000)
    ref = Process.monitor(port_owner)

    receive do
      {:DOWN, ^ref, :process, ^port_owner, _reason} ->
        System.monotonic_time(:millisecond) - started
    after
      timeout -> raise ExUnit.AssertionError, "port owner still running after #{timeout} ms"
    end
  end
end
