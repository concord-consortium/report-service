defmodule ReportServer.Reports.ReportUtilsDbTest do
  use ExUnit.Case, async: false

  @moduletag :portal_db

  alias ReportServer.{PortalDbs, PortalFixture}
  alias ReportServer.Reports.ReportUtils

  @server PortalFixture.server()

  defp states_matching(values) do
    sql = "SELECT state FROM portal_schools WHERE state IN #{ReportUtils.mysql_string_list_to_in(values)}"
    {:ok, result} = PortalDbs.query(@server, sql)
    result.rows |> List.flatten() |> Enum.sort()
  end

  # What MySQL reads back out of the literal the escape produced for a single value.
  defp round_trip(value) do
    literal = ReportUtils.mysql_string_list_to_in([value]) |> String.slice(1..-2//1)
    {:ok, result} = PortalDbs.query(@server, "SELECT #{literal}")
    result.rows |> List.first() |> List.first()
  end

  test "a value survives the literal unchanged" do
    assert round_trip("O'Fallon") == "O'Fallon"
    assert round_trip("C:\\x") == "C:\\x"
    assert round_trip("NH\\") == "NH\\"
    assert round_trip("plain") == "plain"
  end

  test "a value ending in a backslash stays inside its literal" do
    assert states_matching(["NH\\", ") OR (1=1) #"]) == []
  end

  test "the same payload leaks rows through the quote-only escape" do
    unsafe = ReportUtils.string_list_to_single_quoted_in(["NH\\", ") OR (1=1) #"])
    sql = "SELECT state FROM portal_schools WHERE state IN #{unsafe}"
    {:ok, result} = PortalDbs.query(@server, sql)

    assert result.rows |> List.flatten() |> Enum.sort() == ["MA", "NH"]
  end

  test "benign values still match their rows" do
    assert states_matching(["NH", "MA"]) == ["MA", "NH"]
    assert states_matching(["NH"]) == ["NH"]
  end
end
