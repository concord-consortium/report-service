defmodule ReportServer.Reports.LearnerHideNames do
  @moduledoc """
  The MySQL spellings of the learner anonymization the Athena reports express in Presto, so a
  hidden value from a `type: :portal` student report equals the Athena one for the same learner.
  """

  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.ReportUtils

  @doc """
  The student name for a row: hidden when `hide_names` is set, shown otherwise, or, given a
  `predicate`, shown only on the rows it holds for and hidden on the rest.
  """
  def student_name_sql(hide_names, predicate \\ nil)
  def student_name_sql(true, _predicate), do: "rl.student_id"
  def student_name_sql(_, nil), do: "rl.student_name"
  def student_name_sql(_, predicate), do: "CASE WHEN #{predicate} THEN rl.student_name ELSE CAST(rl.student_id AS CHAR) END"

  @doc "The username for a row, by the same rule as `student_name_sql/2`."
  def username_sql(hide_names, predicate \\ nil)

  # Presto hashes with TO_HEX(SHA1(CAST(... AS VARBINARY))), which is uppercase hex of the digest.
  # MySQL's SHA1() already returns lowercase hex, so UPPER matches it and HEX would double-encode.
  def username_sql(true, _predicate) do
    salt = ReportUtils.escape_mysql_literal(AthenaConfig.get_hide_username_hash_salt())
    "UPPER(SHA1(CONCAT('#{salt}', rl.username)))"
  end

  def username_sql(_, nil), do: "rl.username"
  def username_sql(_, predicate), do: "CASE WHEN #{predicate} THEN rl.username ELSE #{username_sql(true)} END"
end
