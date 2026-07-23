defmodule ReportServer.Reports.SourceKeyTest do
  use ExUnit.Case, async: true

  alias ReportServer.Reports.SourceKey

  describe "from_runnable_url/1" do
    test "a hostname-only URL derives the host" do
      assert SourceKey.from_runnable_url("https://example.com/activity/123") == "example.com"
    end

    test "an answersSourceKey query param overrides the host" do
      assert SourceKey.from_runnable_url("https://example.com/a?answersSourceKey=foo") == "foo"
    end

    test "an empty answersSourceKey falls back to the host" do
      assert SourceKey.from_runnable_url("https://example.com/a?answersSourceKey=") ==
               "example.com"
    end

    test "the offline activity-player host is remapped to online" do
      assert SourceKey.from_runnable_url("https://activity-player-offline.concord.org/x") ==
               "activity-player.concord.org"
    end

    test "an answersSourceKey override wins even with an offline host" do
      assert SourceKey.from_runnable_url(
               "https://activity-player-offline.concord.org/x?answersSourceKey=custom"
             ) == "custom"
    end
  end
end
