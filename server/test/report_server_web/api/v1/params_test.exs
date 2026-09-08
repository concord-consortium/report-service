defmodule ReportServerWeb.Api.V1.ParamsTest do
  use ExUnit.Case, async: true

  alias ReportServerWeb.Api.V1.Params

  describe "parse_limit/1" do
    test "a missing limit is the default" do
      assert {:ok, limit} = Params.parse_limit(%{})
      assert limit > 0
    end

    test "a query string carries it as a binary" do
      assert Params.parse_limit(%{"limit" => "25"}) == {:ok, 25}
    end

    test "a JSON body carries it as a number" do
      assert Params.parse_limit(%{"limit" => 25}) == {:ok, 25}
    end

    test "both spellings clamp to the documented server maximum" do
      assert Params.parse_limit(%{"limit" => "100000"}) == {:ok, 200}
      assert Params.parse_limit(%{"limit" => 100_000}) == {:ok, 200}
    end

    test "both spellings clamp up to at least one" do
      assert Params.parse_limit(%{"limit" => 0}) == Params.parse_limit(%{"limit" => "0"})
      assert Params.parse_limit(%{"limit" => -5}) == {:ok, 1}
    end

    test "what the GET endpoints already rejected is still rejected" do
      for bad <- ["abc", "2.5", "", "25x", 2.5, true, %{}, ["25"]] do
        assert Params.parse_limit(%{"limit" => bad}) == {:error, "limit must be an integer"},
               "#{inspect(bad)} should not be accepted as a limit"
      end
    end
  end

  describe "parse_cursor/1" do
    test "a missing or null token is no cursor" do
      assert Params.parse_cursor(%{}) == {:ok, nil}
      assert Params.parse_cursor(%{"page_token" => nil}) == {:ok, nil}
    end

    test "a cursor round-trips through the codec" do
      cursor = {"Lincoln High (sec)", "40"}
      token = Params.encode_cursor(cursor)

      assert is_binary(token)
      assert Params.parse_cursor(%{"page_token" => token}) == {:ok, cursor}
    end

    test "a label with characters that need escaping survives" do
      cursor = {"O'Fallon \"North\" \\ 100%", "7"}

      assert Params.parse_cursor(%{"page_token" => Params.encode_cursor(cursor)}) == {:ok, cursor}
    end

    test "nothing else decodes" do
      for bad <- ["!!", "", Base.url_encode64("not json", padding: false),
                  Base.url_encode64(~s(["only one"]), padding: false),
                  Base.url_encode64(~s([1, 2]), padding: false), 5, %{}] do
        assert Params.parse_cursor(%{"page_token" => bad}) == {:error, "page_token is not valid"},
               "#{inspect(bad)} should not decode to a cursor"
      end
    end

    test "no cursor encodes to no token" do
      assert Params.encode_cursor(nil) == nil
    end
  end
end
