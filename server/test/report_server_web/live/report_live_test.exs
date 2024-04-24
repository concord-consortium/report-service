defmodule ReportServerWeb.ReportLiveTest do
  use ReportServerWeb.ConnCase

  import Phoenix.LiveViewTest
  import ReportServer.ReportsFixtures

  @create_attrs %{}
  @update_attrs %{}
  @invalid_attrs %{}

  defp create_report(_) do
    report = report_fixture()
    %{report: report}
  end

  describe "Index" do
    setup [:create_report]

    test "lists all reports", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/reports")

      assert html =~ "Your Reports"
    end
  end

end
