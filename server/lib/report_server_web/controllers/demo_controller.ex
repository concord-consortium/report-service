defmodule ReportServerWeb.DemoController do
  use ReportServerWeb, :controller

  alias ReportServer.Demo

  def csv(conn, _params) do
    send_download(conn, {:binary, Demo.raw_demo_csv()}, filename: "demo.csv", content_type: "application/csv", disposition: :attachment)
  end

  def job(conn, %{"filename" => filename, "result" => result}) do
    result = Base.decode64!(result)
    send_download(conn, {:binary, result}, filename: filename, content_type: "application/csv", disposition: :attachment)
  end
end
