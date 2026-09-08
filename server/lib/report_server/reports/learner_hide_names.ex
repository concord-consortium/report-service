defmodule ReportServer.Reports.LearnerHideNames do
  @moduledoc """
  The MySQL spellings of the learner anonymization the Athena reports express in Presto, so a
  hidden value from a `type: :portal` student report equals the Athena one for the same learner.
  """

  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.ReportUtils

  def student_name_sql(true), do: "rl.student_id"
  def student_name_sql(_), do: "rl.student_name"

  # Presto hashes with TO_HEX(SHA1(CAST(... AS VARBINARY))), which is uppercase hex of the digest.
  # MySQL's SHA1() already returns lowercase hex, so UPPER matches it and HEX would double-encode.
  def username_sql(true) do
    salt = escape_mysql_literal(AthenaConfig.get_hide_username_hash_salt())
    "UPPER(SHA1(CONCAT('#{salt}', rl.username)))"
  end

  def username_sql(_), do: "rl.username"

  # MySQL treats a backslash inside a string literal as an escape character and Presto does not, so
  # escaping only the quotes would silently change what gets hashed.
  defp escape_mysql_literal(str) do
    str |> String.replace("\\", "\\\\") |> ReportUtils.escape_single_quote()
  end
end
