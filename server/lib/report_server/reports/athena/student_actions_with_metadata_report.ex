defmodule ReportServer.Reports.Athena.StudentActionsWithMetadataReport do
  require Logger

  use ReportServer.Reports.Report, type: :athena

  alias ReportServer.Reports.Athena.LearnerData

  def get_query(report_filter = %ReportFilter{}, user = %User{}) do
    with {:ok, learner_data} <- LearnerData.fetch_and_upload(report_filter, user),
         {:ok, query} <- get_athena_query(report_filter, learner_data) do
      {:ok, query}
    else
      error -> error
    end
  end

  defp get_athena_query(report_filter = %ReportFilter{}, learner_data) do
    query_ids = learner_data |> Enum.map(&(&1.query_id))

    if !Enum.empty?(query_ids) do
      hide_names = report_filter.hide_names

      log_cols = ReportQuery.get_log_cols(hide_names: hide_names, remove_username: true)
      learner_cols = ReportQuery.get_learner_cols(hide_names: hide_names)
      cols = List.flatten([log_cols | learner_cols])

      from = "\"#{ReportQuery.get_log_db_name()}\".\"logs_by_time\" log"

      join = [
        """
        INNER JOIN "report-service"."learners" learner
        ON
          (
            learner.query_id IN #{string_list_to_single_quoted_in(query_ids)}
            AND
            learner.run_remote_endpoint = log.run_remote_endpoint
          )
        """
      ]

      {:ok, %ReportQuery{cols: cols, from: from, join: join }}
    else
      {:error, "No learners were found matching the filters you selected."}
    end
  end
end
