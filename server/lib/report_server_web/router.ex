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

  scope "/reports", ReportServerWeb do
    pipe_through :browser

    live "/", ReportLive.Index, :index
    get "/demo.csv", DemoController, :csv
    get "/job.csv", DemoController, :job
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
end
