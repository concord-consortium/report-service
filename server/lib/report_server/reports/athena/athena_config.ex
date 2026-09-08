defmodule ReportServer.Reports.Athena.AthenaConfig do

  # Projected values of the `app` partition on logs_by_app_and_secure_key; must match
  # 'projection.app.values' in the DDL in server/README.md. Adding one means recreating the tables.
  @log_apps ~w(Activity_Player CEASAR CLUE CODAP CollabSpace Dataflow DEVOPS GeniStarDev GRASP
               HASBot-Dashboard IS LARA-log-poc none portal-report rigse-log)

  # 'projection.year.range' and 'projection.month.range' from the same DDL. Together they set the
  # number of (year, month) partition prefixes an unbounded query admits.
  @log_projection_years 2014..2050
  @log_projection_months 1..12

  def get_log_apps() do
    Application.get_env(:report_server, :athena, [])
      |> Keyword.get(:log_apps, @log_apps)
  end

  def get_log_projection_years(), do: @log_projection_years

  def get_log_projection_months(), do: @log_projection_months

  # {label, value} pairs for Phoenix.HTML.Form.options_for_select/2. The wording lives here so the
  # form and every API client render the vocabulary from one definition.
  def app_options() do
    Enum.map(get_log_apps(), fn
      "none" -> {"none (no application recorded)", "none"}
      app -> {app, app}
    end)
  end

  def get_output_bucket() do
    Application.get_env(:report_server, :athena)
      |> Keyword.get(:bucket, "concord-report-data")
  end

  def get_hide_username_hash_salt() do
    Application.get_env(:report_server, :athena, [])
      |> Keyword.get(:hide_username_hash_salt, get_random_salt())
  end

  def get_source_key() do
    Application.get_env(:report_server, :athena)
      |> Keyword.get(:source_key, "authoring.concord.org")
  end

  defp get_random_salt() do
    :crypto.strong_rand_bytes(64)
    |> Base.encode64()
  end

end
