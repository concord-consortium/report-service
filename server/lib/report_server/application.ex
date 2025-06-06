defmodule ReportServer.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # load the reports into an ets table
    ReportServer.Reports.Tree.init()

    children = [
      ReportServerWeb.Telemetry,
      ReportServer.Repo,
      {DNSCluster, query: Application.get_env(:report_server, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ReportServer.PubSub},
      {Registry, keys: :unique, name: ReportServer.PostProcessingRegistry},
      {Task.Supervisor, name: ReportServer.PostProcessingTaskSupervisor},
      ReportServer.PostProcessing.JobSupervisor,
      {ReportServer.Dashboard.StatsServer, get_dashboard_servers()},
      # Start a worker by calling: ReportServer.Worker.start_link(arg)
      # {ReportServer.Worker, arg},
      # Start to serve requests, typically the last entry
      ReportServerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ReportServer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ReportServerWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp get_dashboard_servers() do
    case Application.get_env(:report_server, :portal) |> Keyword.get(:url)  do
      "https://learn.concord.org" -> ["learn.concord.org", "ngss-assessment.portal.concord.org"]
      _ -> ["learn.portal.staging.concord.org"]
    end
  end
end
