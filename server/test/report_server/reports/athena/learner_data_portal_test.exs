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

  describe "permission_forms for a caller with a researcher project" do
    @filter %ReportFilter{filters: [:class], class: [601, 602, 604]}

    defp user(id, flags), do: struct(%User{portal_server: PortalFixture.server(), portal_user_id: id}, flags)
    defp mixed, do: user(562, portal_is_project_admin: true, portal_is_project_researcher: true)

    defp learners(user) do
      {:ok, groups} = LearnerData.fetch(@filter, user, allow_empty: true)
      groups |> Enum.flat_map(& &1.learners) |> Map.new(&{&1.learner_id, &1})
    end

    test "a researcher's list keeps only their projects' forms" do
      assert learners(user(563, portal_is_project_researcher: true))[905].permission_forms == ["Proj C: Form C"]
    end

    test "a user with both roles keeps every form in an admin-project class only" do
      by_learner = learners(mixed())

      assert by_learner[901].permission_forms == ["Proj A: Form 1", "Proj B: Form 2"]
      assert by_learner[905].permission_forms == ["Proj C: Form C"]
      assert by_learner[901].in_admin_class == 1
      assert by_learner[905].in_admin_class == 0
    end

    test "a project admin's list is unchanged" do
      assert learners(user(555, portal_is_project_admin: true))[901].permission_forms ==
               ["Proj A: Form 1", "Proj B: Form 2"]
    end

    test "the upload leaves the admin-class flag out" do
      previous = Application.get_env(:report_server, :athena_db)
      Application.put_env(:report_server, :athena_db, ReportServer.AthenaDBStub)
      test_pid = self()

      {:ok, stub} =
        ReportServer.AthenaDBStub.start(%{
          put_file_contents: fn _path, contents ->
            send(test_pid, {:uploaded, contents})
            {:ok, nil, nil}
          end
        })

      on_exit(fn ->
        if previous, do: Application.put_env(:report_server, :athena_db, previous), else: Application.delete_env(:report_server, :athena_db)
      end)

      {:ok, groups} = LearnerData.fetch(@filter, mixed(), allow_empty: true)
      assert {:ok, _} = LearnerData.upload(groups)
      Agent.stop(stub)

      assert_received {:uploaded, contents}
      learner = contents |> String.split("\n") |> hd() |> Jason.decode!()

      assert Map.has_key?(learner, "permission_forms")
      refute Map.has_key?(learner, "in_admin_class")
    end
  end

  describe "names for a user with both roles" do
    @salt "pinned.salt"

    setup do
      athena = Application.get_env(:report_server, :athena, [])
      Application.put_env(:report_server, :athena, Keyword.put(athena, :hide_username_hash_salt, @salt))
      on_exit(fn -> Application.put_env(:report_server, :athena, athena) end)
    end

    defp mixed_learners(hide_names) do
      {:ok, groups} = LearnerData.fetch(%{@filter | hide_names: hide_names}, mixed(), allow_empty: true)
      groups |> Enum.flat_map(& &1.learners) |> Map.new(&{&1.learner_id, &1})
    end

    test "a learner outside an admin-project class carries the values hide_names gives" do
      by_learner = mixed_learners(false)

      assert {by_learner[901].student_name, by_learner[901].username} == {"Stu One", "stu.one"}
      assert by_learner[905].student_name == "76"
      assert by_learner[905].username == Base.encode16(:crypto.hash(:sha, @salt <> "stu.six"))
    end

    test "with hide_names on the username is left for Athena to hash" do
      assert mixed_learners(true)[905].username == "stu.six"
    end

    test "a NULL username stays nil" do
      server = PortalFixture.server()
      {:ok, _} = ReportServer.PortalDbs.query(server, "UPDATE report_learners SET username = NULL WHERE learner_id = 905")
      on_exit(fn -> ReportServer.PortalDbs.query(server, "UPDATE report_learners SET username = 'stu.six' WHERE learner_id = 905") end)

      assert mixed_learners(false)[905].username == nil
    end
  end
end
