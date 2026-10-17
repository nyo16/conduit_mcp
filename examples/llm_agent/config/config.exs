import Config

config :logger, level: :info
config :logger, :default_formatter, format: "$time [$level] $message\n"
