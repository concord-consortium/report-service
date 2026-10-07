defmodule ReportServer.Packages.IdentityTest do
  use ExUnit.Case, async: true

  alias ReportServer.Packages.Identity

  describe "valid_name?/1" do
    test "accepts lowercase letters, digits and inner hyphens up to 63 characters" do
      assert Identity.valid_name?("class-counts")
      assert Identity.valid_name?("a")
      assert Identity.valid_name?("0abc")
      assert Identity.valid_name?(String.duplicate("a", 63))
    end

    test "refuses an underscore, uppercase, a leading hyphen, 64 characters and non-strings" do
      refute Identity.valid_name?("class_counts")
      refute Identity.valid_name?("Class-counts")
      refute Identity.valid_name?("-counts")
      refute Identity.valid_name?(String.duplicate("a", 64))
      refute Identity.valid_name?("")
      refute Identity.valid_name?("a/b")
      refute Identity.valid_name?("counts\n")
      refute Identity.valid_name?(nil)
    end
  end

  describe "parse_origin/1" do
    test "parses user and project origins" do
      assert Identity.parse_origin("users/136") == {:ok, {:users, 136}}
      assert Identity.parse_origin("projects/20") == {:ok, {:projects, 20}}
    end

    test "refuses a zero or padded id, another kind and malformed strings" do
      assert Identity.parse_origin("users/0") == :error
      assert Identity.parse_origin("users/012") == :error
      assert Identity.parse_origin("groups/1") == :error
      assert Identity.parse_origin("users/1/") == :error
      assert Identity.parse_origin("users/") == :error
      assert Identity.parse_origin("users/1\n") == :error
      assert Identity.parse_origin(nil) == :error
    end
  end

  test "identity/2 and parse/1 round-trip" do
    identity = Identity.identity("projects/20", "class-counts")
    assert identity == "projects/20/class-counts"
    assert Identity.parse(identity) == {:ok, %{origin: "projects/20", name: "class-counts"}}
  end

  test "parse/1 refuses a malformed identity" do
    assert Identity.parse("projects/20") == :error
    assert Identity.parse("projects/20/class_counts") == :error
    assert Identity.parse("groups/20/x") == :error
    assert Identity.parse("users/1/a/b") == :error
  end

  test "s3_key/3 places the object under packages/<identity>/" do
    assert Identity.s3_key("users/136/x", "1.0.0", "zip") == "packages/users/136/x/1.0.0.zip"
  end
end
