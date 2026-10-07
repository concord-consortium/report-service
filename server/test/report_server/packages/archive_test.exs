defmodule ReportServer.Packages.ArchiveTest do
  use ExUnit.Case, async: true

  alias ReportServer.Packages.Archive

  @fixtures Path.expand("../../support/fixtures/packages", __DIR__)

  defp zip(entries) do
    {:ok, {_, bin}} = :zip.create(~c"p.zip", Enum.map(entries, fn {n, d} -> {String.to_charlist(n), d} end), [:memory])
    bin
  end

  defp manifest_json, do: ~s({"name":"x"})

  test "reads the manifest and the file entries of the Info-ZIP fixture" do
    assert {:ok, %{"name" => "class-counts"}, entries} = Archive.read_manifest(File.read!(Path.join(@fixtures, "class-counts-1.0.6.zip")))
    assert Enum.sort(entries) == ["manifest.json", "run.py"]
  end

  test "reads a Go-written archive, whose local headers carry zero sizes" do
    bin = File.read!(Path.join(@fixtures, "class-counts-go-1.0.6.zip"))
    # flag 0x8, and a zero compressed size in the first local header
    assert <<0x50, 0x4B, 3, 4, _::16, 8, 0, _::binary-size(10), 0::32, _::binary>> = bin
    assert {:ok, %{"name" => "class-counts"}, _} = Archive.read_manifest(bin)
  end

  test "reads a stored manifest and leaves directories out of the entries" do
    {:ok, {_, bin}} = :zip.create(~c"p.zip", [{~c"manifest.json", manifest_json()}, {~c"lib/", ""}, {~c"lib/a.py", "x"}], [:memory, {:compress, []}])
    assert {:ok, %{"name" => "x"}, ["manifest.json", "lib/a.py"]} = Archive.read_manifest(bin)
  end

  test "reads a manifest that follows another entry, deflated or stored" do
    files = [{~c"run.py", String.duplicate("x", 5000)}, {~c"manifest.json", manifest_json()}]

    for options <- [[:memory], [:memory, {:compress, []}]] do
      {:ok, {_, bin}} = :zip.create(~c"p.zip", files, options)
      assert {:ok, %{"name" => "x"}, ["run.py", "manifest.json"]} = Archive.read_manifest(bin)
    end
  end

  test "refuses a body that is not a zip" do
    assert {:error, "the archive is not a readable zip"} = Archive.read_manifest("not a zip")
    assert {:error, "the archive is not a readable zip"} = Archive.read_manifest(<<>>)
  end

  test "refuses an archive over 10 MiB" do
    assert {:error, "the archive exceeds 10 MiB"} = Archive.read_manifest(:binary.copy(<<0>>, 10 * 1024 * 1024 + 1))
  end

  test "refuses a missing, nested or repeated manifest" do
    assert {:error, "the archive has no manifest.json at its root"} = Archive.read_manifest(zip([{"run.py", "x"}]))
    assert {:error, "the archive has no manifest.json at its root"} = Archive.read_manifest(zip([{"pkg/manifest.json", manifest_json()}]))
    assert {:error, "the archive has more than one manifest.json"} =
             Archive.read_manifest(zip([{"manifest.json", manifest_json()}, {"manifest.json", manifest_json()}]))
  end

  test "refuses an absolute or climbing entry" do
    assert {:error, message} = Archive.read_manifest(zip([{"manifest.json", manifest_json()}, {"../x", "x"}]))
    assert message =~ "climbs out"
    assert {:error, _} = Archive.read_manifest(zip([{"manifest.json", manifest_json()}, {"a/../../x", "x"}]))
    # :zip.create rewrites an absolute name on some OTP releases, so the name is patched in
    absolute = zip([{"manifest.json", manifest_json()}, {"xabs", "x"}]) |> :binary.replace("xabs", "/abs", [:global])
    assert {:error, message} = Archive.read_manifest(absolute)
    assert message =~ "absolute"
  end

  test "unsafe_path?/1 treats backslashes and drive letters as separators and roots" do
    for name <- ["/x", "\\x", "C:x", "a\\..\\b", "..", "a/.."], do: assert(Archive.unsafe_path?(name), name)
    for name <- ["lib/a.py", "a..b/c", "run.py"], do: refute(Archive.unsafe_path?(name), name)
  end

  test "refuses a stored manifest over 64 KiB" do
    {:ok, {_, bin}} = :zip.create(~c"p.zip", [{~c"manifest.json", :binary.copy(" ", 64 * 1024 + 1)}], [:memory, {:compress, []}])
    assert {:error, "manifest.json exceeds 64 KiB"} = Archive.read_manifest(bin)
  end

  # manifest.json is the first entry: its data starts after the 30-byte local header and 13-byte name
  test "refuses a manifest whose deflate stream is corrupt" do
    <<head::binary-size(43), data::binary>> = zip([{"manifest.json", manifest_json()}])
    <<_::binary-size(4), rest::binary>> = data
    assert {:error, "manifest.json is not a valid deflate stream"} = Archive.read_manifest(<<head::binary, 0xFF, 0xFF, 0xFF, 0xFF, rest::binary>>)
  end

  test "refuses an encrypted manifest" do
    <<pre::binary-size(6), _flags::16, post::binary>> = zip([{"manifest.json", manifest_json()}])
    assert {:error, "manifest.json is encrypted"} = Archive.read_manifest(<<pre::binary, 1::little-16, post::binary>>)
  end

  test "refuses a manifest with an unsupported compression method" do
    <<pre::binary-size(8), _method::16, post::binary>> = zip([{"manifest.json", manifest_json()}])
    assert {:error, "manifest.json uses an unsupported compression method"} = Archive.read_manifest(<<pre::binary, 12::little-16, post::binary>>)
  end

  test "refuses a manifest that is not a JSON object" do
    assert {:error, "manifest.json is not a JSON object"} = Archive.read_manifest(zip([{"manifest.json", "[1]"}]))
    assert {:error, "manifest.json is not a JSON object"} = Archive.read_manifest(zip([{"manifest.json", "{"}]))
  end

  test "refuses a manifest whose actual output passes 64 KiB" do
    assert {:error, "manifest.json exceeds 64 KiB"} = Archive.read_manifest(zip([{"manifest.json", :binary.copy(" ", 64 * 1024 + 1)}]))
  end

  test "refuses a 50 MB bomb on its declared size, before inflating anything" do
    bomb = zip([{"manifest.json", manifest_json()}, {"bomb", :binary.copy(<<0>>, 50 * 1024 * 1024 + 1)}])
    assert byte_size(bomb) < 1_000_000
    assert {:error, "the archive declares more than 50 MiB uncompressed"} = Archive.read_manifest(bomb)
  end

  test "refuses a manifest that declares 100 bytes and inflates to 20 MB, stopping at the cap" do
    bin = zip([{"manifest.json", :binary.copy(" ", 20_000_000)}]) |> lie_about_sizes("manifest.json", 100)
    assert {:ok, [_, {:zip_file, _, info, _, _, _}]} = :zip.list_dir(bin)
    assert elem(info, 1) == 100

    {micros, result} = :timer.tc(fn -> Archive.read_manifest(bin) end)
    assert result == {:error, "manifest.json exceeds 64 KiB"}
    assert micros < 1_000_000
  end

  # Rewrites an entry's uncompressed size in both its local header and its central directory record.
  defp lie_about_sizes(bin, name, size) do
    name_len = byte_size(name)

    local = ~r/PK\x03\x04/ |> Regex.scan(bin, return: :index) |> List.flatten()
    central = ~r/PK\x01\x02/ |> Regex.scan(bin, return: :index) |> List.flatten()

    bin = Enum.reduce(local, bin, fn {at, _}, acc -> patch(acc, at + 22, size, at + 30, name, name_len) end)
    Enum.reduce(central, bin, fn {at, _}, acc -> patch(acc, at + 24, size, at + 46, name, name_len) end)
  end

  defp patch(bin, size_at, size, name_at, name, name_len) do
    if binary_part(bin, name_at, name_len) == name do
      <<pre::binary-size(size_at), _::32, post::binary>> = bin
      <<pre::binary, size::little-32, post::binary>>
    else
      bin
    end
  end
end
