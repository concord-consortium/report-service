defmodule ReportServer.Reports.Athena.StudentAnswersReport do
  use ReportServer.Reports.Report, type: :athena

  alias ReportServer.Reports.Athena.{LearnerData, ResourceData, SharedQueries}

  def get_query(report_filter = %ReportFilter{}, user = %User{portal_server: portal_server}) do
    with {:ok, learner_data} <- LearnerData.fetch_and_upload(report_filter, user),
         {:ok, resource_data} <- ResourceData.fetch_and_upload(learner_data, user),
         {:ok, query} <- SharedQueries.get_usage_or_answers_athena_query(:answers, report_filter, resource_data, portal_server) do
      {:ok, query}
    else
      error -> error
    end
  end
end
