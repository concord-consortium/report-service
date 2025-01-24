defmodule ReportServerWeb.RedirectToReports do
  @moduledoc """
  Redirects all requests to /reports using the path from the request.
  """

  def init(opts), do: opts

  def call(conn, _opts) do
    to = ["/reports" | conn.params["path"]] |> Enum.join("/")
    conn
    |> Phoenix.Controller.redirect(to: to)
  end
end
