defmodule ConduitMcp.Client.Governance.Exec do
  @moduledoc false
  # Runs one piece of host code (a hook, an `on_ask` approver) for the
  # calling process: in a `Task.Supervisor.async_nolink/2` task on the
  # client's task supervisor, under a deadline (X-7, HK-1).
  #
  # The callee's exceptions, throws and exits are caught inside the task and
  # reduced to a closed atom, so nothing it raised (which may quote tool
  # arguments or results) reaches a crash report, the caller or telemetry.
  # A task that dies anyway (`Process.exit(self(), :kill)`) is `:exit`; one
  # that misses the deadline is killed and is `:timeout`.
  #
  # `async_nolink` tasks outlive their caller, so each task starts a small
  # unsupervised guard that monitors both and kills the task if the caller
  # dies first; the guard exits as soon as either is gone.

  @type failure :: :raise | :exit | :timeout

  @doc "Calls `fun` with `args` in a supervised task, waiting at most `timeout` ms."
  @spec run(pid(), function() | {module(), atom()}, [term()], timeout()) ::
          {:ok, term()} | {:failed, failure()}
  def run(task_sup, fun, args, timeout) do
    caller = self()

    task =
      Task.Supervisor.async_nolink(task_sup, fn ->
        guard(caller)
        call(fun, args)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:returned, value}} -> {:ok, value}
      {:ok, {:caught, kind}} -> {:failed, kind}
      {:exit, _reason} -> {:failed, :exit}
      nil -> {:failed, :timeout}
    end
  catch
    # The task supervisor is gone (the client is stopping).
    :exit, _reason -> {:failed, :exit}
  end

  defp call(fun, args) do
    value =
      case fun do
        {module, name} -> apply(module, name, args)
        fun -> apply(fun, args)
      end

    {:returned, value}
  catch
    :exit, _reason -> {:caught, :exit}
    _kind, _reason -> {:caught, :raise}
  end

  defp guard(caller) do
    task = self()

    spawn(fn ->
      caller_ref = Process.monitor(caller)
      task_ref = Process.monitor(task)

      receive do
        {:DOWN, ^caller_ref, :process, _pid, _reason} -> Process.exit(task, :kill)
        {:DOWN, ^task_ref, :process, _pid, _reason} -> :ok
      end
    end)
  end
end
