defmodule ReportServer.PaginationTest do
  use ReportServer.DataCase

  import Ecto.Query
  import ReportServer.AccountsFixtures

  alias ReportServer.Pagination
  alias ReportServer.Reports
  alias ReportServer.Reports.ReportRun

  defp make_runs(n) do
    user = user_fixture()

    for _ <- 1..n do
      {:ok, run} = Reports.create_report_run(%{user_id: user.id, report_slug: "student-answers"})
      run
    end
  end

  defp query(), do: from(r in ReportRun, order_by: [asc: r.id])

  test "an empty query yields page 1 of 1 with no items" do
    result = Pagination.paginate(query(), 1)
    assert result.items == []
    assert result.page == 1
    assert result.total_pages == 1
    assert result.total_count == 0
  end

  test "splits 26 rows into pages of 25 and 1, returning the overflow row on page 2" do
    runs = make_runs(26)

    p1 = Pagination.paginate(query(), 1)
    assert length(p1.items) == 25
    assert p1.page == 1
    assert p1.total_pages == 2
    assert p1.total_count == 26

    p2 = Pagination.paginate(query(), 2)
    assert length(p2.items) == 1
    assert hd(p2.items).id == List.last(runs).id
    assert p2.page == 2
  end

  test "normalizes invalid page params to page 1" do
    make_runs(3)

    for page <- ["abc", "0", nil, -5] do
      assert Pagination.paginate(query(), page).page == 1
    end
  end

  test "clamps a beyond-last page to the last page" do
    make_runs(26)

    result = Pagination.paginate(query(), 99)
    assert result.page == 2
    assert length(result.items) == 1
  end

  describe "normalize_page/1" do
    test "accepts integers and binaries at or above 1, else falls back to 1" do
      assert Pagination.normalize_page(3) == 3
      assert Pagination.normalize_page("3") == 3
      assert Pagination.normalize_page("abc") == 1
      assert Pagination.normalize_page("0") == 1
      assert Pagination.normalize_page(0) == 1
      assert Pagination.normalize_page(nil) == 1
    end
  end
end
