defmodule ReportServer.Reports.ReportFilterQueryDbTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Reports.{ReportFilter, ReportFilterQuery}

  @server PortalFixture.server()
  @project 900

  @secondary_values [
    cohort: [1],
    school: [51],
    teacher: [31],
    assignment: [801],
    permission_form: [11],
    class: [601],
    student: [71],
    country: [1],
    state: ["NH"],
    subject_area: [1]
  ]

  defp options(dimension, report_filter \\ %ReportFilter{}) do
    filter = %{report_filter | filters: [dimension]}
    {query, params} = ReportFilterQuery.get_query_and_params(filter, [@project], "", @server)
    {:ok, result} = PortalDbs.query(@server, ReportFilterQuery.get_options_sql(query), params)
    Enum.map(result.rows, fn [id, label] -> {to_string(id), label} end)
  end

  defp run_narrowed(dimension, secondary, value) do
    filter = %ReportFilter{filters: [dimension]} |> Map.put(secondary, value)
    {query, params} = ReportFilterQuery.get_query_and_params(filter, [@project], "", @server)
    PortalDbs.query(@server, ReportFilterQuery.get_options_sql(query), params)
  end

  test "every dimension the API accepts runs against the fixture" do
    for dimension <- ReportFilter.dimensions() do
      assert options(dimension) != [], "#{dimension} returned no options"
    end
  end

  test "narrowing one dimension by another generates legal SQL" do
    pairs =
      for dimension <- ReportFilter.dimensions(),
          {secondary, value} <- @secondary_values,
          secondary != dimension,
          do: {dimension, secondary, value}

    assert length(pairs) == 90

    broken =
      for {dimension, secondary, value} <- pairs,
          match?({:error, _}, run_narrowed(dimension, secondary, value)),
          do: {dimension, secondary}

    assert broken == []
  end

  test "a scoped caller can narrow assignments by cohort" do
    filter = %ReportFilter{filters: [:assignment], cohort: [1]}
    {query, params} = ReportFilterQuery.get_query_and_params(filter, [@project], "", @server)
    {:ok, result} = PortalDbs.query(@server, ReportFilterQuery.get_options_sql(query), params)

    assert result.rows == [[801, "Activity One"]]
  end

  test "a country narrowed by its schools' subject areas resolves through the offering chain" do
    assert narrowed_options(:country, :subject_area, [1]) == [{"1", "United States"}]
    assert narrowed_options(:country, :subject_area, [2]) == []
  end

  test "a country narrowed by teacher resolves through its own schools" do
    assert narrowed_options(:country, :teacher, [31]) == [{"1", "United States"}]
    assert narrowed_options(:country, :teacher, [35]) == [{"1", "United States"}]
  end

  defp narrowed_options(dimension, secondary, value) do
    {:ok, result} = run_narrowed(dimension, secondary, value)
    Enum.map(result.rows, fn [id, label] -> {to_string(id), label} end)
  end

  test "the class dimension carries a tie and a null label for the paging tests" do
    labels = options(:class) |> Enum.map(&elem(&1, 1))

    assert Enum.count(labels, &(&1 == "Lincoln High (sec)")) == 3
    assert Enum.count(labels, &is_nil/1) == 2
    assert length(labels) == 9
  end

  test "scoping keeps another project's cohort out" do
    assert options(:cohort) == [{"1", "Cohort One"}]
  end

  test "a taxonomy dimension is not scoped to the caller's projects" do
    assert options(:country) |> Enum.map(&elem(&1, 1)) |> Enum.sort() == ["Canada", "United States"]
  end

  test "the subject area dimension serves only subject-area tags" do
    assert options(:subject_area) |> Enum.map(&elem(&1, 1)) |> Enum.sort() == ["Math", "Science"]
  end

  test "the student label is a name, or an id when names are hidden" do
    named = options(:student) |> Enum.map(&elem(&1, 1)) |> Enum.sort()
    assert named == ["Stu Four <104>", "Stu One <101>", "Stu Three <103>", "Stu Two <102>"]

    hidden = options(:student, %ReportFilter{hide_names: true}) |> Enum.map(&elem(&1, 1))
    assert Enum.sort(hidden) == ["101", "102", "103", "104"]
  end
end
