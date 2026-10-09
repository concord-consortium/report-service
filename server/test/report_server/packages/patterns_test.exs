defmodule ReportServer.Packages.PatternsTest do
  use ExUnit.Case, async: true
  alias ReportServer.Packages.Patterns

  @fixture Path.expand("../../../../fixtures/url-patterns.json", __DIR__) |> File.read!() |> Jason.decode!()

  test "every matches case" do
    cases = @fixture["matches"]
    assert length(cases) == 27

    for %{"pattern" => pattern, "url" => url, "match" => match} <- cases do
      assert Patterns.matches?(pattern, url) == match, "#{inspect(pattern)} against #{inspect(url)}"
    end
  end

  test "every applies case" do
    cases = @fixture["applies"]
    assert length(cases) == 12

    for %{"urls" => urls, "scope" => scope, "ok" => ok} <- cases do
      assert (Patterns.applies(urls, scope) == :ok) == ok, "#{inspect(urls)} over #{inspect(scope)}"
    end
  end

  test "the refusals name the deciding pattern in the runner's words" do
    assert Patterns.applies(%{"all" => ["*x*"]}, ["y"]) == {:error, "no URL in this class matches the required pattern *x*"}
    assert Patterns.applies(%{"any" => ["*x*", "*z*"]}, ["y"]) == {:error, "no URL in this class matches any of *x*, *z*"}
    assert Patterns.applies(%{"none" => ["*y*"]}, ["y"]) == {:error, "a URL in this class matches the excluded pattern *y*"}
  end

  # applies matches at most 2,000 URLs of at most 2,048 code points; a quadratic matcher takes minutes here
  for {label, char} <- [{"ASCII", "a"}, {"four-byte", "😀"}] do
    test "the worst cases at the applies route's limits answer within 2 seconds, over #{label} URLs" do
      char = unquote(char)
      urls = List.duplicate(String.duplicate(char, 2_048), 2_000)

      shapes = [
        "*" <> String.duplicate(char, 254) <> "b",
        String.duplicate("*" <> char, 127) <> "*b",
        "*b" <> String.duplicate(char, 253) <> "*"
      ]

      for pattern <- shapes do
        {us, :ok} = :timer.tc(fn -> Patterns.applies(%{"none" => List.duplicate(pattern, 20)}, urls) end)
        assert us < 2_000_000, "#{String.slice(pattern, 0, 4)}... took #{div(us, 1000)} ms"
      end
    end
  end
end
