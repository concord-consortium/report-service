defmodule ReportServerWeb.Api.V1.AttachmentJSON do
  def results(results, expires_in_seconds) do
    %{results: results, expires_in_seconds: expires_in_seconds}
  end
end
