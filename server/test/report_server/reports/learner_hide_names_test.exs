defmodule ReportServer.Reports.LearnerHideNamesTest do
  use ExUnit.Case, async: false

  alias ReportServer.Reports.LearnerHideNames

  # pinned rather than read from config: without HIDE_USERNAME_HASH_SALT the salt is randomized per
  # boot, so a test reading the ambient value could not assert a digest
  @salt "pinned.salt"

  setup do
    athena = Application.get_env(:report_server, :athena, [])
    Application.put_env(:report_server, :athena, Keyword.put(athena, :hide_username_hash_salt, @salt))
    on_exit(fn -> Application.put_env(:report_server, :athena, athena) end)
  end

  describe "student_name_sql/1" do
    test "substitutes the portal student_id when names are hidden" do
      assert LearnerHideNames.student_name_sql(true) == "rl.student_id"
    end

    test "selects the name itself otherwise" do
      assert LearnerHideNames.student_name_sql(false) == "rl.student_name"
      assert LearnerHideNames.student_name_sql(nil) == "rl.student_name"
    end
  end

  describe "username_sql/1" do
    test "hashes with UPPER(SHA1(...)), the MySQL translation of the Presto expression" do
      assert LearnerHideNames.username_sql(true) ==
               "UPPER(SHA1(CONCAT('#{@salt}', rl.username)))"
    end

    test "does not wrap SHA1 in HEX, which would double-encode MySQL's hex string" do
      refute LearnerHideNames.username_sql(true) =~ "HEX(SHA1"
    end

    test "selects the username itself otherwise" do
      assert LearnerHideNames.username_sql(false) == "rl.username"
      assert LearnerHideNames.username_sql(nil) == "rl.username"
    end

    test "escapes a backslash in the salt, which MySQL would otherwise consume" do
      Application.put_env(:report_server, :athena, hide_username_hash_salt: "sa\\lt")

      assert LearnerHideNames.username_sql(true) ==
               "UPPER(SHA1(CONCAT('sa\\\\lt', rl.username)))"
    end

    test "escapes a single quote in the salt" do
      Application.put_env(:report_server, :athena, hide_username_hash_salt: "sa'lt")

      assert LearnerHideNames.username_sql(true) ==
               "UPPER(SHA1(CONCAT('sa''lt', rl.username)))"
    end
  end
end
