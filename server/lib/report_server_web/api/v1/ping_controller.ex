defmodule ReportServerWeb.Api.V1.PingController do
  use ReportServerWeb, :controller

  def ping(conn, _params), do: json(conn, %{ok: true})
end
