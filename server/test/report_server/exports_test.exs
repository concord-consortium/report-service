defmodule ReportServer.ExportsTest do
  use ReportServer.DataCase

  import ReportServer.AccountsFixtures

  alias ReportServer.Exports
  alias ReportServer.Exports.ExportScratch
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

  defp scratch_attrs(user, report_run, overrides \\ %{}) do
    Map.merge(
      %{
        scratch_id: Exports.mint_scratch_id(),
        report_run_id: report_run.id,
        user_id: user.id,
        data_type: "answers_bulk",
        endpoint_set: [%{"remote_endpoint" => "re-1", "source" => "activity-player.concord.org"}],
        expires_at: Exports.ttl_expires_at()
      },
      overrides
    )
  end

  defp insert_scratch!(attrs) do
    {:ok, scratch} = %ExportScratch{} |> ExportScratch.changeset(attrs) |> Repo.insert()
    scratch
  end

  describe "mint_scratch_id/0" do
    test "returns a 43-char url-safe base64 id, unique across calls" do
      id = Exports.mint_scratch_id()
      assert String.length(id) == 43
      assert id =~ ~r/^[A-Za-z0-9_-]+$/
      refute String.contains?(id, "=")
      assert id != Exports.mint_scratch_id()
    end
  end

  describe "create_scratch_with_intent/2" do
    test "commits both the scratch and the intent row" do
      user = user_fixture()
      report_run = report_run_fixture(user)
      s_attrs = scratch_attrs(user, report_run)

      intent_attrs = %{
        event: "export_scoped",
        source: "api",
        data_type: "export_scoped",
        user_id: user.id,
        report_run_id: report_run.id,
        export_id: s_attrs.scratch_id,
        endpoint_set: ["re-1"]
      }

      assert {:ok, %{scratch: %ExportScratch{}, intent: %DataAccessLogEntry{}}} =
               Exports.create_scratch_with_intent(s_attrs, intent_attrs)

      assert Repo.aggregate(ExportScratch, :count) == 1
      assert Repo.aggregate(DataAccessLogEntry, :count) == 1
    end

    test "rolls back the scratch when the intent changeset is invalid" do
      user = user_fixture()
      report_run = report_run_fixture(user)
      s_attrs = scratch_attrs(user, report_run)

      bad_intent = %{
        event: "nope",
        source: "api",
        data_type: "export_scoped",
        user_id: user.id,
        report_run_id: report_run.id
      }

      assert {:error, :intent, _changeset, _} =
               Exports.create_scratch_with_intent(s_attrs, bad_intent)

      assert Repo.aggregate(ExportScratch, :count) == 0
      assert Repo.aggregate(DataAccessLogEntry, :count) == 0
    end
  end

  describe "fetch_for_page/4" do
    test "returns {:ok, scratch} with a bumped TTL for an active row" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      scratch =
        insert_scratch!(
          scratch_attrs(user, report_run, %{
            expires_at: DateTime.utc_now(:second) |> DateTime.add(60)
          })
        )

      assert {:ok, fetched} =
               Exports.fetch_for_page(scratch.scratch_id, user.id, report_run.id, "answers_bulk")

      assert DateTime.compare(fetched.expires_at, scratch.expires_at) == :gt
    end

    test "returns :not_found for wrong user, run, data_type or scratch_id" do
      user = user_fixture()
      other = user_fixture()
      report_run = report_run_fixture(user)
      scratch = insert_scratch!(scratch_attrs(user, report_run))

      assert :not_found =
               Exports.fetch_for_page(scratch.scratch_id, other.id, report_run.id, "answers_bulk")

      assert :not_found =
               Exports.fetch_for_page(
                 scratch.scratch_id,
                 user.id,
                 report_run.id + 1,
                 "answers_bulk"
               )

      assert :not_found =
               Exports.fetch_for_page(scratch.scratch_id, user.id, report_run.id, "history_bulk")

      assert :not_found = Exports.fetch_for_page("nope", user.id, report_run.id, "answers_bulk")
    end

    test "returns :expired and deletes the row for an expired scratch" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      scratch =
        insert_scratch!(
          scratch_attrs(user, report_run, %{
            expires_at: DateTime.utc_now(:second) |> DateTime.add(-60)
          })
        )

      assert :expired =
               Exports.fetch_for_page(scratch.scratch_id, user.id, report_run.id, "answers_bulk")

      assert :not_found =
               Exports.fetch_for_page(scratch.scratch_id, user.id, report_run.id, "answers_bulk")

      assert Repo.aggregate(ExportScratch, :count) == 0
    end

    test "bump is absolute — two rapid fetches converge, not stack" do
      user = user_fixture()
      report_run = report_run_fixture(user)
      scratch = insert_scratch!(scratch_attrs(user, report_run))

      {:ok, first} =
        Exports.fetch_for_page(scratch.scratch_id, user.id, report_run.id, "answers_bulk")

      {:ok, second} =
        Exports.fetch_for_page(scratch.scratch_id, user.id, report_run.id, "answers_bulk")

      assert DateTime.diff(second.expires_at, first.expires_at) <= 1
    end
  end

  describe "merge_touched_endpoints/2" do
    test "adds lti_tuple only to the matching endpoint, idempotent and persisted" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      scratch =
        insert_scratch!(
          scratch_attrs(user, report_run, %{
            endpoint_set: [
              %{"remote_endpoint" => "re-1", "source" => "s"},
              %{"remote_endpoint" => "re-2", "source" => "s"}
            ]
          })
        )

      tuple = %{"platform_id" => "p", "platform_user_id" => "u", "resource_link_id" => "r"}

      updated =
        Exports.merge_touched_endpoints(scratch, [
          %{"remote_endpoint" => "re-1", "lti_tuple" => tuple}
        ])

      assert Enum.find(updated.endpoint_set, &(&1["remote_endpoint"] == "re-1"))["lti_tuple"] ==
               tuple

      assert Enum.find(updated.endpoint_set, &(&1["remote_endpoint"] == "re-2"))["lti_tuple"] ==
               nil

      reloaded = Repo.get!(ExportScratch, scratch.id)

      assert Enum.find(reloaded.endpoint_set, &(&1["remote_endpoint"] == "re-1"))["lti_tuple"] ==
               tuple

      again =
        Exports.merge_touched_endpoints(updated, [
          %{"remote_endpoint" => "re-1", "lti_tuple" => tuple}
        ])

      assert again.endpoint_set == updated.endpoint_set
    end

    test "an empty touched list is a no-op" do
      user = user_fixture()
      report_run = report_run_fixture(user)
      scratch = insert_scratch!(scratch_attrs(user, report_run))

      assert Exports.merge_touched_endpoints(scratch, []) == scratch
      assert Exports.merge_touched_endpoints(scratch, nil) == scratch
    end
  end

  describe "sweep_expired/0" do
    test "deletes only expired rows and returns the count" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      insert_scratch!(
        scratch_attrs(user, report_run, %{
          expires_at: DateTime.utc_now(:second) |> DateTime.add(-60)
        })
      )

      insert_scratch!(
        scratch_attrs(user, report_run, %{
          expires_at: DateTime.utc_now(:second) |> DateTime.add(3600)
        })
      )

      assert Exports.sweep_expired() == 1
      assert Repo.aggregate(ExportScratch, :count) == 1
    end
  end

  describe "endpoint_set DB round-trip" do
    test "a non-trivial endpoint_set (list of maps with nested lti_tuple) loads back equal to what was written" do
      user = user_fixture()
      report_run = report_run_fixture(user)

      endpoint_set = [
        %{
          "remote_endpoint" => "re-1",
          "source" => "activity-player.concord.org",
          "lti_tuple" => %{
            "platform_id" => "p",
            "platform_user_id" => "u",
            "resource_link_id" => "r"
          }
        },
        %{"remote_endpoint" => "re-2", "source" => "example.com"}
      ]

      scratch = insert_scratch!(scratch_attrs(user, report_run, %{endpoint_set: endpoint_set}))

      assert Repo.get!(ExportScratch, scratch.id).endpoint_set == endpoint_set

      {:ok, fetched} =
        Exports.fetch_for_page(scratch.scratch_id, user.id, report_run.id, "answers_bulk")

      assert fetched.endpoint_set == endpoint_set
    end
  end
end
