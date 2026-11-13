defmodule ReportServer.Reports.LearnerScopingDbTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{ReportFilter, ReportQuery}
  alias ReportServer.Reports.Athena.LearnerData
  alias ReportServer.Reports.Portal.StudentIdMappingReport

  @server PortalFixture.server()
  @filter %ReportFilter{filters: [:class], class: [601, 602, 604]}

  defp user(id, flags), do: struct(%User{portal_server: @server, portal_user_id: id}, flags)
  defp researcher(id), do: user(id, portal_is_project_researcher: true)

  defp learner_ids(user, filter \\ @filter) do
    {:ok, query} = StudentIdMappingReport.get_query(filter, user)
    {:ok, sql} = ReportQuery.get_sql(query)
    {:ok, result} = PortalDbs.query(@server, sql)
    result |> PortalDbs.map_columns_on_rows() |> Enum.map(& &1.learner_id) |> Enum.sort()
  end

  test "a researcher sees only the cohort-class learners holding their project's form" do
    assert learner_ids(researcher(557)) == [901]
    assert learner_ids(researcher(563)) == [905]
  end

  test "a researcher on a project with no permission forms sees every cohort-class learner" do
    assert learner_ids(researcher(572), %ReportFilter{filters: [:class], class: [605]}) == [908]
  end

  test "a project admin of the same project sees every cohort-class learner" do
    assert learner_ids(user(555, portal_is_project_admin: true)) == [901, 903, 904]
  end

  test "a user with both roles gets the admin project's learners and the consented researcher-project ones" do
    mixed = user(562, portal_is_project_admin: true, portal_is_project_researcher: true)
    assert learner_ids(mixed) == [901, 903, 904, 905]
  end

  test "an expired researcher row admits nothing and a live one admits by consent" do
    assert learner_ids(researcher(564)) == []
    assert learner_ids(researcher(566)) == [901]
  end

  test "the form must belong to the project that reaches the class, not to any of the caller's projects" do
    assert learner_ids(researcher(569)) == [901, 905]
  end

  test "a site admin with a researcher row sees every learner" do
    site_admin = user(570, portal_is_admin: true, portal_is_project_researcher: true)
    assert learner_ids(site_admin) == [901, 902, 903, 904, 905, 906, 907]
  end

  test "a researcher's named form matches only a form of their projects" do
    assert learner_ids(researcher(563), %{@filter | permission_form: [12]}) == []
    assert learner_ids(researcher(563), %{@filter | permission_form: [15]}) == [905]
  end

  test "a user with both roles matches a foreign form in an admin-project class only" do
    mixed = user(562, portal_is_project_admin: true, portal_is_project_researcher: true)
    assert learner_ids(mixed, %{@filter | permission_form: [12]}) == [901]
    assert learner_ids(mixed, %{@filter | permission_form: [11]}) == [901, 905]
  end

  test "the Athena learner fetch takes the same rule" do
    assert {:ok, groups} = LearnerData.fetch(@filter, researcher(557), allow_empty: true)
    assert groups |> Enum.flat_map(& &1.learners) |> Enum.map(& &1.learner_id) == [901]
  end
end
