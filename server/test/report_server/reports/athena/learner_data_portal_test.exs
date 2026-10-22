defmodule ReportServer.Reports.Athena.LearnerDataPortalTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.Accounts.User
  alias ReportServer.PortalFixture
  alias ReportServer.Reports.Athena.LearnerData
  alias ReportServer.Reports.ReportFilter

  defp admin, do: %User{portal_server: PortalFixture.server(), portal_is_admin: true}

  test "a learner whose teacher and permission form id lists are NULL is fetched" do
    filter = %ReportFilter{filters: [:class], class: [602]}

    assert {:ok, groups} = LearnerData.fetch(filter, admin())

    learners = Enum.flat_map(groups, & &1.learners)
    assert %{user_id: 102} = Enum.find(learners, &(&1.learner_id == 904))
  end
end
