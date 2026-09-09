defmodule ReportServerWeb.ReportFormLiveTest do
  # reads the global :athena env through AthenaConfig, so it must not overlap async cases
  use ReportServerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ReportServer.AccountsFixtures

  alias ReportServer.LearnerDataStub
  alias ReportServer.Reports
  alias ReportServer.Reports.{ReportFilter, ReportUtils}

  setup do
    on_exit(fn ->
      Application.delete_env(:report_server, :learner_data)
      Application.delete_env(:report_server, :partition_warning_threshold)
    end)

    :ok
  end

  # a super admin resolves allowed projects without a portal round trip
  defp mount_form(conn, slug) do
    mount_form_as(conn, slug, user_fixture(%{portal_is_admin: true}))
  end

  defp mount_form_as(conn, slug, user) do
    {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/new/#{slug}")
    {view, user}
  end

  # the date, hide-names and application controls only render once a first filter has a value
  defp choose_first_filter(view, extra_params \\ %{}) do
    params = Map.merge(%{"filter1_type" => "cohort", "filter1" => ["1"]}, extra_params)

    render_change(view, "form_updated", %{
      "_target" => ["filter_form", "filter1"],
      "filter_form" => params
    })
  end

  defp stub_learner_count(counter) do
    {:ok, pid} = LearnerDataStub.start(%{count: counter})
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)
    Application.put_env(:report_server, :learner_data, LearnerDataStub)
  end

  defp stub_count(result), do: stub_learner_count(fn _filter, _user -> result end)

  # a count that blocks until released, so the form can be edited while one is genuinely in flight
  defp stub_blocking_count do
    test = self()

    stub_learner_count(fn _filter, _user ->
      send(test, {:counting, self()})

      receive do
        {:release, result} -> result
      after
        5_000 -> {:error, "the count was never released"}
      end
    end)
  end

  defp await_counting do
    receive do
      {:counting, pid} -> pid
    after
      5_000 -> flunk("the count task never started")
    end
  end

  defp release_count(pid, result), do: send(pid, {:release, result})

  # the count runs as a task, so its result reaches the view after the click has been answered
  defp wait_for(view, needle, attempts \\ 100) do
    html = render(view)

    cond do
      html =~ needle ->
        html

      attempts == 0 ->
        flunk("timed out waiting for #{inspect(needle)}")

      true ->
        Process.sleep(5)
        wait_for(view, needle, attempts - 1)
    end
  end

  describe "the application control" do
    test "renders on student-actions", %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions")

      html = choose_first_filter(view)

      assert html =~ ~s(id="live_select_app")
      assert html =~ ~s(name="filter_form[app_text_input]")
      # collapse whitespace so the assertions test the copy rather than where it wraps
      text = String.replace(html, ~r/\s+/, " ")
      assert text =~ "Leave this empty to include every application"
      assert text =~ "logs can span more than one application"
      # the list contains an option literally labelled "none", so the help text must never say
      # "select none" to mean "select nothing"
      refute text =~ "Select none"
    end

    test "renders on student-actions-with-metadata", %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions-with-metadata")

      assert choose_first_filter(view) =~ ~s(id="live_select_app")
    end

    test "does not render on teacher-actions, which reads a table with no app partition",
         %{conn: conn} do
      {view, _user} = mount_form(conn, "teacher-actions")

      html = choose_first_filter(view)

      refute html =~ ~s(id="live_select_app")
      assert html =~ "Earliest date:"
    end

    test "carries a programmatic label rather than an empty one", %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions")

      html = choose_first_filter(view)

      assert html =~ ~s(<label for="filter_form_app_text_input")
      assert html =~ ~s(id="filter_form_app_text_input")
    end

    # LiveSelect renders each tag's removal control as a button whose only content is the
    # clear_button slot, so without this text the button announces as an unnamed "button"
    test "a selected application's removal button carries hidden text naming the action",
         %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions")

      html = choose_first_filter(view, %{"app" => ["CLUE"]})

      assert html =~ "CLUE"

      # sr-only rather than a bare span: the name has to reach a screen reader without adding
      # visible text beside the glyph
      assert Floki.find(html, ~s(#live_select_app button span.sr-only))
             |> Enum.any?(&(Floki.text(&1) |> String.trim() == "Remove"))
    end

    test "a selected numbered filter's removal button carries the same hidden text",
         %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions")

      html = choose_first_filter(view)

      assert Floki.find(html, ~s(#live_select1 button span.sr-only))
             |> Enum.any?(&(Floki.text(&1) |> String.trim() == "Remove"))
    end

    test "the search box is not labelled as if nothing were selected", %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions")

      html = choose_first_filter(view, %{"app" => ["CLUE"]})

      # LiveSelect leaves the tags-mode text input empty whatever is selected, so a placeholder
      # describing the empty filter would sit on screen next to a CLUE tag contradicting it
      [input] = Floki.find(html, ~s(input[name="filter_form[app_text_input]"]))
      assert Floki.attribute(input, "placeholder") == ["Search applications"]
    end

    # the hook sends the form-qualified field name, which carries none of the trailing index the
    # numbered filters are found by, so this event must never reach the filter lookup
    test "a change event from the application box never reaches the numbered-filter lookup",
         %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions")
      choose_first_filter(view)

      render_hook(view, "live_select_change", %{
        "field" => "filter_form_app",
        "id" => "live_select_app",
        "text" => "data"
      })

      assert render(view) =~ ~s(id="live_select_app")
    end
  end

  describe "submitting" do
    test "stores the selected application on the run", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      stub_count({:ok, 1})
      choose_first_filter(view, %{"app" => ["CLUE"]})

      render_click(view, "submit_form")
      assert_redirect(view)

      assert [run] = Reports.list_user_report_runs(user, "student-actions")
      assert run.report_filter.app == ["CLUE"]
    end

    test "creates the run when the control was left blank", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      stub_count({:ok, 1})
      choose_first_filter(view, %{"app" => []})

      render_click(view, "submit_form")
      assert_redirect(view)

      assert [run] = Reports.list_user_report_runs(user, "student-actions")
      # deselecting everything sends no key at all, so the stored value is nil rather than []
      assert ReportFilter.app_list(run.report_filter.app) == []
    end

    # the date control constrains a browser and not a crafted event, and apply_start_date/3
    # interpolates its argument into the portal statement
    test "refuses a date the portal statement would carry verbatim", %{conn: conn} do
      {view, user} = mount_form(conn, "teacher-actions")
      payload = "2026-01-01' OR '1'='1"
      choose_first_filter(view, %{"start_date" => payload})

      html = render_click(view, "submit_form")

      assert html =~ "must be an ISO 8601 date"
      assert Reports.list_user_report_runs(user, "teacher-actions") == []
      assert_raise ArgumentError, fn -> ReportUtils.apply_start_date([], payload) end
    end

    # the label lookup resolves the user's projects against the portal, and a project-scoped user
    # is the one whose lookup can fail
    test "creates the run when the labels cannot be derived", %{conn: conn} do
      researcher = user_fixture(%{portal_is_project_researcher: true})
      {view, _user} = mount_form_as(conn, "teacher-actions", researcher)
      choose_first_filter(view)

      render_click(view, "submit_form")
      assert_redirect(view)

      assert [run] = Reports.list_user_report_runs(researcher, "teacher-actions")
      assert run.report_filter_values == %{}
      assert run.report_filter.cohort == [1]
    end

    test "refuses an application on a report that does not support one", %{conn: conn} do
      {view, user} = mount_form(conn, "teacher-actions")
      choose_first_filter(view, %{"app" => ["CLUE"]})

      html = render_click(view, "submit_form")

      assert html =~ "does not support an application filter"
      assert Reports.list_user_report_runs(user, "teacher-actions") == []
    end

    test "accepts a blank application on a report that does not support one", %{conn: conn} do
      {view, user} = mount_form(conn, "teacher-actions")
      choose_first_filter(view, %{"app" => []})

      render_click(view, "submit_form")
      assert_redirect(view)

      assert [_run] = Reports.list_user_report_runs(user, "teacher-actions")
    end
  end

  describe "the partition warning" do
    test "warns and creates nothing when the projection crosses the limit", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      stub_count({:ok, 141})
      choose_first_filter(view)

      render_click(view, "submit_form")
      html = wait_for(view, "141 learners")

      assert html =~ "1,001,664 partitions"
      assert html =~ "over the 1,000,000 limit"
      assert Reports.list_user_report_runs(user, "student-actions") == []
    end

    test "does not warn just under the limit", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      stub_count({:ok, 140})
      choose_first_filter(view)

      render_click(view, "submit_form")
      assert_redirect(view)

      assert [_run] = Reports.list_user_report_runs(user, "student-actions")
    end

    test "confirming runs it anyway, from the filter the count was made against", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      # over the limit even with one application selected: 3000 x 1 x 444
      stub_count({:ok, 3_000})
      choose_first_filter(view, %{"app" => ["CLUE"]})
      render_click(view, "submit_form")
      wait_for(view, "Run it anyway")

      render_click(view, "submit_form_confirmed")
      assert_redirect(view)

      assert [run] = Reports.list_user_report_runs(user, "student-actions")
      assert run.report_filter.app == ["CLUE"]
    end

    test "an unknown application is refused at the form, before any portal or S3 work", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      # the count is what a submit reaching the run would call; refusing first means it never does
      stub_count({:ok, 1})
      choose_first_filter(view, %{"app" => ["CLUE", "NotAnApp"]})

      html = render_click(view, "submit_form")

      assert html =~ "Unknown application: NotAnApp"
      assert Reports.list_user_report_runs(user, "student-actions") == []
    end

    test "editing the form drops a warning it no longer describes", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      stub_count({:ok, 3_000})
      choose_first_filter(view, %{"app" => ["CLUE"]})
      render_click(view, "submit_form")
      wait_for(view, "Run it anyway")

      html = choose_first_filter(view, %{"app" => ["Dataflow"]})
      refute html =~ "Run it anyway"

      # the confirm the researcher can no longer see must not run the filter it was counted for
      render_click(view, "submit_form_confirmed")
      assert Reports.list_user_report_runs(user, "student-actions") == []
    end

    test "a count still in flight keeps the filter it was started on", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      stub_blocking_count()
      choose_first_filter(view, %{"app" => ["CLUE"]})
      render_click(view, "submit_form")
      counting = await_counting()

      # the select stays enabled while the count runs, so this is an ordinary interaction
      choose_first_filter(view, %{"app" => ["Dataflow"]})
      release_count(counting, {:ok, 1})
      assert_redirect(view)

      assert [run] = Reports.list_user_report_runs(user, "student-actions")
      assert run.report_filter.app == ["CLUE"]
    end

    test "a configured threshold lowers where the warning fires", %{conn: conn} do
      Application.put_env(:report_server, :partition_warning_threshold, 1_000)
      {view, user} = mount_form(conn, "student-actions")
      stub_count({:ok, 1})
      choose_first_filter(view)

      render_click(view, "submit_form")

      assert wait_for(view, "over the 1,000 limit")
      assert Reports.list_user_report_runs(user, "student-actions") == []
    end

    test "a count that fails still creates the run, leaving the view alive", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      stub_count({:error, "portal is down"})
      choose_first_filter(view)

      render_click(view, "submit_form")
      assert_redirect(view)

      assert [_run] = Reports.list_user_report_runs(user, "student-actions")
    end

    test "a count that crashes still creates the run, leaving the view alive", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      stub_learner_count(fn _filter, _user -> raise "boom" end)
      choose_first_filter(view)

      render_click(view, "submit_form")
      assert_redirect(view)

      assert [_run] = Reports.list_user_report_runs(user, "student-actions")
    end

    test "a report without the filter enabled never counts", %{conn: conn} do
      {view, user} = mount_form(conn, "teacher-actions")
      stub_count({:ok, 10_000_000})
      choose_first_filter(view)

      render_click(view, "submit_form")
      assert_redirect(view)

      assert [_run] = Reports.list_user_report_runs(user, "teacher-actions")
    end

    test "confirming with nothing pending does nothing", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      choose_first_filter(view)

      render_click(view, "submit_form_confirmed")

      assert Reports.list_user_report_runs(user, "student-actions") == []
      assert render(view) =~ "Run Report"
    end

    test "the run button reports being busy while the count is in flight", %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions")
      test_process = self()

      stub_learner_count(fn _filter, _user ->
        send(test_process, :counting)
        Process.sleep(200)
        {:ok, 1}
      end)

      choose_first_filter(view)
      render_click(view, "submit_form")
      assert_receive :counting

      html = render(view)

      assert html =~ ~s(aria-busy="true")
      assert html =~ "Checking"
    end

    test "a second submit while a count is in flight is ignored", %{conn: conn} do
      {view, user} = mount_form(conn, "student-actions")
      test_process = self()

      stub_learner_count(fn _filter, _user ->
        send(test_process, :counting)
        Process.sleep(100)
        {:ok, 1}
      end)

      choose_first_filter(view)
      render_click(view, "submit_form")
      assert_receive :counting

      # the form still submits on Enter while the button is disabled, and a second task would
      # orphan the first, whose reply would then match no clause
      render_click(view, "submit_form")

      refute_receive :counting, 300
      assert [_run] = Reports.list_user_report_runs(user, "student-actions")
    end

    test "the warning is announced and offers the confirm", %{conn: conn} do
      {view, _user} = mount_form(conn, "student-actions")
      stub_count({:ok, 141})
      choose_first_filter(view)

      render_click(view, "submit_form")
      html = wait_for(view, "Run it anyway")

      assert html =~ ~s(role="alert")
    end
  end
end
