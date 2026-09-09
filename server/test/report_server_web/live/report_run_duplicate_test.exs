defmodule ReportServerWeb.ReportRunDuplicateTest do
  use ReportServerWeb.ConnCase, async: false

  @moduletag :portal_db

  import Phoenix.LiveViewTest
  import ReportServer.AccountsFixtures

  alias ReportServer.{PortalFixture, Repo, Reports}
  alias ReportServer.Reports.{ReportFilter, ReportRun}

  @server PortalFixture.server()

  setup do
    test = self()
    Application.put_env(:report_server, :athena_run_starter, fn run -> send(test, {:started, run.id}) end)
    on_exit(fn -> Application.delete_env(:report_server, :athena_run_starter) end)
    :ok
  end

  defp admin, do: user_fixture(%{portal_server: @server, portal_is_admin: true})
  defp researcher,
    do: user_fixture(%{portal_server: @server, portal_user_id: 557, portal_is_project_researcher: true})

  defp stranger, do: user_fixture(%{portal_server: @server, portal_is_project_researcher: true})

  defp run_fixture(user, slug \\ "student-answers", filter \\ %ReportFilter{filters: [:cohort], cohort: [1]}) do
    {:ok, run} =
      Reports.create_report_run(%{
        user_id: user.id,
        report_slug: slug,
        report_filter: filter,
        report_filter_values: %{}
      })

    run
  end

  defp newest_run, do: Repo.all(ReportRun) |> Enum.max_by(& &1.id)

  describe "the runs table" do
    test "duplicating my own run creates a run owned by me and goes to it", %{conn: conn} do
      user = researcher()
      source = run_fixture(user)

      {:ok, view, html} = live(log_in_conn(conn, user), ~p"/reports/runs")
      assert html =~ "Duplicate"

      assert {:error, {:redirect, %{to: to}}} =
               view |> element("button[phx-value-id='#{source.id}']") |> render_click()

      copy = newest_run()
      assert copy.id != source.id
      assert copy.user_id == user.id
      assert to == "/reports/runs/#{copy.id}"
    end

    test "an admin duplicating another user's run on all-runs owns the copy", %{conn: conn} do
      owner = researcher()
      admin = admin()
      source = run_fixture(owner)

      {:ok, view, _html} = live(log_in_conn(conn, admin), ~p"/reports/all-runs")

      assert {:error, {:redirect, _}} =
               view |> element("button[phx-value-id='#{source.id}']") |> render_click()

      copy = newest_run()
      assert copy.id != source.id
      assert copy.user_id == admin.id
    end

    test "a non-admin cannot reach all-runs at all", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/reports"}}} =
               live(log_in_conn(conn, researcher()), ~p"/reports/all-runs")
    end

    test "a non-admin naming another user's run is refused, whatever the DOM said", %{conn: conn} do
      owner = researcher()
      other = stranger()
      source = run_fixture(owner)

      {:ok, view, _html} = live(log_in_conn(conn, other), ~p"/reports/runs")

      html = render_click(view, "duplicate", %{"id" => to_string(source.id)})

      assert html =~ "you don&#39;t have access to that report run"
      assert Repo.aggregate(ReportRun, :count) == 1
    end

    test "a Portal run duplicates without a force flag", %{conn: conn} do
      user = admin()
      source = run_fixture(user, "school-metrics", %ReportFilter{filters: [:country], country: [1]})

      {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/runs")

      assert {:error, {:redirect, _}} =
               view |> element("button[phx-value-id='#{source.id}']") |> render_click()

      assert newest_run().report_slug == "school-metrics"
    end

    test "a run whose filter no longer validates flashes and leaves the view alive", %{conn: conn} do
      user = admin()
      source = run_fixture(user, "student-answers", %ReportFilter{cohort: [1], start_date: "nope"})

      {:ok, view, _html} = live(log_in_conn(conn, user), ~p"/reports/runs")

      html = view |> element("button[phx-value-id='#{source.id}']") |> render_click()

      assert html =~ "Unable to duplicate this report run"
      assert Repo.aggregate(ReportRun, :count) == 1
      assert render(view) =~ "Duplicate"
    end
  end

  describe "the report form" do
    test "duplicates a run from the runs table it renders", %{conn: conn} do
      user = admin()
      source = run_fixture(user)

      {:ok, view, html} = live(log_in_conn(conn, user), ~p"/reports/new/student-answers")
      assert html =~ "Duplicate"

      assert {:error, {:redirect, %{to: to}}} =
               view |> element("button[phx-value-id='#{source.id}']") |> render_click()

      assert to == "/reports/runs/#{newest_run().id}"
    end
  end

  describe "the run page" do
    test "duplicates the run it is showing", %{conn: conn} do
      user = admin()
      source = run_fixture(user)

      {:ok, view, html} = live(log_in_conn(conn, user), ~p"/reports/runs/#{source.id}")
      assert html =~ "Duplicate"

      assert {:error, {:redirect, %{to: to}}} =
               view |> element("button[phx-value-id='#{source.id}']") |> render_click()

      copy = newest_run()
      assert copy.id != source.id
      assert to == "/reports/runs/#{copy.id}"
    end
  end
end
