defmodule ReportServerWeb.ReportLiveTest do
  use ReportServerWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "Index" do
    test "Requires login", %{conn: conn} do
      {:error, {error, %{to: to}}} = live(conn, ~p"/reports")

      assert error == :redirect
      assert to == "/auth/login?return_to=/reports"
    end
  end

end
