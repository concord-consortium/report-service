import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/report_server start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :report_server, ReportServerWeb.Endpoint, server: true
end

server_access_key_id =
  System.get_env("SERVER_ACCESS_KEY_ID") ||
    raise """
    the required SERVER_ACCESS_KEY_ID environment variable is missing.
    """
server_secret_access_key =
  System.get_env("SERVER_SECRET_ACCESS_KEY") ||
    raise """
    the required SERVER_SECRET_ACCESS_KEY environment variable is missing.
    """

report_service_token =
  System.get_env("REPORT_SERVICE_TOKEN") ||
    raise """
    the required REPORT_SERVICE_TOKEN environment variable is missing.
    """

hide_username_hash_salt =
  System.get_env("HIDE_USERNAME_HASH_SALT") ||
    raise """
    the required HIDE_USERNAME_HASH_SALT environment variable is missing.
    """

config :report_server, :aws_credentials,
  access_key_id: server_access_key_id,
  secret_access_key: server_secret_access_key

config :report_server, :report_service,
  url: System.get_env("REPORT_SERVICE_URL") || "https://us-central1-report-service-pro.cloudfunctions.net/api", # production
  token: report_service_token,
  firebase_app: System.get_env("REPORT_SERVICE_FIREBASE_APP") || "report-service-pro" # production

config :report_server, :portal_report,
  url: System.get_env("PORTAL_REPORT_URL") || "https://portal-report.concord.org/branch/master/" # production (yes, prod uses master)

config :report_server, :stats_server,
  disable: System.get_env("DISABLE_STATS_SERVER") == "true" || false

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :report_server, ReportServer.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "report-server.concord.org"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :report_server, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :report_server, ReportServerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  config :report_server, :portal,
    client_id: "research-report-server",
    url: System.get_env("PORTAL_URL") || "https://learn.concord.org"

  config :report_server, :token_service,
    url: System.get_env("TOKEN_SERVICE_URL") || "https://token-service-62822.firebaseapp.com/api/v1/resources", # production
    private_bucket: System.get_env("TOKEN_SERVICE_PRIVATE_BUCKET") || "token-service-files-private" # production

  config :report_server, :output,
    bucket: System.get_env("OUTPUT_BUCKET") || "report-server-output",
    jobs_folder: System.get_env("JOBS_FOLDER") || "jobs",
    transcripts_folder: System.get_env("TRANSCRIPTS_FOLDER") || "transcripts"

  config :report_server, :athena,
    bucket: System.get_env("ATHENA_REPORT_BUCKET") || "concord-report-data", # production
    log_db_name: System.get_env("ATHENA_LOG_DB_NAME") || "log_ingester_production", # production
    source_key: System.get_env("ATHENA_SOURCE_KEY") || "authoring.concord.org", # production
    hide_username_hash_salt: hide_username_hash_salt

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :report_server, ReportServerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :report_server, ReportServerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
