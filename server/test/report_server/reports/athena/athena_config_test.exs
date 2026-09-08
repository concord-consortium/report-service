defmodule ReportServer.Reports.Athena.AthenaConfigTest do
  # mutates the global :athena env, so it must not overlap other async cases that read it
  use ExUnit.Case, async: false

  alias ReportServer.Reports.Athena.AthenaConfig

  setup do
    previous = Application.get_env(:report_server, :athena)

    on_exit(fn ->
      if previous do
        Application.put_env(:report_server, :athena, previous)
      else
        Application.delete_env(:report_server, :athena)
      end
    end)
  end

  defp readme, do: File.read!(Path.join([__DIR__, "..", "..", "..", "..", "README.md"]))

  describe "get_log_apps/0" do
    test "returns the projected values when :athena is unset" do
      Application.delete_env(:report_server, :athena)

      assert "CLUE" in AthenaConfig.get_log_apps()
    end

    test "returns the projected values when :athena is set but carries no :log_apps" do
      default = AthenaConfig.get_log_apps()
      Application.put_env(:report_server, :athena, log_db_name: "log_ingester_production")

      assert AthenaConfig.get_log_apps() == default
    end

    test "a configured override wins, so a Glue table change can be closed without a release" do
      Application.put_env(:report_server, :athena, log_apps: ~w(CLUE Dataflow))
      assert AthenaConfig.get_log_apps() == ~w(CLUE Dataflow)
    end
  end

  describe "get_hide_username_hash_salt/0" do
    test "falls back to a random salt when :athena is unset, rather than raising" do
      Application.delete_env(:report_server, :athena)

      assert is_binary(AthenaConfig.get_hide_username_hash_salt())
    end

    test "a configured salt wins" do
      Application.put_env(:report_server, :athena, hide_username_hash_salt: "configured.salt")

      assert AthenaConfig.get_hide_username_hash_salt() == "configured.salt"
    end
  end

  describe "agreement with the DDL in the README" do
    test "the app list agrees with every projection.app.values declaration" do
      matches =
        Regex.scan(~r/'projection\.app\.values'='([^']*)'/, readme(), capture: :all_but_first)

      assert length(matches) == 2, "expected both DDL blocks to declare the app projection"

      for [values] <- matches do
        assert String.split(values, ",") == AthenaConfig.get_log_apps()
      end
    end

    test "the year and month ranges agree with every declaration" do
      for {property, range} <- [
            {"year", AthenaConfig.get_log_projection_years()},
            {"month", AthenaConfig.get_log_projection_months()}
          ] do
        matches =
          Regex.scan(~r/'projection\.#{property}\.range'='(\d+),(\d+)'/, readme(),
            capture: :all_but_first
          )

        assert length(matches) == 2, "expected both DDL blocks to declare the #{property} range"

        for [first, last] <- matches do
          assert String.to_integer(first)..String.to_integer(last) == range
        end
      end
    end
  end

  describe "app_options/0" do
    test "carries every value exactly once, in order, with the raw enum string as the value" do
      values = AthenaConfig.app_options() |> Enum.map(fn {_label, value} -> value end)

      assert values == AthenaConfig.get_log_apps()
      assert length(Enum.uniq(values)) == length(values)
    end

    test "none is the only value whose label differs from it" do
      relabeled =
        AthenaConfig.app_options() |> Enum.filter(fn {label, value} -> label != value end)

      assert relabeled == [{"none (no application recorded)", "none"}]
    end
  end
end
