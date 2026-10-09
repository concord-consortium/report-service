defmodule ReportServer.Packages.Patterns do
  @moduledoc """
  A package's URL patterns and the only glob matcher in the system. The dashboard
  app, the runner and cc-data ask report-server rather than keeping a copy.

  A pattern matches the whole URL. `*` matches any run of characters, including none and
  including `/`; every other character, `?` included, matches only itself, because URLs carry
  `?` literally. The matcher splits the pattern on `*` and finds each literal leftmost in turn,
  which is linear in the URL, where a backtracking two-pointer match is quadratic on a pattern
  such as `*aaaa...b`.
  """

  @groups ~w(all any none)
  @max_patterns 20
  @max_pattern_length 256

  @type urls :: %{String.t() => [String.t()]}

  @doc "Whether `pattern` matches the whole of `url`."
  @spec matches?(String.t(), String.t()) :: boolean()
  def matches?(pattern, url) when is_binary(pattern) and is_binary(url) do
    case :binary.split(pattern, "*", [:global]) do
      [literal] ->
        literal == url

      [first | rest] ->
        {middle, [last]} = Enum.split(rest, -1)
        first_size = byte_size(first)
        last_size = byte_size(last)
        size = byte_size(url)

        size >= first_size + last_size and
          binary_part(url, 0, first_size) == first and
          binary_part(url, size - last_size, last_size) == last and
          in_order?(middle, binary_part(url, first_size, size - first_size - last_size))
    end
  end

  defp in_order?([], _rest), do: true
  defp in_order?(["" | literals], rest), do: in_order?(literals, rest)

  defp in_order?([literal | literals], rest) do
    case :binary.match(rest, literal) do
      {at, length} -> in_order?(literals, binary_part(rest, at + length, byte_size(rest) - at - length))
      :nomatch -> false
    end
  end

  @doc """
  Whether a package's `urls` apply to a scope's URLs: every `all` pattern matches some URL, at
  least one `any` pattern does when `any` is non-empty, and no `none` pattern does. A refusal
  names the deciding pattern in the runner's words.
  """
  @spec applies(urls(), [String.t()]) :: :ok | {:error, String.t()}
  def applies(urls, scope_urls) do
    matched? = fn pattern -> Enum.any?(scope_urls, &matches?(pattern, &1)) end
    any = Map.get(urls, "any", [])

    cond do
      pattern = Enum.find(Map.get(urls, "all", []), &(not matched?.(&1))) ->
        {:error, "no URL in this class matches the required pattern #{pattern}"}

      any != [] and not Enum.any?(any, matched?) ->
        {:error, "no URL in this class matches any of #{Enum.join(any, ", ")}"}

      pattern = Enum.find(Map.get(urls, "none", []), matched?) ->
        {:error, "a URL in this class matches the excluded pattern #{pattern}"}

      true ->
        :ok
    end
  end

  @doc """
  Checks a manifest's or a request's `urls` and answers it with all three groups present, or a
  message naming what is wrong. The caps bound the matcher's work on every later request.
  """
  @spec validate(term()) :: {:ok, urls()} | {:error, String.t()}
  def validate(nil), do: {:ok, Map.new(@groups, &{&1, []})}

  def validate(urls) when is_map(urls) do
    with :ok <- known_groups(urls),
         {:ok, groups} <- pattern_groups(urls),
         :ok <- pattern_count(groups) do
      {:ok, groups}
    end
  end

  def validate(_), do: {:error, "urls must be an object of all, any and none arrays"}

  # an unknown group, such as a misspelled "any", would otherwise leave the package offered everywhere
  defp known_groups(urls) do
    case Map.keys(urls) -- @groups do
      [] -> :ok
      keys -> {:error, "urls has unknown keys #{Enum.join(keys, ", ")}; only all, any and none are allowed"}
    end
  end

  defp pattern_groups(urls) do
    Enum.reduce_while(@groups, {:ok, %{}}, fn group, {:ok, acc} ->
      case patterns(group, Map.get(urls, group, [])) do
        {:ok, patterns} -> {:cont, {:ok, Map.put(acc, group, patterns)}}
        error -> {:halt, error}
      end
    end)
  end

  defp patterns(group, patterns) when is_list(patterns) do
    if Enum.all?(patterns, &valid_pattern?/1),
      do: {:ok, patterns},
      else: {:error, "urls.#{group} patterns must be non-empty strings of at most #{@max_pattern_length} characters with no whitespace or control characters"}
  end

  defp patterns(group, _), do: {:error, "urls.#{group} must be an array of strings"}

  defp valid_pattern?(pattern) do
    is_binary(pattern) and String.valid?(pattern) and pattern != "" and
      length(String.codepoints(pattern)) <= @max_pattern_length and not Regex.match?(~r/[\s\p{Cc}]/u, pattern)
  end

  defp pattern_count(groups) do
    if groups |> Map.values() |> Enum.map(&length/1) |> Enum.sum() > @max_patterns,
      do: {:error, "urls declares more than #{@max_patterns} patterns across all, any and none"},
      else: :ok
  end
end
