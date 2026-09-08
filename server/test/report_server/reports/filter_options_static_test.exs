defmodule ReportServer.Reports.FilterOptionsStaticTest do
  use ExUnit.Case, async: true

  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{FilterOptions, ReportFilter, Tree}
  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.FilterOptions.AppDimension

  # A static dimension answers the same way for every caller, so the user never varies here.
  defp user, do: %User{portal_server: "portal.example.com", portal_is_admin: true}

  defp page(opts), do: FilterOptions.page(:app, %ReportFilter{}, user(), opts)

  defp options(opts \\ [limit: 100]) do
    {:ok, options, _cursor} = page(opts)
    options
  end

  defp report(slug), do: Tree.find_report(slug)

  defp walk(limit) do
    Enum.reduce_while(1..40, {[], nil}, fn _, {acc, cursor} ->
      {:ok, options, next} = page(limit: limit, cursor: cursor)
      acc = acc ++ options

      if is_nil(next), do: {:halt, {acc, nil}}, else: {:cont, {acc, next}}
    end)
  end

  describe "the app dimension" do
    test "serves every projected application" do
      assert Enum.map(options(), & &1.id) |> Enum.sort() ==
               Enum.sort(AthenaConfig.get_log_apps())
    end

    test "the id is the raw value and the label is the display wording" do
      none = Enum.find(options(), &(&1.id == "none"))

      assert none == %{id: "none", label: "none (no application recorded)"}
    end

    test "options are ordered case-insensitively, as a portal dimension's are" do
      labels = Enum.map(options(), & &1.label)

      assert Enum.find_index(labels, &(&1 == "Dataflow")) <
               Enum.find_index(labels, &(&1 == "DEVOPS"))
    end

    test "search narrows case-insensitively and blank text returns everything" do
      assert Enum.map(options(limit: 100, like_text: "clue"), & &1.label) == ["CLUE"]
      assert options(limit: 100, like_text: "") == options()
    end

    test "a search that matches nothing is an empty page, not an error" do
      assert page(limit: 100, like_text: "no-such-application") == {:ok, [], nil}
    end
  end

  describe "the envelope is indistinguishable from a portal dimension's" do
    test "ids are strings and the last page carries no cursor" do
      {:ok, options, cursor} = page(limit: 100)

      assert Enum.all?(options, &(is_binary(&1.id) and is_binary(&1.label)))
      assert cursor == nil
    end

    for limit <- [1, 2, 4, 14] do
      test "a walk at page size #{limit} visits every option exactly once" do
        {visited, _} = walk(unquote(limit))

        assert visited == options()
      end
    end

    test "a page short of the limit carries no cursor" do
      {:ok, _options, cursor} = page(limit: 100, like_text: "clue")

      assert cursor == nil
    end
  end

  describe "a static dimension does not cascade or scope" do
    test "narrowing dimensions and dates are accepted and change nothing" do
      noisy = %ReportFilter{
        class: [601],
        student: [71],
        state: ["NH"],
        start_date: "2020-01-01",
        end_date: "2020-12-31",
        exclude_internal: true,
        hide_names: true,
        app: ["CLUE"]
      }

      {:ok, narrowed, _} = FilterOptions.page(:app, noisy, user(), limit: 100)

      assert narrowed == options()
    end

    test "an empty-set narrowing selection does not empty the vocabulary" do
      {:ok, narrowed, _} = FilterOptions.page(:app, %ReportFilter{class: []}, user(), limit: 100)

      assert narrowed == options()
    end
  end

  describe "count/4 for a static dimension" do
    test "is exact and never skipped" do
      assert FilterOptions.count(:app, %ReportFilter{}, user()) ==
               {:ok, length(AthenaConfig.get_log_apps())}
    end

    test "follows the search text" do
      assert FilterOptions.count(:app, %ReportFilter{}, user(), like_text: "clue") == {:ok, 1}
    end
  end

  describe "enabled_for_report?/1" do
    test "the reports whose logs carry an app partition accept the dimension" do
      assert AppDimension.enabled_for_report?(report("student-actions"))
      assert AppDimension.enabled_for_report?(report("student-actions-with-metadata"))
    end

    test "a report without one does not" do
      refute AppDimension.enabled_for_report?(report("teacher-actions"))
      refute AppDimension.enabled_for_report?(report("student-answers"))
    end
  end

  test "no name is both a static and a portal dimension" do
    static = FilterOptions.static_dimensions() |> Map.keys() |> Enum.map(&String.to_atom/1)

    assert static != []
    assert static -- ReportFilter.dimensions() == static
  end
end
