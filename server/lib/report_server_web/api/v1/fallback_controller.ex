defmodule ReportServerWeb.Api.V1.FallbackController do
  use ReportServerWeb, :controller

  alias ReportServerWeb.Api.ErrorHelpers

  def not_found(conn, _params), do: ErrorHelpers.not_found(conn)
end
