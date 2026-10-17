defmodule ConduitMcp.Client.Transport.Stdio do
  alias ConduitMcp.Client.Secret
  alias ConduitMcp.Client.Transport.Stdio.PortOwner

  @posix_env ~w(HOME LOGNAME PATH SHELL TERM USER)
  @windows_env ~w(APPDATA HOMEDRIVE HOMEPATH LOCALAPPDATA PATH PATHEXT PROCESSOR_ARCHITECTURE
                  SYSTEMDRIVE SYSTEMROOT TEMP USERNAME USERPROFILE PROGRAMFILES)

  # Characters cmd.exe interprets inside a batch file's arguments (ST-7).
  @batch_unsafe ["\"", "%", "^", "&", "|", "<", ">"]

  @schema NimbleOptions.new!(
            command: [
              type: {:custom, __MODULE__, :validate_command, []},
              required: true,
              doc: """
              The executable: a name looked up in `PATH` with
              `System.find_executable/1` when the client connects, or an
              absolute path. It must not contain whitespace - arguments go
              in `:args` - so `"npx -y server"` raises.
              """
            ],
            args: [
              type: {:list, :string},
              default: [],
              doc: """
              The arguments, passed to the executable as they are. No shell
              sees them, so `"; rm -rf ~"` arrives as one literal argument.
              """
            ],
            env: [
              type: {:custom, __MODULE__, :validate_env, []},
              default: [],
              doc: """
              Variables to set in the server's environment, as a map or a
              list of `{name, value}` string pairs. A value may be a
              `ConduitMcp.Client.Secret` (exposed only when the process is
              spawned). The server inherits **only** the allowlisted
              variables of this VM's environment (`HOME LOGNAME PATH SHELL
              TERM USER`; on Windows `APPDATA HOMEDRIVE HOMEPATH LOCALAPPDATA
              PATH PATHEXT PROCESSOR_ARCHITECTURE SYSTEMDRIVE SYSTEMROOT TEMP
              USERNAME USERPROFILE PROGRAMFILES`), minus any whose value
              starts with `()` (an exported shell function); every other
              inherited variable is removed. `:env` wins over inherited
              values.
              """
            ],
            cd: [
              type: {:custom, __MODULE__, :validate_cd, []},
              default: nil,
              doc: """
              The server's working directory: an absolute path to an
              existing directory. Defaults to this VM's working directory.
              """
            ],
            stderr: [
              type: {:custom, __MODULE__, :validate_stderr, []},
              default: :inherit,
              doc: """
              Where the server's stderr goes: `:inherit` (this VM's stderr),
              `:discard`, or `{:file, absolute_path}` (appended). `:discard`
              and `{:file, path}` are POSIX only: the server is started as
              `/bin/sh -c 'f=$1; shift; exec "$@" 2>>"$f"' conduit_mcp PATH
              EXECUTABLE ARGS...`, where the path, the executable and the
              arguments are positional parameters that the shell never
              parses, and `exec` keeps the server's pid. stderr is never
              merged into stdout, and never captured into `Logger`.
              """
            ],
            allow_batch_files: [
              type: :boolean,
              default: false,
              doc: """
              Allow a `.bat` or `.cmd` executable. They are refused by
              default because Windows runs them through `cmd.exe`, which
              re-parses their arguments (BatBadBut); when allowed, an
              argument containing any of `"%^&|<>` is still refused. On
              Windows, launchers such as `npx` resolve to `npx.cmd`.
              """
            ],
            max_message_bytes: [
              type: :pos_integer,
              default: 8 * 1024 * 1024,
              doc: """
              The largest message the server may write, in bytes. A longer
              line closes the transport with `:message_too_large` and stops
              the server.
              """
            ],
            max_junk_lines: [
              type: :non_neg_integer,
              default: 10,
              doc: """
              How many lines in a row that are not JSON-RPC messages are
              tolerated (each is logged at debug level and dropped). One more
              closes the transport with `:junk_output`, and the connection
              restarts the server.
              """
            ],
            stdin_grace: [
              type: :non_neg_integer,
              default: 2_000,
              doc: """
              Milliseconds the server gets to exit after its stdin is closed
              before it is sent `SIGTERM` (on Windows, killed).
              """
            ],
            term_grace: [
              type: :non_neg_integer,
              default: 2_000,
              doc: "Milliseconds the server gets after `SIGTERM` before `SIGKILL`."
            ]
          )

  @moduledoc """
  A `ConduitMcp.Client.Transport` that runs a local MCP server as an
  operating-system process and speaks newline-delimited JSON-RPC over its
  stdin and stdout (the MCP stdio transport).

      {ConduitMcp.Client,
       name: :files,
       transport:
         {ConduitMcp.Client.Transport.Stdio,
          command: "npx",
          args: ["-y", "@modelcontextprotocol/server-filesystem", "/srv/data"],
          env: %{"NODE_OPTIONS" => "--max-old-space-size=256"}}}

  `kind/0` is `:stdio`: protocol discovery follows the stdio rules (a
  timeout or a non-modern error means a legacy server) and `:probe_timeout`
  defaults to 3 s. Cancelling a request writes `notifications/cancelled` in
  both eras.

  Stdio configuration is **operator configuration**: whoever chooses
  `:command`, `:args` and `:env` runs code as this VM's user. Never build
  them from model output, server responses or end-user input.

  ## The process

  The server is started with `Port.open({:spawn_executable, path}, ...)`:
  the executable is run directly, never through a shell, so arguments are
  not expanded or split. Options are checked when the client starts
  (`ConduitMcp.Client.Config.new!/1` raises naming the key); the executable
  is resolved on every connection attempt.

  A port owner process, linked to the connection, owns the port. It writes
  without ever suspending (a server that stops reading stdin cannot stall
  it or the connection; at most 16 MiB of unwritten messages are held
  before the transport closes with `:write_queue_full`), splits stdout into
  lines with `ConduitMcp.Client.Transport.Stdio.Framer`, decodes them and
  passes the messages to the connection.

  When the server exits, the transport reports `{:closed, {:exit_status,
  status}}` and the connection reconnects, starting a new server (with its
  backoff and `:max_reconnects`). Requests in flight fail and are not
  retried.

  ## Shutdown

  When the transport closes (the client stops, reconnects or gives up, or
  the connection process dies, even by `:kill`) the port owner:

    1. closes the port, which closes the server's stdin;
    2. polls `kill -0 <os_pid>` until the server exits, for `:stdin_grace`;
    3. sends `kill -TERM`, and polls again for `:term_grace`;
    4. sends `kill -KILL`.

  On Windows step 3 is skipped and step 4 is `taskkill /PID <os_pid> /T /F`.
  The signals go through `System.cmd/3`; there is no shell. This runs in
  the port owner after it detaches from the connection, so neither a
  reconnect nor the client's shutdown waits for it.

  Limits:

    * Launchers such as `npx` and `uvx` start the real server as a child.
      Closing stdin normally ends both, but the signals reach only the
      launcher's pid, so a grandchild that ignores EOF can outlive it.
    * If the port owner itself is killed (`Process.exit(pid, :kill)`, or the
      VM halting, or an application stop killing the process while it is
      still escalating), only step 1 happens: a server that ignores EOF
      keeps running. Run such servers under a supervisor that kills on
      parent exit (a container, `systemd-run`, MuonTrap) if that matters.
    * The pid is signalled after the port is closed, so pid reuse in that
      window is possible in theory.

  ## Options

  #{NimbleOptions.docs(@schema)}
  """

  @behaviour ConduitMcp.Client.Transport

  @impl true
  def kind, do: :stdio

  @impl true
  def validate_options(opts) do
    with {:ok, opts} <- schema_validate(opts),
         :ok <- check_batch(opts[:command], opts) do
      {:ok, opts}
    end
  end

  defp schema_validate(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, opts} -> {:ok, opts}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  @impl true
  def init(opts, %{owner: owner}) do
    with {:ok, opts} <- validate_options(opts),
         {:ok, path} <- resolve(opts[:command]),
         :ok <- check_batch(path, opts) do
      {:ok,
       %{
         owner: owner,
         ref: make_ref(),
         port_owner: nil,
         path: path,
         opts: opts
       }}
    else
      {:error, message} when is_binary(message) -> {:error, {:invalid_options, message}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A name is looked up in PATH; an absolute path is used as it is.
  defp resolve(command) do
    if Path.type(command) == :absolute do
      if File.regular?(command), do: {:ok, command}, else: {:error, {:command_not_found, command}}
    else
      case System.find_executable(command) do
        nil -> {:error, {:command_not_found, command}}
        path -> {:ok, path}
      end
    end
  end

  defp check_batch(path, opts) do
    cond do
      not batch_file?(path) ->
        :ok

      not opts[:allow_batch_files] ->
        {:error,
         "invalid value for :command option: #{inspect(path)} is a batch file, which " <>
           "Windows runs through cmd.exe; set allow_batch_files: true to allow it"}

      Enum.any?(opts[:args], &batch_unsafe_arg?/1) ->
        {:error,
         "invalid value for :args option: a batch file's arguments must not contain " <>
           Enum.join(@batch_unsafe, " ")}

      true ->
        :ok
    end
  end

  @doc false
  # ST-7 path classification; pure, so it is tested on every OS.
  @spec batch_file?(String.t()) :: boolean()
  def batch_file?(path), do: String.downcase(Path.extname(path)) in [".bat", ".cmd"]

  @doc false
  @spec batch_unsafe_arg?(String.t()) :: boolean()
  def batch_unsafe_arg?(arg), do: String.contains?(arg, @batch_unsafe)

  @impl true
  def connect(state) do
    spec = %{
      owner: state.owner,
      ref: state.ref,
      tag: __MODULE__,
      spawn: spawn_spec(state.path, state.opts),
      user_env: state.opts[:env],
      max_message_bytes: state.opts[:max_message_bytes],
      max_junk_lines: state.opts[:max_junk_lines],
      stdin_grace: state.opts[:stdin_grace],
      term_grace: state.opts[:term_grace]
    }

    {:ok, pid} = PortOwner.start_link(spec)
    {:ok, %{state | port_owner: pid}}
  end

  # The executable, its arguments and the working directory; the
  # environment is built by the port owner when it spawns.
  defp spawn_spec(path, opts) do
    {executable, args} =
      case opts[:stderr] do
        :inherit -> {path, opts[:args]}
        :discard -> stderr_wrapper("/dev/null", path, opts[:args])
        {:file, file} -> stderr_wrapper(file, path, opts[:args])
      end

    %{executable: executable, args: args, cd: opts[:cd]}
  end

  # The file, the executable and its arguments are positional parameters:
  # the script is a constant and the shell never parses them.
  defp stderr_wrapper(file, path, args),
    do:
      {"/bin/sh", ["-c", ~s(f="$1"; shift; exec "$@" 2>>"$f"), "conduit_mcp", file, path | args]}

  @impl true
  def request(state, message, _reply_to, _wire_opts) do
    case write(state, message) do
      :ok -> {:ok, nil, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def notify(state, message) do
    case write(state, message) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def respond(state, message), do: notify(state, message)

  @impl true
  def cancel(state, id, _handle, reason) do
    _ =
      write(state, %{
        "jsonrpc" => "2.0",
        "method" => "notifications/cancelled",
        "params" => %{"requestId" => id, "reason" => Atom.to_string(reason)}
      })

    {:ok, state}
  end

  defp write(%{port_owner: nil}, _message), do: {:error, :not_connected}

  defp write(%{port_owner: pid}, message) do
    # `JSON.encode!/1` escapes every control character, so the line holds
    # no newline. Encoding here (not in the port owner) turns a value that
    # cannot be encoded into an error for this request alone.
    line = JSON.encode!(message)
    PortOwner.write(pid, line)
  rescue
    _error in [Protocol.UndefinedError, ArgumentError] -> {:error, :unencodable}
  end

  @impl true
  def handle_info({__MODULE__, ref, events}, %{ref: ref} = state) do
    state = if Enum.any?(events, &match?({:closed, _}, &1)), do: detach(state), else: state
    {:ok, events, state}
  end

  def handle_info({:EXIT, pid, reason}, %{port_owner: pid} = state),
    do: {:ok, [{:closed, {:port_owner_exit, reason}}], %{state | port_owner: nil}}

  def handle_info(_message, _state), do: :unknown

  # The port owner reported `{:closed, _}`: it has unlinked itself and is
  # stopping the server on its own.
  defp detach(%{port_owner: nil} = state), do: state

  defp detach(%{port_owner: pid} = state) do
    Process.unlink(pid)
    %{state | port_owner: nil}
  end

  @impl true
  def close(%{port_owner: nil}, _reason), do: :ok

  def close(%{port_owner: pid}, _reason) do
    Process.unlink(pid)
    PortOwner.close(pid)
  end

  # --- option validators (NimbleOptions `{:custom, ...}`) ----------------------

  @doc false
  @spec validate_command(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_command(command) when is_binary(command) do
    cond do
      command == "" or String.contains?(command, <<0>>) ->
        {:error,
         "expected a non-empty executable name or absolute path, got: #{inspect(command)}"}

      String.match?(command, ~r/\s/u) ->
        {:error,
         "expected an executable without whitespace, got: #{inspect(command)}; " <>
           "pass arguments in :args (no shell runs the command)"}

      Path.type(command) != :absolute and String.contains?(command, ["/", "\\"]) ->
        {:error,
         "expected an executable name looked up in PATH or an absolute path, " <>
           "got the relative path #{inspect(command)}"}

      true ->
        {:ok, command}
    end
  end

  def validate_command(other),
    do: {:error, "expected a string, got: #{inspect(other)}"}

  @doc false
  # Names may appear in messages; values never do (they may be secrets).
  @spec validate_env(term()) ::
          {:ok, [{String.t(), String.t() | Secret.t()}]} | {:error, String.t()}
  def validate_env(env) when is_map(env), do: validate_env(Map.to_list(env))

  def validate_env(env) when is_list(env) do
    Enum.reduce_while(env, {:ok, []}, fn
      {name, value}, {:ok, acc} when is_binary(name) ->
        cond do
          not valid_env_name?(name) ->
            {:halt,
             {:error,
              "invalid variable name #{inspect(name)}: must be non-empty without = or NUL"}}

          not valid_env_value?(value) ->
            {:halt,
             {:error,
              "the value of #{inspect(name)} must be a string (or a " <>
                "ConduitMcp.Client.Secret wrapping one) without NUL bytes"}}

          true ->
            {:cont, {:ok, [{name, value} | acc]}}
        end

      _entry, _acc ->
        {:halt, {:error, "expected a map or a list of {name, value} string pairs"}}
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  def validate_env(_other), do: {:error, "expected a map or a list of {name, value} string pairs"}

  defp valid_env_name?(name), do: name != "" and not String.contains?(name, ["=", <<0>>])

  defp valid_env_value?(value) when is_binary(value), do: not String.contains?(value, <<0>>)

  # A Secret never wraps another Secret (`Secret.new/1`), so this recurses once.
  defp valid_env_value?(value),
    do: Secret.secret?(value) and valid_env_value?(Secret.expose(value))

  @doc false
  @spec validate_cd(term()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def validate_cd(nil), do: {:ok, nil}

  def validate_cd(dir) when is_binary(dir) do
    cond do
      Path.type(dir) != :absolute -> {:error, "expected an absolute path, got: #{inspect(dir)}"}
      not File.dir?(dir) -> {:error, "expected an existing directory, got: #{inspect(dir)}"}
      true -> {:ok, dir}
    end
  end

  def validate_cd(other),
    do: {:error, "expected an absolute directory path, got: #{inspect(other)}"}

  @doc false
  @spec validate_stderr(term()) :: {:ok, term()} | {:error, String.t()}
  def validate_stderr(:inherit), do: {:ok, :inherit}

  def validate_stderr(:discard), do: posix_only(:discard)

  def validate_stderr({:file, path} = mode) when is_binary(path) do
    if Path.type(path) == :absolute,
      do: posix_only(mode),
      else: {:error, "expected an absolute path in {:file, path}, got: #{inspect(path)}"}
  end

  def validate_stderr(other),
    do: {:error, "expected :inherit, :discard or {:file, absolute_path}, got: #{inspect(other)}"}

  defp posix_only(mode) do
    if windows?(),
      do: {:error, "#{inspect(mode)} is not supported on Windows; use :inherit"},
      else: {:ok, mode}
  end

  # --- environment (ST-2) ------------------------------------------------------

  @doc false
  # The `{:env, ...}` list for `Port.open/2`. Erlang's `:env` *extends* the
  # VM's environment, so every inherited variable outside the allowlist (or
  # holding an exported shell function) is removed with `false`; the
  # user's variables are set on top.
  @spec child_env(
          %{String.t() => String.t()},
          [{String.t(), String.t() | Secret.t()}],
          :unix | :win32
        ) ::
          [{charlist(), charlist() | false}]
  def child_env(inherited, user_env, os_family) do
    allowlist = allowlist(os_family)
    key = env_key(os_family)

    inherited =
      Map.new(inherited, fn {name, value} ->
        keep? = key.(name) in allowlist and not String.starts_with?(value, "()")
        {key.(name), {name, if(keep?, do: value, else: false)}}
      end)

    user_env
    |> Enum.reduce(inherited, fn {name, value}, acc ->
      Map.put(acc, key.(name), {name, expose(value)})
    end)
    |> Enum.map(fn {_key, {name, value}} -> {String.to_charlist(name), charlist(value)} end)
  end

  defp allowlist(:win32), do: @windows_env
  defp allowlist(_unix), do: @posix_env

  # Windows variable names are case-insensitive.
  defp env_key(:win32), do: &String.upcase/1
  defp env_key(_unix), do: & &1

  defp expose(value) when is_binary(value), do: value
  defp expose(secret), do: Secret.expose(secret)

  defp charlist(false), do: false
  defp charlist(value), do: String.to_charlist(value)

  @doc false
  @spec windows?() :: boolean()
  def windows?, do: match?({:win32, _}, :os.type())
end
