defmodule ReportServer.ReportsTest do
  use ReportServer.DataCase

  alias ReportServer.Reports

  describe "report_runs" do
    alias ReportServer.Reports.ReportRun

    import ReportServer.ReportsFixtures

    @invalid_attrs %{report_slug: nil, report_filter: nil, report_filter_values: nil}

    @tag :skip
    test "list_report_runs/0 returns all report_runs" do
      report_run = report_run_fixture()
      assert Reports.list_all_report_runs() == [report_run]
    end

    @tag :skip
    test "get_report_run!/1 returns the report_run with given id" do
      report_run = report_run_fixture()
      assert Reports.get_report_run!(report_run.id) == report_run
    end

    @tag :skip
    test "create_report_run/1 with valid data creates a report_run" do
      valid_attrs = %{report_slug: "some report_slug", report_filter: %{}, report_filter_values: %{}}

      assert {:ok, %ReportRun{} = report_run} = Reports.create_report_run(valid_attrs)
      assert report_run.report_slug == "some report_slug"
      assert report_run.report_filter == %{}
      assert report_run.report_filter_values == %{}
    end

    test "create_report_run/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Reports.create_report_run(@invalid_attrs)
    end

    @tag :skip
    test "update_report_run/2 with valid data updates the report_run" do
      report_run = report_run_fixture()
      update_attrs = %{report_slug: "some updated report_slug", report_filter: %{}, report_filter_values: %{}}

      assert {:ok, %ReportRun{} = report_run} = Reports.update_report_run(report_run, update_attrs)
      assert report_run.report_slug == "some updated report_slug"
      assert report_run.report_filter == %{}
      assert report_run.report_filter_values == %{}
    end

    @tag :skip
    test "update_report_run/2 with invalid data returns error changeset" do
      report_run = report_run_fixture()
      assert {:error, %Ecto.Changeset{}} = Reports.update_report_run(report_run, @invalid_attrs)
      assert report_run == Reports.get_report_run!(report_run.id)
    end

    @tag :skip
    test "delete_report_run/1 deletes the report_run" do
      report_run = report_run_fixture()
      assert {:ok, %ReportRun{}} = Reports.delete_report_run(report_run)
      assert_raise Ecto.NoResultsError, fn -> Reports.get_report_run!(report_run.id) end
    end

    @tag :skip
    test "change_report_run/1 returns a report_run changeset" do
      report_run = report_run_fixture()
      assert %Ecto.Changeset{} = Reports.change_report_run(report_run)
    end
  end
end
