defmodule ReportServer.Reports.AllowedProjects do
  @moduledoc """
  The projects a portal user holds a live project role on: `admin`, the projects they administer,
  and `researcher`, the ones they research and do not also administer. At least one list is
  non-empty; `PortalDbs.get_allowed_project_ids/2` answers `:none` for a user with neither.

  A project admin sees a project's students through its cohort classes; a project researcher sees
  only those of them holding one of that project's permission forms, as rigse's
  `Report::LearnerPolicy` does. Scopes that reach no students use `ids/1`.
  """
  @enforce_keys [:admin, :researcher]
  defstruct [:admin, :researcher]

  def ids(%__MODULE__{admin: admin, researcher: researcher}), do: admin ++ researcher
end
