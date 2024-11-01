defmodule ReportServerWeb.NewReportsLive.Form do
  @doc """
  Render the form for a new report.
  May eventually get a different @live_action to show the result of the report.
  """

  use ReportServerWeb, :live_view
  alias ReportServerWeb.Auth

  @known_reports ["one", "two"]

  @impl true
  def mount(params, session, socket) do
    report = Map.get(params, "report", "No report provided")

    socket = socket
      |> assign(:page_title, "Report Form")
      |> assign(Auth.public_session_vars(session))
      |> assign(:report, report)

    if socket.assigns.live_action == :form do
      if report in @known_reports do
        {:ok, socket}
      else
        {:error, "Report not found"}
      end
    else
      {:error, "Invalid live action"}
    end
  end

end
