defmodule ReportServer.Reports.Athena.SharedQueriesCompletionTest do
  @moduledoc """
  Pins the completion-counter columns on the shared answers path.

  The percentage divides the answer count by the question count, and Presto
  returns NaN for `0.0/0` rather than erroring. Reported verbatim that puts the
  literal string "NaN" into a column that is an empty string everywhere else, so
  anything reading it as numeric hits an unexpected token in a few scattered
  rows rather than failing outright.

  A zero question count is reachable whenever a resource yields no question
  structure for a learner who is nonetheless enrolled on it.
  """
  use ExUnit.Case, async: true

  alias ReportServer.Reports.Athena.SharedQueries
  alias ReportServer.Reports.ReportFilter

  @auth_domain "https://learn.concord.org"

  ## A resource with no question structure is the case that produces the zero
  ## denominator, so the fixture is the failing shape rather than a happy one.
  defp resource_sql(report_type \\ :answers) do
    resource_data = [
      %{
        runnable_url: "https://activity-player.concord.org/branch/master?activity=1",
        query_id: "q1",
        resource: nil,
        denormalized: %{questions: %{}, choices: %{}, question_order: []}
      }
    ]

    {:ok, query} =
      SharedQueries.generate_resource_sql(
        report_type,
        %ReportFilter{hide_names: false},
        resource_data,
        @auth_domain
      )

    query.raw_sql
  end

  describe "total_percent_complete" do
    test "guards the zero denominator so an empty resource yields NULL, not NaN" do
      sql = resource_sql()

      assert sql =~ "res_1_total_percent_complete"

      assert sql =~ ~r/round\(100\.0 \* learners_and_answers_1\.num_answers \/ nullif\(activities_1\.num_questions, 0\), 1\)/,
             "the percentage must divide by nullif(num_questions, 0)"
    end

    test "never divides by a bare num_questions" do
      ## The regression this guards: reverting the nullif restores NaN silently,
      ## because nothing errors and the column still populates for every learner
      ## who does have questions.
      sql = resource_sql()

      refute sql =~ ~r/num_answers \/ activities_1\.num_questions/,
             "an unguarded division reintroduces the literal string NaN"
    end

    test "leaves the numerator and the rounding alone" do
      ## Existing non-zero percentages must be unchanged, including their one
      ## decimal place, so this is a fix rather than a recalculation.
      sql = resource_sql()

      assert sql =~ "100.0 * learners_and_answers_1.num_answers"
      assert sql =~ ", 1)"
    end

    test "the raw counter columns are untouched" do
      sql = resource_sql()

      assert sql =~ "res_1_total_num_questions"
      assert sql =~ "res_1_total_num_answers"
      refute sql =~ ~r/res_1_total_num_questions[^,]*nullif/
    end
  end
end
