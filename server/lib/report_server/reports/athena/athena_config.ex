defmodule ReportServer.Reports.Athena.AthenaConfig do

  def get_output_bucket() do
    Application.get_env(:report_server, :athena)
      |> Keyword.get(:bucket, "concord-report-data")
  end

  def get_hide_username_hash_salt() do
    Application.get_env(:report_server, :athena)
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
