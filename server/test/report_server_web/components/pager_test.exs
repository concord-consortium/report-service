defmodule ReportServerWeb.PagerTest do
  use ReportServerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import ReportServerWeb.CustomComponents

  defp path_fun(), do: fn page -> "/x?page=#{page}" end

  test "is hidden when there is a single page" do
    html = render_component(&pager/1, page: 1, total_pages: 1, path_fun: path_fun())
    refute html =~ ~s(aria-label="pagination")
  end

  test "labels number and endpoint links and marks the active page, with no aria-disabled" do
    html = render_component(&pager/1, page: 2, total_pages: 3, path_fun: path_fun())

    assert html =~ ~s(aria-label="pagination")
    assert html =~ ~s(aria-current="page")
    assert html =~ ~s(aria-label="Page 2")
    assert html =~ ~s(aria-label="Previous page")
    assert html =~ ~s(aria-label="Next page")
    refute html =~ "aria-disabled"
  end

  test "windows a large page count as 1 … 4 5 6 … 20" do
    html = render_component(&pager/1, page: 5, total_pages: 20, path_fun: path_fun())

    assert html =~ ~s(aria-label="Page 1")
    assert html =~ ~s(aria-label="Page 4")
    assert html =~ ~s(aria-label="Page 5")
    assert html =~ ~s(aria-label="Page 6")
    assert html =~ ~s(aria-label="Page 20")
    refute html =~ ~s(aria-label="Page 3")
    refute html =~ ~s(aria-label="Page 7")
    assert html =~ ~s(aria-hidden="true")
  end

  test "shows no ellipsis for a small number of pages" do
    html = render_component(&pager/1, page: 2, total_pages: 3, path_fun: path_fun())
    refute html =~ ~s(aria-hidden="true")
  end
end
