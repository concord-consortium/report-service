defmodule ReportServer.Reports.OptionLabelTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.Athena.AthenaConfig
  alias ReportServer.Reports.OptionLabel

  describe "matches?/2" do
    test "blank text matches everything" do
      assert OptionLabel.matches?("CLUE", "")
      assert OptionLabel.matches?("", "")
    end

    test "a lowercase needle finds an uppercase label" do
      assert OptionLabel.matches?("CLUE", "clue")
    end

    test "an uppercase needle finds a lowercase label" do
      assert OptionLabel.matches?("portal-report", "PORTAL")
    end

    test "it matches a substring, not only a prefix" do
      assert OptionLabel.matches?("HASBot-Dashboard", "dashboard")
    end

    test "a needle that is absent does not match" do
      refute OptionLabel.matches?("CLUE", "codap")
    end
  end

  describe "sort_key/1" do
    test "ordering is case-insensitive, as a _ci collation is" do
      pairs = [{"b", "DEVOPS"}, {"a", "Dataflow"}, {"d", "GRASP"}, {"c", "GeniStarDev"}]

      assert pairs |> Enum.sort_by(&OptionLabel.sort_key/1) |> Enum.map(&elem(&1, 1)) ==
               ["Dataflow", "DEVOPS", "GeniStarDev", "GRASP"]
    end

    test "Elixir's own term order gets the real vocabulary backwards" do
      pairs = AthenaConfig.app_options() |> Enum.map(fn {label, value} -> {value, label} end)

      ours = pairs |> Enum.sort_by(&OptionLabel.sort_key/1) |> Enum.map(&elem(&1, 1))
      naive = pairs |> Enum.sort_by(fn {id, label} -> {label, id} end) |> Enum.map(&elem(&1, 1))

      assert Enum.find_index(ours, &(&1 == "Dataflow")) < Enum.find_index(ours, &(&1 == "DEVOPS"))
      assert Enum.find_index(naive, &(&1 == "DEVOPS")) < Enum.find_index(naive, &(&1 == "Dataflow"))
      refute ours == naive
    end

    test "the id breaks a tie between equal labels" do
      pairs = [{"9", "Same"}, {"40", "Same"}, {"5", "Same"}]

      assert pairs |> Enum.sort_by(&OptionLabel.sort_key/1) |> Enum.map(&elem(&1, 0)) ==
               ["40", "5", "9"]
    end
  end

  describe "AthenaConfig.app_options/1 narrows through the same predicate" do
    test "the form's application search is case-insensitive" do
      assert AthenaConfig.app_options("clue") == [{"CLUE", "CLUE"}]
      assert AthenaConfig.app_options("CLUE") == [{"CLUE", "CLUE"}]
    end

    test "blank text returns the whole vocabulary" do
      assert AthenaConfig.app_options("") == AthenaConfig.app_options()
    end

    test "it matches the label, which is not always the value" do
      assert AthenaConfig.app_options("recorded") == [{"none (no application recorded)", "none"}]
    end
  end
end
