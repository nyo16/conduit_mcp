defmodule ConduitMcp.Client.Transport.Stdio.PortOwner do
  @moduledoc false

  # The process that owns a stdio server's port, started (and linked) by
  # `ConduitMcp.Client.Transport.Stdio.connect/1` in the connection process.
  #
  # * Writes never suspend: `Port.command/3` with `:nosuspend`, and lines the
  #   busy port refused wait in a bounded queue retried on a timer. A server
  #   that stops reading stdin can neither stall this process (it keeps
  #   reading stdout, so the two pipes cannot deadlock) nor the connection.
  # * stdout is framed with `ConduitMcp.Client.Transport.Stdio.Framer`,
  #   decoded and classified here; the connection receives
  #   `{tag, ref, [event]}` messages carrying `ConduitMcp.Client.Transport`
  #   events.
  # * On a fatal condition (exit status, oversized line, junk budget, write
  #   queue overflow) it sends `{:closed, reason}`, unlinks from the
  #   connection and stops. `terminate/2` always stops the server: close the
  #   port (EOF), poll `kill -0`, TERM, KILL (ST-3). It traps exits, so the
  #   connection dying - even by `:kill` - also runs `terminate/2`.
  #
  # The spawn environment can hold exposed secrets: it is built, used and
  # dropped inside `handle_continue/2`, and `format_status/1` redacts the
  # user variables kept in the state.

  use GenServer

  require Logger

  alias ConduitMcp.Client.Transport.Stdio
  alias ConduitMcp.Client.Transport.Stdio.Framer
  alias ConduitMcp.Reflect

  # Unwritten bytes held while the server does not read its stdin.
  @max_pending_write_bytes 16 * 1024 * 1024
  @flush_interval 10
  @poll_interval 50
  @kill_wait 1_000

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(spec), do: GenServer.start_link(__MODULE__, spec)

  @doc "Queues one encoded message (no trailing newline) for the server's stdin."
  @spec write(pid(), binary()) :: :ok
  def write(pid, line) do
    send(pid, {:write, line})
    :ok
  end

  @doc "Stops the server and this process, without reporting back."
  @spec close(pid()) :: :ok
  def close(pid) do
    send(pid, :close)
    :ok
  end

  # --- GenServer ---------------------------------------------------------------

  @impl true
  def init(spec) do
    Process.flag(:trap_exit, true)

    state = %{
      owner: spec.owner,
      ref: spec.ref,
      tag: spec.tag,
      spawn: spec.spawn,
      user_env: spec.user_env,
      port: nil,
      os_pid: nil,
      framer: Framer.new(max_message_bytes: spec.max_message_bytes),
      max_junk_lines: spec.max_junk_lines,
      junk: 0,
      stdin_grace: spec.stdin_grace,
      term_grace: spec.term_grace,
      outq: :queue.new(),
      outq_bytes: 0,
      flush_timer: nil
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, %{spawn: spawn} = state) do
    env = Stdio.child_env(System.get_env(), state.user_env, os_family())

    options =
      [:binary, :exit_status, :use_stdio, :hide, args: spawn.args, env: env] ++
        if(spawn.cd, do: [cd: spawn.cd], else: [])

    port = Port.open({:spawn_executable, spawn.executable}, options)
    # `nil` when the server already exited; its exit status follows.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    emit(state, [{:connected, %{os_pid: os_pid}}])
    {:noreply, %{state | port: port, os_pid: os_pid, user_env: []}}
  rescue
    error in ErlangError -> fail(state, {:spawn_failed, error.original})
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    case Framer.feed(state.framer, chunk) do
      {:ok, lines, framer} ->
        deliver(lines, %{state | framer: framer})

      {:error, :message_too_large, lines, framer} ->
        Logger.warning(
          "MCP stdio server wrote a message larger than #{state.framer.max_message_bytes} bytes; " <>
            "stopping it"
        )

        case deliver(lines, %{state | framer: framer}) do
          {:noreply, state} -> fail(state, :message_too_large)
          stop -> stop
        end
    end
  end

  # The server exited: nothing left to signal.
  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: fail(%{state | port: nil, os_pid: nil}, {:exit_status, status})

  # The port's link: `:normal` follows the exit status above; anything else
  # (for example `:epipe`) closed the port while the server may still run.
  def handle_info({:EXIT, port, :normal}, %{port: port} = state), do: {:noreply, state}

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: fail(%{state | port: nil}, {:port_exit, reason})

  def handle_info({:write, line}, state), do: enqueue(line, state)

  def handle_info(:flush, state), do: flush(%{state | flush_timer: nil})

  def handle_info(:close, state), do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    if state.os_pid, do: stop_os_process(state.os_pid, state)
    :ok
  end

  @impl true
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{} = state -> %{state | user_env: :redacted, spawn: :redacted, outq: :redacted}
      other -> other
    end)
  end

  # --- stdout --------------------------------------------------------------------

  defp deliver(lines, state) do
    case decode(lines, state, []) do
      {:ok, events, state} ->
        emit(state, events)
        {:noreply, state}

      {:junk, events, state} ->
        emit(state, events)

        Logger.warning(
          "MCP stdio server wrote more than #{state.max_junk_lines} lines in a row that are " <>
            "not JSON-RPC messages; restarting it"
        )

        fail(state, :junk_output)
    end
  end

  defp decode([], state, acc), do: {:ok, Enum.reverse(acc), state}

  defp decode([line | rest], state, acc) do
    case classify(line) do
      {:ok, event} ->
        decode(rest, %{state | junk: 0}, [event | acc])

      :junk ->
        Logger.debug("MCP stdio server wrote a line that is not a JSON-RPC message",
          line: Reflect.text(line, 64)
        )

        state = %{state | junk: state.junk + 1}

        if state.junk > state.max_junk_lines,
          do: {:junk, Enum.reverse(acc), state},
          else: decode(rest, state, acc)
    end
  end

  defp classify(line) do
    case JSON.decode(line) do
      {:ok, %{"method" => method, "id" => id} = message} when is_binary(method) ->
        {:ok, {:server_request, id, message, nil}}

      {:ok, %{"method" => method} = message} when is_binary(method) ->
        {:ok, {:notification, method, Map.get(message, "params", %{})}}

      {:ok, %{"id" => id} = message}
      when is_map_key(message, "result") or is_map_key(message, "error") ->
        {:ok, {:response, id, message}}

      _other ->
        :junk
    end
  end

  # --- stdin ---------------------------------------------------------------------

  defp enqueue(line, state) do
    size = byte_size(line) + 1

    # One message larger than the bound is accepted into an empty queue.
    if state.outq_bytes > 0 and state.outq_bytes + size > @max_pending_write_bytes do
      Logger.warning("MCP stdio server is not reading its stdin; restarting it")
      fail(state, :write_queue_full)
    else
      flush(%{state | outq: :queue.in(line, state.outq), outq_bytes: state.outq_bytes + size})
    end
  end

  defp flush(%{port: nil} = state), do: {:noreply, state}

  defp flush(state) do
    case :queue.out(state.outq) do
      {:empty, _queue} ->
        {:noreply, state}

      {{:value, line}, rest} ->
        case command(state.port, line) do
          :sent ->
            flush(%{state | outq: rest, outq_bytes: state.outq_bytes - byte_size(line) - 1})

          :busy ->
            {:noreply, schedule_flush(state)}

          # The port is closing; its exit message follows.
          :closed ->
            {:noreply, state}
        end
    end
  end

  defp command(port, line) do
    if Port.command(port, [line, ?\n], [:nosuspend]), do: :sent, else: :busy
  rescue
    ArgumentError -> :closed
  end

  defp schedule_flush(%{flush_timer: nil} = state),
    do: %{state | flush_timer: Process.send_after(self(), :flush, @flush_interval)}

  defp schedule_flush(state), do: state

  # --- closing -------------------------------------------------------------------

  defp emit(_state, []), do: :ok
  defp emit(state, events), do: send(state.owner, {state.tag, state.ref, events})

  # Report, detach from the connection (which no longer waits for this
  # process), then stop the server in `terminate/2`.
  defp fail(state, reason) do
    emit(state, [{:closed, reason}])
    Process.unlink(state.owner)
    {:stop, :normal, state}
  end

  defp close_port(nil), do: :ok

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp stop_os_process(os_pid, state) do
    _ = exited?(os_pid, state.stdin_grace) or escalate(os_family(), os_pid, state)
    :ok
  end

  defp escalate(:unix, os_pid, state) do
    signal(os_pid, :term)
    exited?(os_pid, state.term_grace) or kill(os_pid)
  end

  # Windows has no TERM for a console process: straight to taskkill.
  defp escalate(:win32, os_pid, _state), do: kill(os_pid)

  defp kill(os_pid) do
    signal(os_pid, :kill)
    exited?(os_pid, @kill_wait)
  end

  # Polls until `os_pid` is gone or `timeout` ms pass.
  defp exited?(os_pid, timeout),
    do: poll_exit(os_pid, System.monotonic_time(:millisecond) + timeout)

  defp poll_exit(os_pid, deadline) do
    cond do
      not alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          @poll_interval -> poll_exit(os_pid, deadline)
        end
    end
  end

  defp alive?(os_pid) do
    case os_family() do
      :unix ->
        match?({_, 0}, run("kill", ["-0", Integer.to_string(os_pid)]))

      :win32 ->
        case run("tasklist", ["/FI", "PID eq #{os_pid}", "/NH", "/FO", "CSV"]) do
          {output, 0} -> String.contains?(output, ~s("#{os_pid}"))
          _ -> false
        end
    end
  end

  defp signal(os_pid, :term), do: run("kill", ["-TERM", Integer.to_string(os_pid)])
  defp signal(os_pid, :kill), do: signal_kill(os_family(), os_pid)

  defp signal_kill(:unix, os_pid), do: run("kill", ["-KILL", Integer.to_string(os_pid)])

  defp signal_kill(:win32, os_pid),
    do: run("taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"])

  # No shell: the executable is resolved and run with an argument list. A
  # missing one means the process cannot be checked or signalled.
  defp run(command, args) do
    case System.find_executable(command) do
      nil ->
        Logger.warning("MCP stdio transport cannot find #{command} to stop a server process")
        :unavailable

      path ->
        System.cmd(path, args, stderr_to_stdout: true)
    end
  end

  defp os_family, do: elem(:os.type(), 0)
end
