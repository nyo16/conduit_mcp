import Config

# Verbose logger so a failed JSON-RPC call shows the actual exception
# instead of just "Error handling method". Useful when developing the
# example; downstream apps should override.
config :logger, :default_formatter,
  format: "$time [$level] $message $metadata\n",
  metadata: [:error, :method, :request_id, :crash_reason]

# Ecto repos managed by this app
config :oban_tasks_server, ecto_repos: [Examples.ObanTasks.Repo]

# SQLite database — defaults to a file in System.tmp_dir!/ so the example
# works without polluting the working tree. Override via OBAN_SQLITE_PATH.
config :oban_tasks_server, Examples.ObanTasks.Repo,
  database:
    System.get_env("OBAN_SQLITE_PATH") ||
      Path.join(System.tmp_dir!(), "conduit_oban_tasks.sqlite3"),
  journal_mode: :wal,
  pool_size: 5

# Oban configuration. Oban.Engines.Lite is the SQLite-friendly engine —
# single-node, low-concurrency, fine for examples and small workloads.
# Production users on Postgres should swap engine to the default and
# adjust the queue concurrency.
config :oban_tasks_server, Oban,
  repo: Examples.ObanTasks.Repo,
  engine: Oban.Engines.Lite,
  queues: [mcp_tasks: 4],
  plugins: [{Oban.Plugins.Pruner, max_age: 3600}]

# Wire ConduitMCP to use the Oban-backed task store. This is the key
# line that flips the library from the default in-memory ETS backend to
# the durable SQLite-backed one. The standard tasks/get, tasks/cancel,
# tasks/result, and tasks/list JSON-RPC routes pick this up
# transparently — no handler changes needed.
config :conduit_mcp, :tasks_store, Examples.ObanTasks.Store
