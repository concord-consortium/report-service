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
    plug :accepts, ["json"]
  end

  scope "/", ReportServerWeb do
    pipe_through :browser

    live "/", PageLive.Home, :home
    get "/config", PageController, :config

    get "/auth/login", AuthController, :login
    get "/auth/logout", AuthController, :logout
    live "/auth/callback", AuthLive.Callback, :callback
    get "/auth/save_token", AuthController, :save_token
  end

  scope "/", ReportServerWeb do
    pipe_through :codap_plugin

    live_session :codap_plugin, layout: false, root_layout: {ReportServerWeb.Layouts, :codap_plugin} do
      live "/codap-plugin", CodapPluginLive.Index, :index
    end
  end

  scope "/old-reports", ReportServerWeb do
    pipe_through :browser

    live "/", OldReportLive.Index, :index
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
      live "/runs/:id", ReportRunLive.Show, :show
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
