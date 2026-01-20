defmodule ReportServer.ReportFilterQueryTest do
  use ExUnit.Case, async: true
  alias ReportServer.Reports.{ReportFilter, ReportFilterQuery}

  describe "cohorts" do
    test "basic cohort query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:cohort]
        },
        :all,
        "test",
        "portal.example.com")
      assert query ==
        %ReportFilterQuery{
          id: "admin_cohorts.id",
          value: "admin_cohorts.name",
          from: "admin_cohorts",
          join: [],
          where: ["admin_cohorts.name LIKE ?"],
          order_by: "admin_cohorts.name",
          num_params: 1
        }

      assert params == ["%test%"]

      normalized = ReportFilterQuery.get_options_sql(query)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

      assert normalized ==
        "SELECT DISTINCT admin_cohorts.id, admin_cohorts.name FROM admin_cohorts WHERE (admin_cohorts.name LIKE ?) ORDER BY admin_cohorts.name"
    end

    test "cohort query with allowed project ids" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:cohort]
        },
        [1, 2, 3],
        "",
        "portal.example.com")
      assert query ==
        %ReportFilterQuery{
          id: "admin_cohorts.id",
          value: "admin_cohorts.name",
          from: "admin_cohorts",
          join: [],
          where: ["admin_cohorts.project_id IN (1,2,3)"],
          order_by: "admin_cohorts.name",
          num_params: 1
        }

      assert params == []
    end

    test "cohort query with secondary filters" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:cohort],
          school: [5],
          teacher: [10],
          assignment: [20],
          permission_form: [30],
          class: [40],
          student: [50]
        },
        :all,
        "",
        "portal.example.com")

      assert query.id == "admin_cohorts.id"
      assert query.value == "admin_cohorts.name"
      assert length(query.join) == 6
      assert length(query.where) == 6
      assert params == []
    end

    test "cohort query returns nil for empty filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:cohort],
          school: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
      assert params == []
    end
  end

  describe "schools" do
    test "basic school query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:school]
        },
        :all,
        "test",
        "portal.example.com")
      assert query ==
        %ReportFilterQuery{
          id: "portal_schools.id",
          value: "portal_schools.name",
          from: "portal_schools",
          join: [],
          where: ["portal_schools.name LIKE ?"],
          order_by: "portal_schools.name",
          num_params: 1
        }

      assert params == ["%test%"]
    end

    test "school query with allowed project ids" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:school]
        },
        [1, 2],
        "",
        "portal.example.com")

      assert query.id == "portal_schools.id"
      assert length(query.join) == 1
      assert Enum.any?(query.where, &String.contains?(&1, "ac.project_id IN"))
      assert params == []
    end

    test "school query with secondary filters" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:school],
          cohort: [1],
          teacher: [2],
          assignment: [3],
          permission_form: [4],
          class: [5],
          student: [6]
        },
        :all,
        "",
        "portal.example.com")

      assert query.id == "portal_schools.id"
      assert length(query.join) == 6
      assert length(query.where) == 6
      assert params == []
    end

    test "school query returns nil for empty filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:school],
          teacher: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
      assert params == []
    end
  end

  describe "teachers" do
    test "basic teacher query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:teacher]
        },
        :all,
        "smith",
        "portal.example.com")
      assert query ==
        %ReportFilterQuery{
          id: "portal_teachers.id",
          value: "CONCAT(u.first_name, ' ', u.last_name, ' <', u.email, '>') AS fullname",
          from: "portal_teachers",
          join: ["JOIN users u ON u.id = portal_teachers.user_id"],
          where: ["CONCAT(u.first_name, ' ', u.last_name, ' <', u.email, '>') LIKE ?"],
          order_by: "fullname",
          num_params: 1
        }

      assert params == ["%smith%"]
    end

    test "teacher query with exclude_internal" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:teacher],
          exclude_internal: true
        },
        :all,
        "",
        "portal.concord.org")

      # exclude_internal may or may not add a where clause depending on
      # whether internal teacher IDs are found for the portal server
      # Just verify the query structure is valid
      assert query.id == "portal_teachers.id"
      assert query.order_by == "fullname"
      assert params == []
    end

    test "teacher query with allowed project ids" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:teacher]
        },
        [10, 20],
        "",
        "portal.example.com")

      assert query.id == "portal_teachers.id"
      assert length(query.join) > 1
      assert Enum.any?(query.where, &String.contains?(&1, "ac.project_id IN"))
      assert params == []
    end

    test "teacher query with secondary filters" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:teacher],
          cohort: [1],
          school: [2],
          assignment: [3],
          permission_form: [4],
          class: [5],
          student: [6]
        },
        :all,
        "",
        "portal.example.com")

      assert query.id == "portal_teachers.id"
      assert length(query.join) == 7  # base join + 6 secondary filters
      assert length(query.where) == 6
      assert params == []
    end

    test "teacher query returns nil for empty filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:teacher],
          cohort: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
      assert params == []
    end
  end

  describe "assignments" do
    test "basic assignment query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:assignment]
        },
        :all,
        "activity",
        "portal.example.com")
      assert query ==
        %ReportFilterQuery{
          id: "external_activities.id",
          value: "external_activities.name",
          from: "external_activities",
          join: [],
          where: ["external_activities.name LIKE ?"],
          order_by: "external_activities.name",
          num_params: 1
        }

      assert params == ["%activity%"]
    end

    test "assignment query with allowed project ids uses LEFT JOIN" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:assignment]
        },
        [1, 2],
        "",
        "portal.example.com")

      assert query.id == "external_activities.id"
      # Should have LEFT JOIN for allowed projects
      join_sql = query.join |> List.flatten() |> Enum.join(" ")
      assert String.contains?(join_sql, "LEFT JOIN")
      assert Enum.any?(query.where, fn w ->
        String.contains?(w, "ac.project_id IN") || String.contains?(w, "apm.project_id IN")
      end)
      assert params == []
    end

    test "assignment query with secondary filters" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:assignment],
          cohort: [1],
          school: [2],
          teacher: [3],
          permission_form: [4],
          class: [5],
          student: [6]
        },
        :all,
        "",
        "portal.example.com")

      assert query.id == "external_activities.id"
      assert length(query.join) == 6
      assert length(query.where) == 6
      assert params == []
    end

    test "assignment query returns nil for empty filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:assignment],
          school: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
      assert params == []
    end
  end

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
        "abc",
        "portal.example.com")
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
        "abc",
        "portal.example.com")
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

    test "permission form query returns nil for empty filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:permission_form],
          cohort: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
      assert params == []
    end
  end

  describe "classes" do
    test "basic class query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:class]
        },
        :all,
        "period",
        "portal.example.com")
      assert query ==
        %ReportFilterQuery{
          id: "pc.id",
          value: "CONCAT(pc.name, ' (', pc.class_word, ')') AS fullname",
          from: "portal_clazzes pc",
          join: [],
          where: ["pc.name LIKE ? OR pc.class_word LIKE ?"],
          order_by: "fullname",
          num_params: 2
        }

      assert params == ["%period%", "%period%"]

      normalized = ReportFilterQuery.get_options_sql(query)
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

      assert normalized ==
        "SELECT DISTINCT pc.id, CONCAT(pc.name, ' (', pc.class_word, ')') AS fullname FROM portal_clazzes pc WHERE (pc.name LIKE ? OR pc.class_word LIKE ?) ORDER BY fullname"
    end

    test "class query with allowed project ids" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:class]
        },
        [5, 6],
        "",
        "portal.example.com")

      assert query.id == "pc.id"
      assert length(query.join) == 1
      assert Enum.any?(query.where, &String.contains?(&1, "ac.project_id IN"))
      assert params == []
    end

    test "class query with secondary filters" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:class],
          cohort: [1],
          school: [2],
          teacher: [3],
          assignment: [4],
          permission_form: [5],
          student: [6]
        },
        :all,
        "",
        "portal.example.com")

      assert query.id == "pc.id"
      assert length(query.join) == 6
      assert length(query.where) == 6
      assert params == []
    end

    test "class query returns nil for empty filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:class],
          teacher: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
      assert params == []
    end
  end

  describe "students" do
    test "basic student query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:student]
        },
        :all,
        "jones",
        "portal.example.com")
      assert query ==
        %ReportFilterQuery{
          id: "ps.id",
          value: "CONCAT(u.first_name, ' ', u.last_name, ' <', u.id, '>') AS fullname",
          from: "portal_students ps JOIN users u ON u.id = ps.user_id",
          join: [],
          where: ["CONCAT(u.first_name, ' ', u.last_name, ' <', u.id, '>') LIKE ?"],
          order_by: "fullname",
          num_params: 1
        }

      assert params == ["%jones%"]
    end

    test "student query with hide_names true" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:student],
          hide_names: true
        },
        :all,
        "123",
        "portal.example.com")

      assert query.id == "ps.id"
      assert query.value == "CAST(u.id AS CHAR) AS fullname"
      assert query.where == ["CAST(u.id AS CHAR) LIKE ?"]
      assert params == ["%123%"]
    end

    test "student query with hide_names false" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:student],
          hide_names: false
        },
        :all,
        "test",
        "portal.example.com")

      assert query.id == "ps.id"
      assert String.contains?(query.value, "CONCAT")
      assert params == ["%test%"]
    end

    test "student query with allowed project ids" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:student]
        },
        [7, 8],
        "",
        "portal.example.com")

      assert query.id == "ps.id"
      assert length(query.join) == 1
      assert Enum.any?(query.where, &String.contains?(&1, "ac.project_id IN"))
      assert params == []
    end

    test "student query with secondary filters" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:student],
          cohort: [1],
          school: [2],
          teacher: [3],
          assignment: [4],
          permission_form: [5],
          class: [6]
        },
        :all,
        "",
        "portal.example.com")

      assert query.id == "ps.id"
      assert length(query.join) == 6
      assert length(query.where) == 6
      assert params == []
    end

    test "student query returns nil for empty filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:student],
          class: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
      assert params == []
    end
  end

  describe "edge cases" do
    test "empty filters list returns nil query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
      assert params == []
    end

    test "allowed_project_ids :none returns nil query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:school]
        },
        :none,
        "",
        "portal.example.com")

      assert query == nil
      assert params == []
    end

    test "empty like_text returns empty params" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:cohort]
        },
        :all,
        "",
        "portal.example.com")

      assert query.where == []
      assert params == []
    end

    test "like_text is properly escaped in params" do
      {_query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:school]
        },
        :all,
        "test%value",
        "portal.example.com")

      assert params == ["%test%value%"]
    end

    test "multiple like params for class filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:class]
        },
        :all,
        "period",
        "portal.example.com")

      assert query.num_params == 2
      assert params == ["%period%", "%period%"]
    end

    test "multiple like params for permission_form filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:permission_form]
        },
        :all,
        "consent",
        "portal.example.com")

      assert query.num_params == 2
      assert params == ["%consent%", "%consent%"]
    end
  end

  describe "helper functions" do
    # Note: Helper functions are private, so we test them indirectly through get_query_and_params

    test "has_empty_dependent_filters? works for cohort with empty school" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:cohort],
          school: []
        },
        :all,
        "",
        "portal.example.com")

      # Should return nil when dependent filter is empty
      assert query == nil
    end

    test "has_empty_dependent_filters? works for school with empty teacher" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:school],
          teacher: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end

    test "has_empty_dependent_filters? works for teacher with empty cohort" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:teacher],
          cohort: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end

    test "has_empty_dependent_filters? works for assignment with empty school" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:assignment],
          school: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end

    test "has_empty_dependent_filters? works for permission_form with empty cohort" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:permission_form],
          cohort: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end

    test "has_empty_dependent_filters? works for class with empty teacher" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:class],
          teacher: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end

    test "has_empty_dependent_filters? works for student with empty class" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:student],
          class: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end

    test "build_base_query creates correct structure for cohort" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:cohort]
        },
        :all,
        "",
        "portal.example.com")

      # Verify base query structure was created correctly
      assert query.id == "admin_cohorts.id"
      assert query.value == "admin_cohorts.name"
      assert query.from == "admin_cohorts"
      assert query.order_by == "admin_cohorts.name"
      assert query.num_params == 1
    end

    test "build_base_query creates correct structure for school" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:school]
        },
        :all,
        "",
        "portal.example.com")

      assert query.id == "portal_schools.id"
      assert query.value == "portal_schools.name"
      assert query.from == "portal_schools"
      assert query.order_by == "portal_schools.name"
    end

    test "build_base_query handles initial joins for teacher" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:teacher]
        },
        :all,
        "",
        "portal.example.com")

      # Teacher filter should have initial join to users table
      assert Enum.any?(query.join, fn join ->
        is_binary(join) && String.contains?(join, "JOIN users u")
      end)
    end

    test "build_base_query handles compound values for permission_form" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:permission_form]
        },
        :all,
        "",
        "portal.example.com")

      assert query.value == "CONCAT(ap.name, ': ', ppf.name)"
      assert query.num_params == 2
    end

    test "build_base_query handles compound values for class" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:class]
        },
        :all,
        "",
        "portal.example.com")

      assert query.value == "CONCAT(pc.name, ' (', pc.class_word, ')') AS fullname"
      assert query.num_params == 2
    end

    test "build_base_query handles hide_names parameter for student" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:student],
          hide_names: true
        },
        :all,
        "",
        "portal.example.com")

      # When hide_names is true, value should be the ID cast as char
      assert query.value == "CAST(u.id AS CHAR) AS fullname"
    end

    test "build_base_query handles hide_names false for student" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:student],
          hide_names: false
        },
        :all,
        "",
        "portal.example.com")

      # When hide_names is false, value should include name concatenation
      assert String.contains?(query.value, "CONCAT")
      assert String.contains?(query.value, "first_name")
    end

    test "empty filter check does not trigger when all filters are nil" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:cohort],
          school: nil,
          teacher: nil,
          assignment: nil,
          permission_form: nil,
          class: nil,
          student: nil
        },
        :all,
        "",
        "portal.example.com")

      # Should not be nil when all dependent filters are nil (not empty lists)
      assert query != nil
      assert query.id == "admin_cohorts.id"
    end

    test "empty filter check triggers when any filter is empty list" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:cohort],
          school: nil,
          teacher: nil,
          assignment: [],  # This empty list should trigger nil
          permission_form: nil,
          class: nil,
          student: nil
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end

    test "multiple empty filters still result in nil query" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:school],
          cohort: [],
          teacher: [],
          assignment: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end
  end

  describe "countries" do
    test "basic country query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:country]
        },
        :all,
        "United",
        "portal.example.com")

      assert query.id == "portal_countries.id"
      assert query.value == "COALESCE(portal_countries.name, '(Unknown)') AS country_name"
      assert query.from == "portal_countries"
      assert query.where == ["portal_countries.name LIKE ?"]
      assert query.order_by == "country_name"
      assert params == ["%United%"]
    end

    test "country query with state filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:country],
          state: ["CA", "NY"]
        },
        :all,
        "",
        "portal.example.com")

      assert query.id == "portal_countries.id"
      assert length(query.join) > 0
      assert length(query.where) == 1
      assert Enum.at(query.where, 0) =~ "ps_country.state IN"
      assert params == []
    end

    test "country query with school filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:country],
          school: [10, 20]
        },
        :all,
        "",
        "portal.example.com")

      assert length(query.join) > 0
      assert length(query.where) == 1
    end

    test "country query with teacher filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:country],
          teacher: [5]
        },
        :all,
        "",
        "portal.example.com")

      assert length(query.join) > 0
      assert length(query.where) == 1
    end

    test "country query with subject_area filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:country],
          subject_area: [1, 2]
        },
        :all,
        "",
        "portal.example.com")

      assert length(query.join) > 0
      assert length(query.where) == 1
    end

    test "country query returns nil for empty dependent filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:country],
          state: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end
  end

  describe "states" do
    test "basic state query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:state]
        },
        :all,
        "CA",
        "portal.example.com")

      assert query.id == "COALESCE(portal_schools.state, '(Unknown)') AS state_code"
      assert query.value == "COALESCE(portal_schools.state, '(Unknown)') AS state_name"
      assert query.from == "portal_schools"
      assert query.where == ["portal_schools.state LIKE ?"]
      assert query.order_by == "state_name"
      assert params == ["%CA%"]
    end

    test "state query with country filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:state],
          country: [1, 2]
        },
        :all,
        "",
        "portal.example.com")

      assert query.id == "COALESCE(portal_schools.state, '(Unknown)') AS state_code"
      assert length(query.where) == 1
      assert Enum.at(query.where, 0) =~ "portal_schools.country_id IN"
      assert params == []
    end

    test "state query with school filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:state],
          school: [10]
        },
        :all,
        "",
        "portal.example.com")

      assert length(query.where) == 1
    end

    test "state query with teacher filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:state],
          teacher: [5, 6]
        },
        :all,
        "",
        "portal.example.com")

      assert length(query.join) > 0
      assert length(query.where) == 1
    end

    test "state query with subject_area filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:state],
          subject_area: [3]
        },
        :all,
        "",
        "portal.example.com")

      assert length(query.join) > 0
      assert length(query.where) == 1
    end

    test "state query returns nil for empty dependent filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:state],
          school: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end
  end

  describe "subject_areas" do
    test "basic subject_area query" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:subject_area]
        },
        :all,
        "Math",
        "portal.example.com")

      assert query.id == "admin_tags.id"
      assert query.value == "admin_tags.tag"
      assert query.from == "admin_tags"
      assert query.where == ["admin_tags.tag LIKE ?", "admin_tags.scope = 'subject_areas'"]
      assert query.order_by == "admin_tags.tag"
      assert params == ["%Math%"]
    end

    test "subject_area query with country filter" do
      {query, params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:subject_area],
          country: [1]
        },
        :all,
        "",
        "portal.example.com")

      assert query.id == "admin_tags.id"
      assert length(query.join) > 0
      assert length(query.where) == 2  # scope + country filter
      assert Enum.any?(query.where, fn w -> w =~ "ps.country_id IN" end)
      assert Enum.any?(query.where, fn w -> w =~ "admin_tags.scope" end)
      assert params == []
    end

    test "subject_area query with state filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:subject_area],
          state: ["CA", "NY"]
        },
        :all,
        "",
        "portal.example.com")

      assert length(query.join) > 0
      assert length(query.where) == 2  # scope + state filter
      assert Enum.any?(query.where, fn w -> w =~ "ps.state IN" end)
      assert Enum.any?(query.where, fn w -> w =~ "admin_tags.scope" end)
    end

    test "subject_area query with school filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:subject_area],
          school: [10, 20]
        },
        :all,
        "",
        "portal.example.com")

      assert length(query.join) > 0
      assert length(query.where) == 2  # scope + school filter
      assert Enum.any?(query.where, fn w -> w =~ "admin_tags.scope" end)
    end

    test "subject_area query with teacher filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:subject_area],
          teacher: [5]
        },
        :all,
        "",
        "portal.example.com")

      assert length(query.join) > 0
      assert length(query.where) == 2  # scope + teacher filter
      assert Enum.any?(query.where, fn w -> w =~ "admin_tags.scope" end)
    end

    test "subject_area query returns nil for empty dependent filter" do
      {query, _params} = ReportFilterQuery.get_query_and_params(
        %ReportFilter{
          filters: [:subject_area],
          teacher: []
        },
        :all,
        "",
        "portal.example.com")

      assert query == nil
    end
  end

end
