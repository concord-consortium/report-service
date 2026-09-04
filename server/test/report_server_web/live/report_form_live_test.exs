defmodule ReportServerWeb.ReportFormLiveTest do
  # reads the global :athena env through AthenaConfig, so it must not overlap async cases
  use ReportServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ReportServer.AccountsFixtures

  alias ReportServer.Reports

  # a super admin resolves allowed projects without a portal round trip
  defp mount_form(conn, slug) do
    user = user_fixture(%{portal_is_admin: true})
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/new/#{slug}")
    {view, user}
  end

  # the date, hide-names and application controls only render once a first filter has a value
  defp choose_first_filter(view, extra_params \\ %{}) do
    params = Map.merge(%{"filter1_type" => "cohort", "filter1" => ["1"]}, extra_params)
    render_change(view, "form_updated", %{"_target" => ["filter_form", "filter1"], "filter_form" => params})
  end

  describe "the application control" do
    test "renders on student-actions", %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions")

      html = choose_first_filter(view)

      assert html =~ "All applications"
      assert html =~ ~s(<option value="CLUE">CLUE</option>)
      assert html =~ "none (no application recorded)"
    end

    test "renders on student-actions-with-metadata", %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions-with-metadata")

      assert choose_first_filter(view) =~ "All applications"
    end

    test "does not render on teacher-actions, which reads a table with no app partition", %{conn: conn} do
      {view, _user} = mount_form(conn, "teacher-actions")

      html = choose_first_filter(view)

      refute html =~ "All applications"
      assert html =~ "Earliest date:"
    end

    test "carries a programmatic label rather than an empty one", %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions")

      assert choose_first_filter(view) =~ ~s(<label for="app")
    end
  end

  describe "submitting" do
    test "stores the selected application on the run", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      choose_first_filter(view, %{"app" => "CLUE"})

      assert {:error, {:redirect, %{to: _path}}} = render_click(view, "submit_form")

      assert [run] = Reports.list_user_report_runs(user, "student-actions")
      assert run.report_filter.app == "CLUE"
    end

    test "creates the run when the control was left blank", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      choose_first_filter(view, %{"app" => ""})

      assert {:error, {:redirect, %{to: _path}}} = render_click(view, "submit_form")

      assert [run] = Reports.list_user_report_runs(user, "student-actions")
      assert run.report_filter.app == ""
    end

    test "refuses an application on a report that does not support one", %{conn: conn} do
      {view, user} = mount_form(conn, "teacher-actions")
      choose_first_filter(view, %{"app" => "CLUE"})

      html = render_click(view, "submit_form")

      assert html =~ "does not support an application filter"
      assert Reports.list_user_report_runs(user, "teacher-actions") == []
    end

    test "accepts a blank application on a report that does not support one", %{conn: conn} do
      {view, user} = mount_form(conn, "teacher-actions")
      choose_first_filter(view, %{"app" => ""})

      assert {:error, {:redirect, %{to: _path}}} = render_click(view, "submit_form")

      assert [_run] = Reports.list_user_report_runs(user, "teacher-actions")
    end
  end
end
