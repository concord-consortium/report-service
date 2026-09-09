defmodule ReportServerWeb.Api.ErrorHelpersTest do
  use ExUnit.Case, async: true

  alias ReportServerWeb.Api.ErrorHelpers

  describe "primary_code_by_status/0" do
    test "names a code that exists and carries that status" do
      assert map_size(ErrorHelpers.primary_code_by_status()) > 0

      for {status, code} <- ErrorHelpers.primary_code_by_status() do
        assert Map.fetch!(ErrorHelpers.statuses(), code) == status
      end
    end

    test "covers every status any code renders as" do
      assert map_size(ErrorHelpers.statuses()) > 0

      for {_code, status} <- ErrorHelpers.statuses() do
        assert Map.has_key?(ErrorHelpers.primary_code_by_status(), status),
               "status #{status} has no primary code"
      end
    end
  end

  describe "code_for_status/1" do
    test "409 is NOT_READY, not the duplicate guard's code" do
      assert ErrorHelpers.code_for_status(409) == "NOT_READY"
    end

    test "an unmapped status is SERVER_ERROR" do
      assert ErrorHelpers.code_for_status(418) == "SERVER_ERROR"
    end
  end

  describe "statuses/0" do
    test "the duplicate guard's code is a 409" do
      assert Map.fetch!(ErrorHelpers.statuses(), "PORTAL_DUPLICATE_UNNECESSARY") == 409
    end
  end
end
