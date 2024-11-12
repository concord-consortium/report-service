import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :report_server, ReportServer.Repo,
  username: "root",
  password: "xyzzy",
  hostname: "localhost",
  port: 3406,
  database: "portal_server_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :report_server, ReportServerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "dVgyX6OXy2LsFToLpy02eK9PKFcWe4MEGc8KHU1N+P9t9sr/fkV/hIQ3Owrrs44L",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

config :report_server, :portal,
  client_id: "research-report-server",
  url: "https://learn.portal.staging.concord.org"
