defmodule ReportServer.Reports.CohortFilter do
  @moduledoc """
  The activity side of the cohort filter: a selected cohort admits an activity that is one of its
  `ExternalActivity` items or one of its project's `ExternalActivity` materials, the two ways
  project scoping accepts an activity. The teacher side, a teacher who is an item of a selected
  cohort, is each report's own join.

  Both subqueries are uncorrelated, so MySQL materializes each once. A correlated `EXISTS` would
  run once for every row the teacher side admits.
  """

  import ReportServer.Reports.ReportUtils, only: [list_to_in: 1]

  @doc "SQL that is true when the activity `activity_ref` names is admitted by one of `cohort_ids`."
  def activity_in_cohorts(activity_ref, cohort_ids) do
    ids = list_to_in(cohort_ids)

    "(#{activity_ref} IN (SELECT aci_cf.item_id FROM admin_cohort_items aci_cf " <>
      "WHERE aci_cf.item_type = 'ExternalActivity' AND aci_cf.admin_cohort_id IN #{ids}) " <>
      "OR #{activity_ref} IN (SELECT apm_cf.material_id FROM admin_project_materials apm_cf " <>
      "JOIN admin_cohorts ac_cf ON (ac_cf.project_id = apm_cf.project_id) " <>
      "WHERE apm_cf.material_type = 'ExternalActivity' AND ac_cf.id IN #{ids}))"
  end

  @doc """
  SQL that is true when the `admin_cohorts` row aliased `cohorts` admits one of `activity_ids`,
  the same rule as `activity_in_cohorts/2` read from the cohort's side.
  """
  def cohort_admits_activities(cohorts, activity_ids) do
    ids = list_to_in(activity_ids)

    "(#{cohorts}.id IN (SELECT aci_cf.admin_cohort_id FROM admin_cohort_items aci_cf " <>
      "WHERE aci_cf.item_type = 'ExternalActivity' AND aci_cf.item_id IN #{ids}) " <>
      "OR #{cohorts}.project_id IN (SELECT apm_cf.project_id FROM admin_project_materials apm_cf " <>
      "WHERE apm_cf.material_type = 'ExternalActivity' AND apm_cf.material_id IN #{ids}))"
  end
end
