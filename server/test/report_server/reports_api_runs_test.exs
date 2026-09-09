defmodule ReportServer.ReportsApiRunsTest do
  use ReportServer.DataCase, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture, Reports}
  alias ReportServer.Reports.{ReportFilter, ReportQuery, ReportRun, Tree}

  import ReportServer.AccountsFixtures

  @server PortalFixture.server()

  defp admin, do: user_fixture(%{portal_server: @server, portal_is_admin: true})

  defp researcher,
    do: user_fixture(%{portal_server: @server, portal_user_id: 557, portal_is_project_researcher: true})

  defp report(slug), do: Tree.find_report(slug)

  defp athena_report, do: report("student-answers")
  defp app_report, do: report("student-actions")
  defp portal_report, do: report("resource-metrics-summary")
  defp taxonomy_report, do: report("school-metrics")

  defp create(user, report, filter), do: Reports.create_api_report_run(user, report, filter)

  defp run_count, do: Repo.aggregate(ReportRun, :count)

  defp sql(report, filter, user) do
    {:ok, query} = report.get_query.(filter, user)
    {:ok, sql} = ReportQuery.get_sql(query)
    sql
  end

  defp record_starts do
    test = self()
    Application.put_env(:report_server, :athena_run_starter, fn run -> send(test, {:started, run.id}) end)
    on_exit(fn -> Application.delete_env(:report_server, :athena_run_starter) end)
  end

  describe "create_api_report_run/3" do
    setup do
      record_starts()
      :ok
    end

    test "derives filters in reverse declaration order" do
      {:ok, run} = create(admin(), athena_report(), %ReportFilter{cohort: [1], school: [51]})

      assert run.report_filter.filters == [:school, :cohort]
    end

    test "an unset dimension is not in filters and a filled one is" do
      {:ok, run} = create(admin(), athena_report(), %ReportFilter{cohort: [1], school: nil})

      assert run.report_filter.filters == [:cohort]
    end

    test "derives the labels" do
      {:ok, run} = create(admin(), athena_report(), %ReportFilter{cohort: [1]})

      assert run.report_filter_values == %{cohort: %{1 => "Cohort One"}}
    end

    test "stores the id the portal holds rather than the one the caller sent" do
      {:ok, run} = create(admin(), taxonomy_report(), %ReportFilter{state: ["ma"]})

      assert run.report_filter.state == ["MA"]
    end

    test "hide_names is forced on for a caller who may not see names" do
      {:ok, run} = create(researcher(), athena_report(), %ReportFilter{cohort: [1], hide_names: false})

      assert run.report_filter.hide_names
    end

    test "an Athena run is inserted with no query id and its query is started" do
      {:ok, run} = create(admin(), athena_report(), %ReportFilter{cohort: [1]})

      assert run.athena_query_id == nil
      assert run.athena_query_state == nil
      assert run.user.id
      assert_receive {:started, id} when id == run.id
    end

    test "a Portal run starts no query" do
      {:ok, run} = create(admin(), portal_report(), %ReportFilter{cohort: [1]})

      refute_receive {:started, _id}
      assert run.report_slug == "resource-metrics-summary"
    end

    test "a Portal filter that yields no query is refused with the builder's own message" do
      before = run_count()

      assert {:error, :invalid, message} = create(admin(), taxonomy_report(), %ReportFilter{})
      assert message =~ "no filters"
      assert run_count() == before

      assert {:ok, _run} = create(admin(), taxonomy_report(), %ReportFilter{country: [1]})
    end

    test "an Athena filter that constrains nothing is refused by the input rule" do
      before = run_count()

      assert {:error, :invalid, message} = create(admin(), athena_report(), %ReportFilter{})
      assert message =~ "at least one dimension, date or application"
      assert run_count() == before
    end

    test "an Athena filter carrying only an application is accepted" do
      assert {:ok, run} = create(admin(), app_report(), %ReportFilter{app: ["CODAP"]})

      assert run.report_filter_values == %{}
      assert run.report_filter.filters == []
    end

    test "a dimension selecting nothing is refused and inserts nothing" do
      before = run_count()

      assert {:error, :invalid, message} =
               create(admin(), athena_report(), %ReportFilter{cohort: [1], school: []})

      assert message =~ "no values selected for: school"
      assert run_count() == before

      assert {:ok, _run} = create(admin(), athena_report(), %ReportFilter{cohort: [1], school: nil})
    end

    test "a dimension the report does not offer is refused" do
      assert {:error, :invalid, message} = create(admin(), athena_report(), %ReportFilter{country: [1]})
      assert message =~ "does not filter on: country"
    end

    test "an unparseable date is refused" do
      assert {:error, :invalid, message} =
               create(admin(), athena_report(), %ReportFilter{cohort: [1], start_date: "nope"})

      assert message =~ "ISO 8601"
    end

    test "an id the caller cannot see is refused, naming the dimension" do
      before = run_count()

      assert {:error, :out_of_scope, [{:cohort, [2]}]} =
               create(researcher(), athena_report(), %ReportFilter{cohort: [2]})

      assert run_count() == before
    end

    test "a failed label derivation fails the create and inserts nothing" do
      unreachable = user_fixture(%{portal_server: "no.such.host.example", portal_is_admin: true})
      before = run_count()

      assert {:error, :derivation_failed, _reason} =
               create(unreachable, athena_report(), %ReportFilter{cohort: [1]})

      assert run_count() == before
    end
  end

  describe "duplicate_api_report_run/3" do
    setup do
      record_starts()
      :ok
    end

    test "copies the slug and the filter and starts a query of its own" do
      user = admin()
      {:ok, source} = create(user, athena_report(), %ReportFilter{cohort: [1]})
      {:ok, _} = Reports.update_report_run(source, %{athena_query_id: "abc", athena_result_url: "s3://x"})
      source = Reports.get_report_run_with_user!(source.id)

      {:ok, copy} = Reports.duplicate_api_report_run(user, athena_report(), source)

      assert copy.id != source.id
      assert copy.report_slug == source.report_slug
      assert copy.report_filter.cohort == [1]
      assert copy.athena_query_id == nil
      assert copy.athena_result_url == nil
      assert_receive {:started, id} when id == copy.id
    end

    test "derives filters rather than copying the strings a round trip left behind" do
      user = admin()
      {:ok, source} = create(user, athena_report(), %ReportFilter{cohort: [1], school: [51]})
      source = Reports.get_report_run_with_user!(source.id)

      assert source.report_filter.filters == ["school", "cohort"]

      {:ok, copy} = Reports.duplicate_api_report_run(user, athena_report(), source)

      assert copy.report_filter.filters == [:school, :cohort]
    end

    test "re-derives the labels rather than copying the source's snapshot" do
      user = admin()
      {:ok, source} = create(user, athena_report(), %ReportFilter{cohort: [1]})
      assert source.report_filter_values == %{cohort: %{1 => "Cohort One"}}

      rename_cohort_one("Cohort One Renamed")

      {:ok, copy} = Reports.duplicate_api_report_run(user, athena_report(), source)

      assert copy.report_filter_values == %{cohort: %{1 => "Cohort One Renamed"}}
    end

    test "a dimension selecting nothing is dropped rather than refused, and the SQL is unchanged" do
      user = admin()
      source_filter = %ReportFilter{cohort: [1], school: []}
      {:ok, source} = Reports.create_report_run(%{user_id: user.id, report_slug: "resource-metrics-summary", report_filter: source_filter, report_filter_values: %{}})
      source = Reports.get_report_run_with_user!(source.id)

      {:ok, copy} = Reports.duplicate_api_report_run(user, portal_report(), source)

      assert copy.report_filter.school == nil
      assert copy.report_filter.cohort == [1]
      assert sql(portal_report(), copy.report_filter, user) == sql(portal_report(), source_filter, user)
    end

    test "a run with no stored filter is read as the empty filter rather than raising" do
      user = admin()
      {:ok, source} = Reports.create_report_run(%{user_id: user.id, report_slug: "student-actions", report_filter: nil, report_filter_values: %{}})
      source = Reports.get_report_run_with_user!(source.id)

      assert {:error, :invalid, message} = Reports.duplicate_api_report_run(user, app_report(), source)
      assert message =~ "at least one dimension, date or application"
    end

    test "a stored date that does not parse is refused rather than repaired" do
      user = admin()
      filter = %ReportFilter{cohort: [1], start_date: "2026-01-01' OR '1'='1"}
      {:ok, source} = Reports.create_report_run(%{user_id: user.id, report_slug: "student-answers", report_filter: filter, report_filter_values: %{}})
      source = Reports.get_report_run_with_user!(source.id)

      assert {:error, :invalid, message} = Reports.duplicate_api_report_run(user, athena_report(), source)
      assert message =~ "ISO 8601"
    end
  end

  # The kickoff is injectable so a test can assert it happened at all; nothing may configure one
  # outside a test, or production would stop starting the supervised task.
  test "no starter override is configured" do
    refute Application.get_env(:report_server, :athena_run_starter)
  end

  defp rename_cohort_one(name) do
    {:ok, _} = PortalDbs.query(@server, "UPDATE admin_cohorts SET name = '#{name}' WHERE id = 1")
    on_exit(fn -> PortalDbs.query(@server, "UPDATE admin_cohorts SET name = 'Cohort One' WHERE id = 1") end)
  end
end
