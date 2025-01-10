defmodule ReportServer.ReportFilterQueryTest do
  use ExUnit.Case, async: true
  alias ReportServer.Reports.{ReportFilter, ReportFilterQuery}

  describe "permission forms" do

    test "basic permission forms query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:permission_form]
          # cohort: [1],
          # school: [2],
          # teacher: [3],
          # assignment: [4]
        },
        :all,
        "abc")
      assert query ==
        %ReportFilterQuery{
          id: "ppf.id",
          value: "CONCAT(ap.name, ': ', ppf.name)",
          from: "portal_permission_forms ppf JOIN admin_projects ap ON ap.id = ppf.project_id",
          join: [],
          where: ["ppf.name LIKE ? or ap.name LIKE ?"],
          order_by: "ppf.name",
          num_params: 2
        }

      assert params == ["%abc%", "%abc%"]

      normalized = ReportFilterQuery.get_options_sql(query)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

      assert normalized ==
        "SELECT DISTINCT ppf.id, CONCAT(ap.name, ': ', ppf.name) FROM portal_permission_forms ppf JOIN admin_projects ap ON ap.id = ppf.project_id WHERE (ppf.name LIKE ? or ap.name LIKE ?) ORDER BY ppf.name"
    end

    test "fancy permission forms query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:permission_form],
          cohort: [1],
          school: [2],
          teacher: [3],
          assignment: [4]
        },
        :all,
        "abc")
      assert query ==
        %ReportFilterQuery{
          id: "ppf.id",
          value: "CONCAT(ap.name, ': ', ppf.name)",
          from: "portal_permission_forms ppf JOIN admin_projects ap ON ap.id = ppf.project_id",
          join: [
            ["JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id", "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id", "JOIN portal_offerings po ON (po.clazz_id = psc.clazz_id AND po.runnable_type = 'ExternalActivity')"],
            ["JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id", "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id", "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)"],
            ["JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id", "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id", "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)", "JOIN portal_school_memberships psm ON (psm.member_id = ptc.teacher_id AND psm.member_type = 'Portal::Teacher')"],
            ["JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id", "JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id", "JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id)", "JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id)"],
          ],
          where: [
            "po.runnable_id IN (4)",
            "ptc.teacher_id IN (3)",
            "psm.school_id IN (2)",
            "aci.admin_cohort_id IN (1)",
            "ppf.name LIKE ? or ap.name LIKE ?"
          ],
          order_by: "ppf.name",
          num_params: 2
        }

      assert params == ["%abc%", "%abc%"]

      normalized = ReportFilterQuery.get_options_sql(query)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

      assert normalized ==
        "SELECT DISTINCT ppf.id, CONCAT(ap.name, ': ', ppf.name) FROM portal_permission_forms ppf JOIN admin_projects ap ON ap.id = ppf.project_id JOIN portal_student_permission_forms pspf ON pspf.portal_permission_form_id = ppf.id JOIN portal_student_clazzes psc ON psc.student_id = pspf.portal_student_id JOIN portal_teacher_clazzes ptc ON (ptc.clazz_id = psc.clazz_id) JOIN admin_cohort_items aci ON (aci.item_type = 'Portal::Teacher' AND aci.item_id = ptc.teacher_id) JOIN portal_school_memberships psm ON (psm.member_id = ptc.teacher_id AND psm.member_type = 'Portal::Teacher') JOIN portal_offerings po ON (po.clazz_id = psc.clazz_id AND po.runnable_type = 'ExternalActivity') WHERE (ppf.name LIKE ? or ap.name LIKE ?) AND (aci.admin_cohort_id IN (1)) AND (psm.school_id IN (2)) AND (ptc.teacher_id IN (3)) AND (po.runnable_id IN (4)) ORDER BY ppf.name"
    end
  end

end
