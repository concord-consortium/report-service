defmodule ReportServer.Reports.DimensionScopeTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Reports.{AllowedProjectsLookupError, DimensionScope, ReportFilter, ReportFilterQuery}

  @server PortalFixture.server()
  @project 900
  @other_project 901

  @scoped [:cohort, :school, :teacher, :assignment, :permission_form, :class, :student]
  @taxonomies [:country, :state, :subject_area]

  # An entity the project reaches, and one it does not, per scoped dimension.
  @inside %{
    cohort: 1,
    school: 51,
    teacher: 31,
    assignment: 801,
    permission_form: 11,
    class: 601,
    student: 71
  }
  @outside %{
    cohort: 2,
    school: 54,
    teacher: 32,
    assignment: 802,
    permission_form: 14,
    class: 603,
    student: 75
  }

  defp ids(dimension, allowed) do
    {scope_join, scope_where} =
      case DimensionScope.scope(dimension, allowed) do
        :none -> {[], []}
        restriction -> restriction
      end

    join_sql = (DimensionScope.join(dimension) ++ scope_join) |> Enum.join(" ")

    where_sql =
      case DimensionScope.where(dimension) ++ scope_where do
        [] -> ""
        clauses -> "WHERE " <> Enum.map_join(clauses, " AND ", &"(#{&1})")
      end

    sql =
      "SELECT DISTINCT #{DimensionScope.id_expr(dimension)} FROM #{DimensionScope.from(dimension)} " <>
        "#{join_sql} #{where_sql}"

    {:ok, result} = PortalDbs.query(@server, sql)
    result.rows |> List.flatten() |> Enum.sort()
  end

  describe "scope/2 on the seven scoped dimensions" do
    test "admits an entity the caller's projects reach and excludes one they do not" do
      for dimension <- @scoped do
        scoped = ids(dimension, [@project])

        assert @inside[dimension] in scoped, "#{dimension} lost an entity inside the project"
        refute @outside[dimension] in scoped, "#{dimension} kept an entity outside the project"
      end
    end

    test "another project's scope excludes what this one admits" do
      for dimension <- @scoped do
        refute @inside[dimension] in ids(dimension, [@other_project]),
               "#{dimension} is not scoped by project at all"
      end
    end

    test "an empty list restricts to nothing rather than to everything" do
      for dimension <- @scoped do
        assert ids(dimension, []) == [], "#{dimension} answered an unscoped caller with rows"
        assert ids(dimension, :none) == []
      end
    end

    test ":all applies no restriction" do
      for dimension <- @scoped do
        assert @outside[dimension] in ids(dimension, :all)
        assert DimensionScope.scope(dimension, :all) == {[], []}
      end
    end

    test "a failed allowed-projects lookup raises rather than scoping to nothing" do
      assert_raise AllowedProjectsLookupError, fn ->
        DimensionScope.scope(:cohort, {:error, "portal is down"})
      end
    end
  end

  describe "scope/2 on the taxonomies" do
    test "is :none whatever the caller may see" do
      for dimension <- @taxonomies do
        assert DimensionScope.scope(dimension, [@project]) == :none
        assert DimensionScope.scope(dimension, []) == :none
      end
    end

    test "the same options come back for every caller" do
      for dimension <- @taxonomies do
        assert ids(dimension, [@project]) == ids(dimension, [])
        assert ids(dimension, [@project]) != []
      end
    end
  end

  test "the assignment disjunction admits an activity reached only through project materials" do
    {:ok, result} =
      PortalDbs.query(
        @server,
        "SELECT COUNT(*) FROM admin_cohort_items WHERE item_type = 'ExternalActivity' AND item_id = 803"
      )

    assert [[0]] = result.rows
    assert 803 in ids(:assignment, [@project])
  end

  test "option discovery selects the id expression this module defines" do
    for dimension <- ReportFilter.dimensions() do
      {query, _params} =
        ReportFilterQuery.get_query_and_params(
          %ReportFilter{filters: [dimension]},
          :all,
          "",
          @server
        )

      assert query.id == DimensionScope.id_expr(dimension),
             "#{dimension} resolves ids by a different expression than it offers them by"
    end
  end

  test "the state dimension's id is synthesized rather than a key" do
    assert DimensionScope.id_expr(:state) == "COALESCE(portal_schools.state, '(Unknown)')"
    assert "(Unknown)" in ids(:state, :all)
  end

  test "state is the one dimension whose ids are strings" do
    for dimension <- ReportFilter.dimensions() do
      expected = if dimension == :state, do: :string, else: :integer
      assert DimensionScope.id_type(dimension) == expected
    end
  end
end
