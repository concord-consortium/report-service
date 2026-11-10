defmodule ReportServer.Reports.HideNames do
  @moduledoc """
  Who may see learner names, and the enforcement that overrides a request that asks to.

  Lives outside the LiveView so every path that builds a report filter can apply it.

  A caller allowed names who also holds a researcher project sees them only for learners in classes
  reached through one of their admin projects, as the portal decides per class; that rule is applied
  where each query is built, from `AllowedProjects.admin_class_sql/2`.
  """

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.ReportFilter

  @doc "Only portal admins and project admins may see names."
  def allowed?(%User{portal_is_admin: true}), do: true
  def allowed?(%User{portal_is_project_admin: true}), do: true
  def allowed?(%User{}), do: false

  @doc "Forces hide_names on for anyone not allowed to see them, whatever the filter asked for."
  def enforce(report_filter = %ReportFilter{}, user = %User{}) do
    if allowed?(user) do
      report_filter
    else
      %{report_filter | hide_names: true}
    end
  end
end
