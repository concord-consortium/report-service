defmodule ReportServer.ClueNoLearnersTest do
  @moduledoc """
  Guards the degenerate learner lists that reach the CLUE answers path.

  Both failures these pin are hard to reach through today's grouping, which
  builds a runnable group only from rows that exist, but neither is prevented by
  anything upstream and both fail badly rather than emptily: the year floor has
  no minimum to take, and the learner predicates interpolate as `IN ()`, which
  Athena rejects as a syntax error rather than returning no rows.

  Separate module rather than part of `ClueTest` because stubbing the `:athena_db`
  seam is global state, so this one cannot be `async: true`.
  """
  use ExUnit.Case, async: false

  import ReportServer.ClueFixtures

  alias ReportServer.Accounts.User
  alias ReportServer.Clue

  defmodule UnreachableAthenaDB do
    @moduledoc "Fails the test loudly if the query is sent at all."
    def query(_sql, _id, _user) do
      raise "Athena was queried for a runnable with no usable learner endpoints"
    end
  end

  setup do
    previous = Application.get_env(:report_server, :athena_db)
    Application.put_env(:report_server, :athena_db, UnreachableAthenaDB)

    on_exit(fn ->
      if previous do
        Application.put_env(:report_server, :athena_db, previous)
      else
        Application.delete_env(:report_server, :athena_db)
      end
    end)

    :ok
  end

  defp user, do: %User{id: 1, portal_server: portal_site()}

  describe "fetch_resource/3 with nothing to query" do
    test "returns the empty structure rather than querying, when no learner has an endpoint" do
      ## A learner with no run_remote_endpoint is dropped when the predicate is
      ## built, so a non-empty group can still reduce to no usable endpoints.
      learners =
        learners_fixture(2)
        |> Enum.map(&Map.put(&1, :run_remote_endpoint, nil))

      assert {:ok, resource} = Clue.fetch_resource(runnable_url(), learners, user())

      assert resource["type"] == "clue"
      assert resource["url"] == runnable_url()
      assert resource["denormalized"] == %{questions: %{}, choices: %{}, question_order: []}
    end

    test "returns the empty structure rather than querying, when the learner list is empty" do
      assert {:ok, resource} = Clue.fetch_resource(runnable_url(), [], user())

      assert resource["denormalized"] == %{questions: %{}, choices: %{}, question_order: []}
    end

    test "still names the activity from the runnable url" do
      ## The name is parsed from the URL rather than the data, so it survives
      ## having no learners and the column is labelled either way.
      assert {:ok, resource} = Clue.fetch_resource(runnable_url(), [], user())

      assert resource["name"] == "CLUE m2s: Problem 4.5"
    end
  end

  describe "answer_sql/1 with an empty learner list" do
    test "builds a string rather than raising on the year floor" do
      ## Enum.min/1 raises on an empty list, and the floor is derived from the
      ## learners' own created_at. fetch_resource/3 no longer reaches this, but
      ## answer_sql/1 is public and asserted on directly elsewhere.
      sql = Clue.answer_sql([])

      assert is_binary(sql)
      assert sql =~ ~r/"log"\."year" >= \d{4}/
    end
  end
end
