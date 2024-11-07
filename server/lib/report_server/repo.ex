defmodule ReportServer.Repo do
  use Ecto.Repo,
    otp_app: :report_server,
    adapter: Ecto.Adapters.MyXQL
end
