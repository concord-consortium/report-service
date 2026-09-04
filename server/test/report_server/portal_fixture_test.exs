defmodule ReportServer.PortalFixtureTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}

  defp rows(sql) do
    {:ok, result} = PortalDbs.query(PortalFixture.server(), sql)
    PortalDbs.map_columns_on_rows(result)
  end

  test "the server name and the configured connection string agree" do
    assert PortalFixture.env_var() == "PORTAL_TEST_EXAMPLE_COM_DB"
    assert System.get_env(PortalFixture.env_var()),
           "config/test.exs sets a different variable than #{PortalFixture.server()} resolves to"
  end

  test "the fixture seeds four learners across two classes" do
    learners = rows("SELECT learner_id, class_id FROM report_learners ORDER BY learner_id")

    assert Enum.map(learners, & &1.learner_id) == [901, 902, 903, 904]
    assert Enum.map(learners, & &1.class_id) == [601, 601, 602, 602]
  end

  test "learner 901's joins fan out, which is what makes a row count differ from a learner count" do
    assert [%{count: 2}] = rows("SELECT COUNT(*) AS count FROM portal_runs WHERE learner_id = 901")
    assert [%{count: 2}] = rows("SELECT COUNT(*) AS count FROM portal_teacher_clazzes WHERE clazz_id = 601")
  end

  test "learner 902 carries the null edges" do
    assert [%{secure_key: nil}] = rows("SELECT secure_key FROM portal_learners WHERE id = 902")
    assert [%{url: nil}] = rows("SELECT url FROM external_activities WHERE id = 802")
    assert [%{teachers_district: nil}] = rows("SELECT teachers_district FROM report_learners WHERE learner_id = 902")
  end

  test "teacher 31 belongs to two schools whose districts and states are crossed" do
    schools =
      rows("""
      SELECT ps.id AS school_id, pd.name AS district, pd.state AS state
        FROM portal_school_memberships psm
        JOIN portal_schools ps ON (ps.id = psm.school_id)
        JOIN portal_districts pd ON (pd.id = ps.district_id)
       WHERE psm.member_type = 'Portal::Teacher' AND psm.member_id = 31
       ORDER BY ps.id
      """)

    assert length(schools) == 2
    assert Enum.map(schools, & &1.district) == ["Dist W", "Dist Y"]
    assert Enum.map(schools, & &1.state) == ["NH", "MA"]

    assert Enum.min_by(schools, & &1.district).state == "NH"
    assert Enum.min_by(schools, & &1.state).district == "Dist Y"
  end

  test "learner 903 names a teacher with no school and a teacher id with no teacher row" do
    assert [%{teachers_id: "31, 33, 34"}] =
             rows("SELECT teachers_id FROM report_learners WHERE learner_id = 903")

    assert [] = rows("SELECT id FROM portal_school_memberships WHERE member_id = 33 AND member_type = 'Portal::Teacher'")
    assert [] = rows("SELECT id FROM portal_teachers WHERE id = 34")
  end

  test "learner 904 has no teachers at all" do
    assert [%{teachers_id: nil}] = rows("SELECT teachers_id FROM report_learners WHERE learner_id = 904")
  end

  test "the project scoping rows give one project admin a subset and another nothing" do
    assert [%{project_id: 900}] =
             rows("SELECT project_id FROM admin_project_users WHERE user_id = 555 AND is_admin = 1")

    assert [] = rows("SELECT project_id FROM admin_project_users WHERE user_id = 556")

    assert [%{item_id: 31}] =
             rows("""
             SELECT aci.item_id FROM admin_cohort_items aci
               JOIN admin_cohorts ac ON (ac.id = aci.admin_cohort_id)
              WHERE ac.project_id = 900 AND aci.item_type = 'Portal::Teacher'
             """)
  end
end
