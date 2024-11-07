defmodule ReportServerWeb.CodapPluginLive.Query do
  defstruct name: nil, sql: nil

  def count_sql(table, name, period, count \\ "*")
  def count_sql(table, name, :month, count), do: "SELECT DATE_FORMAT(created_at, '%Y-%m') AS date, COUNT(#{count}) AS num_#{name} from #{table} GROUP BY YEAR(created_at), MONTH(created_at)"
  def count_sql(table, name, :year, count), do: "SELECT YEAR(created_at) AS date, COUNT(#{count}) AS num_#{name} from #{table} GROUP BY YEAR(created_at)"
  def user_count_sql(table, name, :month), do: count_sql(table, name, :month, "DISTINCT user_id")
  def user_count_sql(table, name, :year), do: count_sql(table, name, :year, "DISTINCT user_id")
end

defmodule ReportServerWeb.CodapPluginLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServer.PortalDbs
  alias ReportServerWeb.CodapPluginLive.Query

  @servers ["learn.concord.org"] #, "ngss-assessment.portal.concord.org", "learn.portal.staging.concord.org"]
  @queries %{
    "new_student_counts_by_month" => %Query{name: "New Student Counts By Month", sql: Query.user_count_sql("portal_students", "students", :month)},
    "new_student_counts_by_year" => %Query{name: "New Student Counts By Year", sql: Query.user_count_sql("portal_students", "students", :year)},
    "new_teacher_counts_by_month" => %Query{name: "New Teacher Counts By Month", sql: Query.user_count_sql("portal_teachers", "teachers", :month)},
    "new_teacher_counts_by_year" => %Query{name: "New Teacher Counts By Year", sql: Query.user_count_sql("portal_teachers", "teachers", :year)},
    "new_class_counts_by_month" => %Query{name: "New Class Counts By Month", sql: Query.count_sql("portal_clazzes", "classes", :month)},
    "new_class_counts_by_year" => %Query{name: "New Class Counts By Year", sql: Query.count_sql("portal_clazzes", "classes", :year)},
    "new_activity_counts_by_month" => %Query{name: "New Activity Counts By Month", sql: Query.count_sql("external_activities", "activities", :month)},
    "new_activity_counts_by_year" => %Query{name: "New Activity Counts By Year", sql: Query.count_sql("external_activities", "activities", :year)},
    "new_assignment_counts_by_month" => %Query{name: "New Assignment Counts By Month", sql: Query.count_sql("portal_offerings", "assignments", :month)},
    "new_assignment_counts_by_year" => %Query{name: "New Assignment Counts By Year", sql: Query.count_sql("portal_offerings", "assignments", :year)},
  }

  @impl true
  def mount(_params, _session, socket) do
    socket = socket
      |> assign(:page_title, "CODAP Plugin")
      |> assign(:in_codap, false)
      |> assign(:server, hd(@servers))
      |> assign(:server_options, @servers |> Enum.map(&{&1, &1}))
      |> assign(:query, hd(Map.keys(@queries)))
      |> assign(:query_options, Map.keys(@queries) |> Enum.map(&{@queries[&1].name, &1}))
      |> assign(:error, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("client_inited", _, socket) do
    {:noreply, assign(socket, :in_codap, true)}
  end

  @impl true
  def handle_event("get_data", %{"server" => server, "query" => query}, socket) do
    case PortalDbs.query(server, @queries[query].sql) do
      {:ok, result} ->
        rows = result
          |> PortalDbs.map_columns_on_rows()
          |> maybe_add_totals()
        socket = socket
          |> push_event("query_result", %{server: server, query: query, rows: rows})
          |> assign(:error, nil)
        {:noreply, socket}

      {:error, error} ->
        socket = socket
          |> assign(:error, error)
        {:noreply, socket}
    end
  end

  # the portal dbs don't support window functions so we need to total outside the query
  defp maybe_add_totals(rows) when length(rows) == 0, do: rows
  defp maybe_add_totals(rows) do
    num_column = get_num_column(hd(rows))
    if num_column do
      total_column = String.to_atom("total_#{num_column}")
      {reversed_rows_with_totals, _total} = rows
        |> Enum.reduce({[], 0}, fn row, {rows, total} ->
          total = total + row[num_column]
          row = Map.put(row, total_column, total)
          {[row|rows], total}
        end)
      Enum.reverse(reversed_rows_with_totals)
    else
      rows
    end
  end

  defp get_num_column(row) do
    row
      |> Map.keys()
      |> Enum.find(&(String.starts_with?(to_string(&1), "num_")))
  end

end
