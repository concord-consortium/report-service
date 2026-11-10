defmodule ReportServer.Reports.AllowedProjectsDbTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Reports.AllowedProjects

  @admin_only %AllowedProjects{admin: [900], researcher: []}
  @researcher_only %AllowedProjects{admin: [], researcher: [902]}

  test "a caller with no researcher project is treated alike on every row" do
    for allowed <- [:all, :none, @admin_only] do
      refute AllowedProjects.researcher?(allowed)
      assert AllowedProjects.form_project_ids(allowed) == :all
      assert AllowedProjects.admin_class_sql(allowed, :class) == nil
      assert AllowedProjects.form_names_sql(allowed) == "rl.permission_forms"
    end
  end

  test "a researcher-only caller has no admin-project class" do
    assert AllowedProjects.researcher?(@researcher_only)
    assert AllowedProjects.admin_class_sql(@researcher_only, :class) == "FALSE"
    refute AllowedProjects.form_names_sql(@researcher_only) =~ "CASE"
  end

  # the narrowed expression over a derived table standing in for report_learners
  defp narrowed(project_ids, names, ids) do
    sql =
      "SELECT #{AllowedProjects.form_names_sql(%AllowedProjects{admin: [], researcher: project_ids})} " <>
        "FROM (SELECT ? AS permission_forms, ? AS permission_forms_id) rl"

    {:ok, %{rows: [[value]]}} = PortalDbs.query(PortalFixture.server(), sql, [names, ids])
    value
  end

  test "keeps the stored name at each position whose form belongs to the caller's projects" do
    assert narrowed([902], "Proj B: Form 2,Proj C: Form C", "12,15") == "Proj C: Form C"
    assert narrowed([901], "Proj B: Form 2,Proj C: Form C", "12,15") == "Proj B: Form 2"
    assert narrowed([901, 902], "Proj B: Form 2,Proj C: Form C", "12,15") == "Proj B: Form 2,Proj C: Form C"
  end

  test "is NULL when no position matches, when there are no forms, and when the lists disagree in length" do
    assert narrowed([900], "Proj B: Form 2,Proj C: Form C", "12,15") == nil
    assert narrowed([902], nil, nil) == nil
    assert narrowed([902], "Proj C: Form C", "12,15") == nil
  end
end
