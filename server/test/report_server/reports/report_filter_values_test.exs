defmodule ReportServer.Reports.ReportFilterValuesTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.PortalFixture
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.ReportFilter

  @server PortalFixture.server()

  defp super_admin, do: %User{portal_server: @server, portal_is_admin: true}

  defp project_admin,
    do: %User{portal_server: @server, portal_user_id: 555, portal_is_project_admin: true}

  defp values(filter, user \\ nil), do: ReportFilter.get_filter_values(filter, user || super_admin())

  describe "nothing to derive" do
    test "a filter with no ids answers without querying the portal" do
      filter = %ReportFilter{app: ["CODAP"], start_date: "2026-01-01", end_date: "2026-02-01"}
      unreachable = %User{portal_server: "no.such.host.example", portal_is_admin: true}

      assert values(filter, unreachable) == {:ok, %{}}
    end

    test "a dimension set to an empty list is not a dimension to derive" do
      assert values(%ReportFilter{cohort: []}) == {:ok, %{}}
    end
  end

  describe "the state dimension" do
    test "a payload that closes the IN list resolves nothing" do
      assert values(%ReportFilter{state: ["CA') OR 1=1 -- "]}) ==
               {:error, :out_of_scope, [{:state, ["CA') OR 1=1 -- "]}]}
    end

    test "a value containing a quote is refused as data rather than failing as syntax" do
      assert values(%ReportFilter{state: ["O'Hara"]}) ==
               {:error, :out_of_scope, [{:state, ["O'Hara"]}]}
    end

    test "the synthesized (Unknown) option resolves like any other value" do
      assert {:ok, %{state: %{"(Unknown)" => "(Unknown)"}}} = values(%ReportFilter{state: ["(Unknown)"]})
    end

    test "a value resolves under the spelling the portal holds" do
      assert {:ok, %{state: %{"MA" => "MA"}}} = values(%ReportFilter{state: ["ma"]})
    end

    test "a state no school carries is refused" do
      assert values(%ReportFilter{state: ["ZZ"]}) == {:error, :out_of_scope, [{:state, ["ZZ"]}]}
    end
  end

  describe "the labels each dimension derives" do
    test "one dimension at a time" do
      assert {:ok, %{cohort: %{1 => "Cohort One"}}} = values(%ReportFilter{cohort: [1]})
      assert {:ok, %{school: %{51 => "School W"}}} = values(%ReportFilter{school: [51]})
      assert {:ok, %{teacher: %{31 => "Ann Teach <ann@e.org>"}}} = values(%ReportFilter{teacher: [31]})
      assert {:ok, %{assignment: %{801 => "Activity One"}}} = values(%ReportFilter{assignment: [801]})
      assert {:ok, %{permission_form: %{11 => "Proj A: Form 1"}}} = values(%ReportFilter{permission_form: [11]})
      assert {:ok, %{class: %{601 => "Class 601 (c)"}}} = values(%ReportFilter{class: [601]})
      assert {:ok, %{student: %{71 => "Stu One <101>"}}} = values(%ReportFilter{student: [71]})
      assert {:ok, %{country: %{1 => "United States"}}} = values(%ReportFilter{country: [1]})
      assert {:ok, %{state: %{"NH" => "NH"}}} = values(%ReportFilter{state: ["NH"]})
      assert {:ok, %{subject_area: %{1 => "Science"}}} = values(%ReportFilter{subject_area: [1]})
    end

    test "a student label is the user id when names are hidden" do
      assert {:ok, %{student: %{71 => "101"}}} =
               values(%ReportFilter{student: [71], hide_names: true})
    end

    test "several dimensions come back in one map, keyed by their own id type" do
      filter = %ReportFilter{cohort: [1], state: ["NH"]}

      assert {:ok, %{cohort: %{1 => "Cohort One"}, state: %{"NH" => "NH"}}} = values(filter)
    end
  end

  describe "scoping" do
    test "an id outside the caller's projects is refused, naming the dimension and the id" do
      assert values(%ReportFilter{cohort: [2]}, project_admin()) ==
               {:error, :out_of_scope, [{:cohort, [2]}]}

      assert {:ok, %{cohort: %{2 => "Cohort Two"}}} = values(%ReportFilter{cohort: [2]})
    end

    test "every scoped dimension refuses an entity the caller's projects do not reach" do
      outside = [
        {:cohort, 2},
        {:school, 54},
        {:teacher, 32},
        {:assignment, 802},
        {:permission_form, 14},
        {:class, 603},
        {:student, 75}
      ]

      for {dimension, id} <- outside do
        filter = Map.put(%ReportFilter{}, dimension, [id])

        assert values(filter, project_admin()) == {:error, :out_of_scope, [{dimension, [id]}]}
        assert {:ok, %{^dimension => _}} = values(filter)
      end
    end

    test "the refusal names every dimension that lost an id, and resolves the rest" do
      filter = %ReportFilter{cohort: [1, 2], school: [51, 54]}

      assert values(filter, project_admin()) ==
               {:error, :out_of_scope, [{:cohort, [2]}, {:school, [54]}]}
    end

    test "the taxonomies resolve for a scoped caller" do
      assert {:ok, %{country: %{1 => "United States"}}} =
               values(%ReportFilter{country: [1]}, project_admin())

      assert {:ok, %{state: %{"NH" => "NH"}}} = values(%ReportFilter{state: ["NH"]}, project_admin())

      assert {:ok, %{subject_area: %{1 => "Science"}}} =
               values(%ReportFilter{subject_area: [1]}, project_admin())
    end
  end

  test "a portal failure is reported rather than folded into an empty map" do
    unreachable = %User{portal_server: "no.such.host.example", portal_is_admin: true}

    assert {:error, error} = values(%ReportFilter{cohort: [1]}, unreachable)
    refute match?({:out_of_scope, _}, error)
  end
end
