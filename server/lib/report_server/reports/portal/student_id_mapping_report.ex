defmodule ReportServer.Reports.Portal.StudentIdMappingReport do
  use ReportServer.Reports.Report, type: :portal

  alias ReportServer.Reports.LearnerBaseQuery

  def get_query(report_filter = %ReportFilter{}, user = %User{portal_server: portal_server}) do
    LearnerBaseQuery.build(report_filter, user, cols(portal_server),
      group_by: LearnerBaseQuery.group_by(), order_by: [{"learner_id", :asc}])
  end

  defp cols(portal_server) do
    [
      {"rl.learner_id", "learner_id"},
      {"rl.user_id", "user_id"},
      {"COALESCE(u.primary_account_id, u.id)", "primary_user_id"},
      {"rl.student_id", "student_id"},
      {"rl.class_id", "class_id"},
      {"rl.offering_id", "offering_id"},
      {"ea.url", "runnable_url"},
      {LearnerBaseQuery.run_remote_endpoint_sql(portal_server), "run_remote_endpoint"}
    ]
  end
end
