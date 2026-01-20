defmodule ReportServer.Reports.Tree do
  alias ReportServer.Reports
  alias ReportServer.Reports.{
    Report,
    # TBDReport
  }
  alias ReportServer.Reports.Portal.{
    TeacherStatusReport,
    ResourceMetricsSummaryReport,
    ResourceMetricsDetailsReport,
    DetailedMetricsBySchoolReport,
    SummaryMetricsBySubjectAreaReport
  }
  alias ReportServer.Reports.Athena.{
    StudentActionsReport,
    StudentActionsWithMetadataReport,
    TeacherActionsReport,
    StudentAnswersReport,
    StudentAssignmentUsageReport,
  }

  @tree_cache :tree_cache
  @disable_report_tree_cache !!Application.compile_env(:report_server, :disable_report_tree_cache)

  defmodule ReportGroup do
    defstruct slug: nil, title: nil, subtitle: nil, children: [], parents: [], path: nil, tbd: false
  end

  # Initialize the ETS table with the report tree, called at application start
  def init do
    if !@disable_report_tree_cache do
      :ets.new(@tree_cache, [:named_table, :set, :public, read_concurrency: true])

      get_tree()
      |> add_to_cache()
    end
  end

  def root(), do: find(Reports.get_root_slug())

  def find(slug) do
    if @disable_report_tree_cache do
      search_in_tree(slug)
    else
      case :ets.lookup(@tree_cache, slug) do
        [{^slug, value}] -> value
        [] -> :nil
      end
    end
  end

  def find_report(slug) do
    case find(slug) do
      report = %Report{} -> report
      _ -> nil
    end
  end

  def find_report_group([]), do: root()
  def find_report_group(slugs) do
    slug = List.last(slugs)
    case find(slug) do
      tree = %ReportGroup{} -> tree
      _ -> nil
    end
  end

  defp decorate_tree(root) do
    decorate_tree(root, [])
  end
  defp decorate_tree(node = %ReportGroup{}, parents) do
    children = parents ++ [{node.slug, node.title, get_parent_path(parents ++ [{node.slug, node.title, ""}])}]
    %{node | parents: parents, path: "#{get_parent_path(parents)}/#{node.slug}", children: Enum.map(node.children, &(decorate_tree(&1, children)))}
  end
  defp decorate_tree(node = %Report{}, parents) do
    %{node | parents: parents, path: "#{Reports.get_root_path()}/new/#{node.slug}"}
  end

  defp get_parent_path([]), do: ""
  defp get_parent_path(parents) do
    slugs = parents
      |> Enum.map(fn {slug, _title, _path} -> slug end)
      |> Enum.join("/")
    "/#{slugs}"
  end

  defp add_to_cache(%Report{} = node), do: :ets.insert(@tree_cache, {node.slug, node})
  defp add_to_cache(%ReportGroup{} = node) do
    :ets.insert(@tree_cache, {node.slug, node})
    Enum.each(node.children, &add_to_cache/1)
  end

  # used in dev mode so the run function is not cached
  def search_in_tree(slug) do
    tree = get_tree()
    if slug == tree.slug do
      tree
    else
      search_in_tree(slug, tree.children)
    end
  end
  def search_in_tree(slug, children) do
    Enum.reduce_while(children, nil, fn node, _acc ->
      case find_in_tree(node, slug) do
        nil -> {:cont, nil}
        found -> {:halt, found}
      end
    end)
  end
  defp find_in_tree(%Report{slug: node_slug} = node, slug) when node_slug == slug, do: node
  defp find_in_tree(%ReportGroup{slug: node_slug} = node, slug) when node_slug == slug, do: node
  defp find_in_tree(%ReportGroup{children: children}, slug), do: search_in_tree(slug, children)
  defp find_in_tree(_node, _slug), do: nil

  defp get_tree() do
    # NOTE: report slugs should never be changed once they are put into production as they are saved in the report runs
    %ReportGroup{slug: Reports.get_root_slug(), title: "Reports", subtitle: "Top Level Report Categories", children: [
      %ReportGroup{slug: "assignment-reports", title: "Assignment Reports", subtitle: "Reports about assignments", children: [
        ResourceMetricsSummaryReport.new(%Report{
          slug: "resource-metrics-summary",
          title: "Summary Metrics by Assignment",
          subtitle: "Includes total number of schools, number of teachers, number of classes, and number of learners per resource.",
          include_filters: [:cohort, :school, :teacher, :assignment]
        }),
        ResourceMetricsDetailsReport.new(%Report{
          slug: "resource-metrics-details",
          title: "Detailed Metrics by Assignment",
          subtitle: "Includes teacher information, school information, number of classes, number of students, and assignment information per resource.",
          include_filters: [:cohort, :school, :teacher, :assignment]
        }),
        StudentAssignmentUsageReport.new(%Report{
          slug: "student-assignment-usage",
          title: "Assignment Usage by Student",
          subtitle: "Includes ids, usernames, and other information about the student, teacher, class, school, etc as well as summary information about the resource(s) in your query like total number of questions and answers.",
          include_filters: [:cohort, :school, :teacher, :assignment, :permission_form],
          form_options: [enable_hide_names: true]
        })
      ]},
      %ReportGroup{slug: "student-reports", title: "Student Reports", subtitle: "Reports about students", children: [
        StudentActionsReport.new(%Report{
          slug: "student-actions",
          title: "Student Actions",
          subtitle: "Returns the low-level log event stream for the learners, including model-level interactions.",
          include_filters: [:cohort, :school, :teacher, :assignment, :class, :student, :permission_form],
          form_options: [enable_hide_names: true]
        }),
        StudentActionsWithMetadataReport.new(%Report{
          slug: "student-actions-with-metadata",
          title: "Student Actions with Metadata",
          subtitle: "Includes everything in the Student Actions report plus information provided by the Portal about the student, teacher, class, school, permission forms, portal ids, etc.",
          include_filters: [:cohort, :school, :teacher, :assignment, :class, :student, :permission_form],
          form_options: [enable_hide_names: true]
        }),
        StudentAnswersReport.new(%Report{
          slug: "student-answers",
          title: "Student Answers",
          subtitle: "Includes everything from the Assignment Usage by Student report plus details about student answers to all questions in the resource(s) in your query.",
          include_filters: [:cohort, :school, :teacher, :assignment, :class, :student, :permission_form],
          form_options: [enable_hide_names: true]
        }),
      ]},
      %ReportGroup{slug: "teacher-reports", title: "Teacher Reports", subtitle: "Reports about teachers", children: [
        TeacherActionsReport.new(%Report{
          slug: "teacher-actions",
          title: "Teacher Actions",
          subtitle: "Includes log events for teacher actions in the activities, teacher edition, and class dashboard.",
          include_filters: [:cohort, :school, :teacher, :assignment]
        }),
        TeacherStatusReport.new(%Report{
          slug: "teacher-status",
          title: "Teacher Status",
          subtitle: "Shows what activities teachers have assigned to their classes and how many students have started them.",
          include_filters: [:cohort, :school, :teacher, :assignment]
        }),
      ]},
      %ReportGroup{slug: "school-reports", title: "School Reports", subtitle: "Reports about schools", children: [
        DetailedMetricsBySchoolReport.new(%Report{
          slug: "school-metrics",
          title: "Detailed Metrics by School",
          subtitle: "Each row of this report will display the name of a school that had active teachers and students within the specified time period. Each school’s district, city, state, country, number of teachers, number of classes (including archived classes), number of students, class grade levels, and subject areas for the assignments associated with those teachers within the specified time period will also be included.",
          include_filters: [:country, :state, :subject_area]
        })
      ]},
      %ReportGroup{slug: "subject-area-reports", title: "Subject Area Reports", subtitle: "Reports about subject areas", children: [
        SummaryMetricsBySubjectAreaReport.new(%Report{
          slug: "summary-metrics-by-subject-area",
          title: "Summary Metrics by Subject Area",
          subtitle: "Each row of this report will include a subject area that had active assignments (assigned by teachers and/or run by students) within the specified time period. Additional columns include number of countries, number of states, number of schools, number of teachers, number of classes (including archived classes), number of students, and class grade levels.",
          include_filters: [:country, :state, :subject_area]
        })
      ]},
      # %ReportGroup{slug: "codap-reports", title: "CODAP Reports", subtitle: "Reports about CODAP (none yet defined)", tbd: true, children: [
      # ]},
    ]}
    |> decorate_tree()
  end
end
