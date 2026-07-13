defmodule ReportServer.AuditLogTest do
  use ReportServer.DataCase

  import ReportServer.AccountsFixtures

  alias ReportServer.AuditLog
  alias ReportServer.AuditLog.DataAccessLogEntry
  alias ReportServer.Reports
  alias ReportServer.Reports.ReportFilter

  defp report_run_fixture(user) do
    {:ok, report_run} =
      Reports.create_report_run(%{
        user_id: user.id,
        report_slug: "student-answers",
        report_filter: %ReportFilter{filters: [:cohort], cohort: [1, 2]},
        report_filter_values: %{"cohort" => %{"1" => "Cohort One"}}
      })

    report_run
  end

  defp entry_count(), do: Repo.aggregate(DataAccessLogEntry, :count)

  describe "issue_download_url/6" do
    test "writes exactly one row with the issuance attrs and returns the url" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      assert {:ok, "https://presigned"} =
               AuditLog.issue_download_url("api", "run_csv", report_run, user.id, fn ->
                 {:ok, "https://presigned"}
               end)

      assert entry_count() == 1

      entry = Repo.one!(DataAccessLogEntry)
      assert entry.event == "download_url_issued"
      assert entry.source == "api"
      assert entry.data_type == "run_csv"
      assert entry.user_id == user.id
      assert entry.report_run_id == report_run.id
      assert entry.report_slug == "student-answers"
      assert entry.job_id == nil
      assert entry.cursor == nil
      assert entry.endpoint_set == nil
      assert entry.report_filter["cohort"] == [1, 2]
      assert %DateTime{} = entry.inserted_at
    end

    test "records the job id for post-processing artifacts" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      assert {:ok, _url} =
               AuditLog.issue_download_url(
                 "web",
                 "job_result",
                 report_run,
                 user.id,
                 fn -> {:ok, "https://presigned"} end,
                 job_id: 3
               )

      entry = Repo.one!(DataAccessLogEntry)
      assert entry.source == "web"
      assert entry.data_type == "job_result"
      assert entry.job_id == 3
    end

    test "records the requesting user, who may not be the run owner" do
      owner = user_fixture()
      admin = user_fixture(%{portal_is_admin: true})
      report_run = report_run_fixture(owner)

      assert {:ok, _url} =
               AuditLog.issue_download_url("web", "run_csv", report_run, admin.id, fn ->
                 {:ok, "https://presigned"}
               end)

      entry = Repo.one!(DataAccessLogEntry)
      assert entry.user_id == admin.id
      assert entry.report_run_id == report_run.id
    end

    test "a run with no stored filter writes a null filter snapshot" do
      user = user_fixture()
      {:ok, report_run} = Reports.create_report_run(%{user_id: user.id, report_slug: "student-answers"})

      assert {:ok, _url} =
               AuditLog.issue_download_url("api", "run_csv", report_run, user.id, fn ->
                 {:ok, "https://presigned"}
               end)

      assert Repo.one!(DataAccessLogEntry).report_filter == nil
    end

    test "presign failure writes no row and returns {:error, :presign, reason}" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      assert {:error, :presign, "boom"} =
               AuditLog.issue_download_url("api", "run_csv", report_run, user.id, fn ->
                 {:error, "boom"}
               end)

      assert entry_count() == 0
    end

    test "audit write failure discards the url and returns {:error, :audit, _}" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      assert {:error, :audit, %Ecto.Changeset{}} =
               AuditLog.issue_download_url("bogus_source", "run_csv", report_run, user.id, fn ->
                 {:ok, "https://presigned"}
               end)

      assert entry_count() == 0
    end
  end

  describe "create_entry/1" do
    test "rejects unknown event, source and data_type values" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      base = %{
        event: "download_url_issued",
        source: "api",
        data_type: "run_csv",
        user_id: user.id,
        report_run_id: report_run.id
      }

      assert {:error, changeset} = AuditLog.create_entry(%{base | event: "nope"})
      assert "is invalid" in errors_on(changeset).event

      assert {:error, changeset} = AuditLog.create_entry(%{base | source: "nope"})
      assert "is invalid" in errors_on(changeset).source

      assert {:error, changeset} = AuditLog.create_entry(%{base | data_type: "nope"})
      assert "is invalid" in errors_on(changeset).data_type

      assert entry_count() == 0
    end

    test "returns a changeset error rather than raising on a foreign key violation" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      assert {:error, changeset} =
               AuditLog.create_entry(%{
                 event: "download_url_issued",
                 source: "api",
                 data_type: "run_csv",
                 user_id: user.id,
                 report_run_id: report_run.id + 999_999
               })

      assert "does not exist" in errors_on(changeset).report_run_id
      assert entry_count() == 0
    end
  end

  test "the context exposes no update or delete functions" do
    exported = ReportServer.AuditLog.__info__(:functions) |> Keyword.keys() |> Enum.uniq()

    refute Enum.any?(exported, fn name ->
             name |> Atom.to_string() |> String.starts_with?(["update", "delete"])
           end)
  end
end
