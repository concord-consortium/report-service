defmodule ReportServer.Reports.Athena.StudentActionsReport do
  use ReportServer.Reports.Report, type: :athena

  alias ReportServer.Reports.Athena.LearnerData

  def get_query(report_filter = %ReportFilter{}, user = %User{}) do
    hide_names = report_filter.hide_names
    learner_cols = ReportQuery.get_minimal_learner_cols(hide_names: hide_names)
    with {:ok, learner_data} <- LearnerData.fetch_and_upload(report_filter, user),
    {:ok, query} <- ReportQuery.get_athena_query(report_filter, learner_data, learner_cols) do
      {:ok, query}
    else
      error -> error
    end
  end

end
