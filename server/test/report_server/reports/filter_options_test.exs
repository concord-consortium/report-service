defmodule ReportServer.Reports.FilterOptionsTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{FilterOptions, ReportFilter}

  @server PortalFixture.server()

  defp super_admin, do: %User{portal_server: @server, portal_is_admin: true}

  defp project_admin,
    do: %User{portal_server: @server, portal_user_id: 555, portal_is_project_admin: true}

  defp researcher,
    do: %User{portal_server: @server, portal_user_id: 557, portal_is_project_researcher: true}

  defp page(dimension, filter, user, opts) do
    {:ok, options, cursor} = FilterOptions.page(dimension, filter, user, opts)
    {options, cursor}
  end

  defp labels(dimension, filter \\ %ReportFilter{}, user \\ nil, opts \\ [limit: 100]) do
    {options, _cursor} = page(dimension, filter, user || project_admin(), opts)
    Enum.map(options, & &1.label)
  end

  defp ids(dimension, filter \\ %ReportFilter{}, user \\ nil) do
    {options, _cursor} = page(dimension, filter, user || project_admin(), limit: 100)
    Enum.map(options, & &1.id)
  end

  # Every option the walk should visit, in the order the keyset imposes.
  @all_classes [
    {"3", ""},
    {"4", ""},
    {"2", "Adams (a)"},
    {"601", "Class 601 (c)"},
    {"602", "Class 602 (c)"},
    {"5", "Lincoln High (sec)"},
    {"9", "Lincoln High (sec)"},
    {"40", "Lincoln High (sec)"},
    {"77", "Zed (z)"}
  ]

  defp walk(dimension, filter, user, limit) do
    {visited, cursor, seen} = paged(dimension, filter, user, limit)
    assert cursor == nil, "the walk did not reach the last page"
    {visited, seen}
  end

  defp paged(dimension, filter, user, limit) do
    Enum.reduce_while(1..20, {[], nil, []}, fn _, {acc, cursor, seen_cursors} ->
      {options, next} = page(dimension, filter, user, limit: limit, cursor: cursor)
      acc = acc ++ Enum.map(options, &{&1.id, &1.label})

      cond do
        is_nil(next) -> {:halt, {acc, nil, seen_cursors}}
        next in seen_cursors -> flunk("the server repeated a page token: #{inspect(next)}")
        true -> {:cont, {acc, next, [next | seen_cursors]}}
      end
    end)
  end

  describe "page/4 paging" do
    test "one page returns the whole dimension in keyset order" do
      {options, cursor} = page(:class, %ReportFilter{}, project_admin(), limit: 100)

      assert Enum.map(options, &{&1.id, &1.label}) == @all_classes
      assert cursor == nil
    end

    for limit <- [1, 2, 3, 7] do
      test "a walk at page size #{limit} visits every option exactly once" do
        {visited, _} = walk(:class, %ReportFilter{}, project_admin(), unquote(limit))

        assert visited == @all_classes
      end
    end

    test "the tie and the null label are what make the walk able to fail" do
      tied = Enum.filter(@all_classes, fn {_id, label} -> label == "Lincoln High (sec)" end)

      assert Enum.map(tied, &elem(&1, 0)) == ["5", "9", "40"]
      assert Enum.count(@all_classes, fn {_id, label} -> label == "" end) == 2
    end

    test "a cursor is not reissued within a walk" do
      {_, cursors} = walk(:class, %ReportFilter{}, project_admin(), 2)

      assert length(Enum.uniq(cursors)) == length(cursors)
    end

    test "text search narrows the page" do
      assert labels(:class, %ReportFilter{}, nil, limit: 100, like_text: "lincoln") ==
               ["Lincoln High (sec)", "Lincoln High (sec)", "Lincoln High (sec)"]
    end
  end

  describe "page/4 scoping and privacy" do
    test "an option outside the caller's projects is absent, and present for a super admin" do
      refute "Cohort Two" in labels(:cohort)
      assert "Cohort Two" in labels(:cohort, %ReportFilter{}, super_admin())
    end

    test "a caller with no allowed projects gets an empty list rather than an error" do
      orphan = %User{portal_server: @server, portal_user_id: 999, portal_is_project_admin: true}

      assert page(:class, %ReportFilter{}, orphan, limit: 100) == {[], nil}
    end

    test "a researcher cannot read a student name, whatever the request asks for" do
      asked_to_see = %ReportFilter{hide_names: false}

      assert labels(:student, asked_to_see, researcher()) == ["101", "102", "103", "104"]
    end

    test "a researcher cannot confirm a name through the search text either" do
      assert labels(:student, %ReportFilter{}, researcher(), limit: 100, like_text: "Stu One") == []
    end

    test "an admin sees the names a researcher cannot" do
      assert "Stu One <101>" in labels(:student, %ReportFilter{}, project_admin())
    end
  end

  describe "page/4 narrowing" do
    test "a narrowing selection excludes a specific option" do
      in_601 = labels(:student, %ReportFilter{class: [601]})

      assert "Stu One <101>" in in_601
      refute "Stu Three <103>" in in_601
    end

    test "the target dimension's own value does not narrow its own options" do
      assert ids(:class, %ReportFilter{class: [601]}) == ids(:class)
    end

    test "nil means not selected and an empty list means select nothing" do
      assert ids(:student, %ReportFilter{class: nil}) == ids(:student, %ReportFilter{})
      assert ids(:student, %ReportFilter{class: []}) == []
    end

    test "the caller's own filters list is ignored" do
      round_tripped = %ReportFilter{filters: ["student", "class"], class: [601]}

      assert labels(:student, round_tripped) == labels(:student, %ReportFilter{class: [601]})
    end

    test "exclude_internal narrows the teacher dimension" do
      all = labels(:teacher)
      excluded = labels(:teacher, %ReportFilter{exclude_internal: true})

      assert "Eve Internal <eve@concord.org>" in all
      refute "Eve Internal <eve@concord.org>" in excluded
      assert "Ann Teach <ann@e.org>" in excluded
    end

    test "start and end dates are accepted and do not narrow" do
      dated = %ReportFilter{start_date: "2020-01-01", end_date: "2020-12-31"}

      assert ids(:class, dated) == ids(:class)
    end
  end

  describe "count/4" do
    test "a bounded count is the exact total" do
      assert FilterOptions.count(:class, %ReportFilter{}, project_admin()) == {:ok, 9}
      assert FilterOptions.count(:student, %ReportFilter{class: [601]}, project_admin()) == {:ok, 2}
    end

    test "an unnarrowed student count is skipped without running" do
      assert {:skipped, reason} = FilterOptions.count(:student, %ReportFilter{}, project_admin())
      assert reason =~ "unbounded"
    end

    test "any narrowing selection makes the student count runnable" do
      assert {:ok, _} = FilterOptions.count(:student, %ReportFilter{class: [601]}, project_admin())
      assert {:ok, _} = FilterOptions.count(:student, %ReportFilter{}, project_admin(), like_text: "Stu")
    end

    test "an empty-set selection counts zero rather than skipping" do
      assert FilterOptions.count(:student, %ReportFilter{class: []}, project_admin()) == {:ok, 0}
    end

    test "the count agrees with the number of options the walk visits" do
      {:ok, count} = FilterOptions.count(:class, %ReportFilter{}, project_admin())
      {visited, _} = walk(:class, %ReportFilter{}, project_admin(), 3)

      assert count == length(visited)
    end

    test "a caller with no allowed projects counts zero" do
      orphan = %User{portal_server: @server, portal_user_id: 999, portal_is_project_admin: true}

      assert FilterOptions.count(:class, %ReportFilter{}, orphan) == {:ok, 0}
    end
  end

  describe "the form's own lookup is unaffected" do
    test "the wrap is the only place the paging clauses appear" do
      {query, _params} =
        ReportServer.Reports.ReportFilterQuery.get_query_and_params(
          %ReportFilter{filters: [:class]},
          :all,
          "",
          @server
        )

      sql = ReportServer.Reports.ReportFilterQuery.get_options_sql(query)

      refute sql =~ "LIMIT"
      refute sql =~ "opt_label"
      assert {:ok, _} = PortalDbs.query(@server, sql)
    end
  end
end
