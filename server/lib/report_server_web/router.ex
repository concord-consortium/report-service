defmodule ReportServerWeb.Router do
  use ReportServerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReportServerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ReportServerWeb.Auth.Plug
  end

  pipeline :codap_plugin do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReportServerWeb.Layouts, :codap_plugin}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :allow_iframe
  end

  pipeline :api do
    plug :force_json
  end

  pipeline :api_authenticated do
    plug :force_json
    plug ReportServerWeb.Api.AuthPlug
  end

  scope "/", ReportServerWeb do
    pipe_through :browser

    live "/", PageLive.Home, :home
    get "/config", PageController, :config

    get "/auth/login", AuthController, :login
    get "/auth/logout", AuthController, :logout
    live "/auth/callback", AuthLive.Callback, :callback
    get "/auth/save_token", AuthController, :save_token
    get "/auth/cli", AuthCliController, :cli
    get "/auth/cli/resume", AuthCliController, :resume
  end

  scope "/", ReportServerWeb do
    pipe_through :codap_plugin

    live_session :codap_plugin, layout: false, root_layout: {ReportServerWeb.Layouts, :codap_plugin} do
      live "/codap-plugin", CodapPluginLive.Index, :index
    end
  end

  scope "/api/v1", ReportServerWeb.Api.V1 do
    pipe_through :api_authenticated

    get "/reports", ReportController, :index
    get "/reports/:id", ReportController, :show
    get "/reports/:id/download", ReportController, :download
    get "/reports/:id/jobs", ReportJobController, :index
    get "/reports/:id/jobs/:job_id/download", ReportJobController, :download
  end

  # must stay below every real /api/v1 route: unknown API paths render the contract 404 rather
  # than raising NoRouteError, which Phoenix renders as HTML for clients that send no Accept header
  scope "/api/v1", ReportServerWeb.Api.V1 do
    pipe_through :api

    match :*, "/*path", FallbackController, :not_found
  end

  scope "/auth", ReportServerWeb do
    pipe_through :api

    post "/cli/token", AuthCliController, :token
  end

  # the legacy /old-reports export surface (the last unaudited student-data export) is retired;
  # redirect old bookmarks to /reports, matching the /new-reports backwards-compat pattern below
  scope "/old-reports", ReportServerWeb do
    pipe_through :browser

    get "/*path", RedirectToReports, []
  end

  # this directs all requests to /new-reports to /reports for backwards compatibility
  scope "/new-reports", ReportServerWeb do
    pipe_through :browser

    get "/*path", RedirectToReports, []
  end

  scope "/reports", ReportServerWeb do
    pipe_through :browser

    live_session :reports, on_mount: ReportServerWeb.ReportLive.Auth do
      live "/new/:slug", ReportLive.Form, :form
      live "/runs", ReportRunLive.Index, :my_runs
      live "/all-runs", ReportRunLive.Index, :all_runs
      live "/all-tokens", AllTokensLive.Index, :index
      live "/runs/:id", ReportRunLive.Show, :show
      live "/cli-token", ReportLive.CliToken, :cli_token
      live "/audit-log", AuditLogLive.Index, :index
      live "/*path", ReportLive.Index, :index
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:report_server, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ReportServerWeb.Telemetry
    end
  end

  # the API ignores Accept and always speaks JSON: `plug :accepts, ["json"]` would raise
  # Phoenix.NotAcceptableError on an explicit non-JSON Accept header before the auth plug or
  # catch-all could render the contract error shape
  defp force_json(conn, _opts), do: put_format(conn, "json")

  # add a CSP allowing embedding only from concord.org domains
  defp allow_iframe(conn, _opts) do
    conn
    |> delete_resp_header("x-frame-options")
    |> put_resp_header(
      "content-security-policy",
      "frame-ancestors 'self' https://*.concord.org;"
    )
  end
end
