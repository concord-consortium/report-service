defmodule ReportServer.ClueExport do
  @moduledoc """
  Client for CLUE's `clueExport` function, one deployment per CLUE project, chosen by the caller's portal.
  The function is stateless and authorization-blind: report-server decides the scope and owns the cursor.
  """

  # past the function's 300-second timeout, as bulk_read's client is
  @receive_timeout 310_000

  @doc "The function URL for a portal, or nil when CLUE export is not configured for it."
  def url_for(portal_server), do: Map.get(config()[:urls] || %{}, portal_server)

  @doc "{:ok, body_without_success} | {:error, reason}. Anything but a 200 with `success: true` is an error."
  def call(portal_server, req) do
    case url_for(portal_server) do
      nil ->
        {:error, :not_configured}

      url ->
        Req.new(Application.get_env(:report_server, :clue_export_req_options, []))
        |> Req.post(url: url, auth: {:bearer, config()[:token]}, json: req,
             receive_timeout: @receive_timeout, retry: false)
        |> case do
          {:ok, %{status: 200, body: %{"success" => true} = body}} -> {:ok, Map.delete(body, "success")}
          {:ok, %{body: %{"error" => error}}} -> {:error, error}
          {:ok, %{status: status}} -> {:error, "clueExport answered status #{status} without success"}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp config, do: Application.get_env(:report_server, :clue_export, [])
end
