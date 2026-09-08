defmodule ReportServer.Reports.OptionLabel do
  @moduledoc """
  The one Elixir statement of what the option contract means by a label: whether it matches a
  search, and how it sorts. Both are case-insensitive, because the portal dimensions get that from
  SQL under a `_ci` collation, which cannot share this code. Elixir's own term order does the
  opposite, putting every uppercase letter first, so a plain `Enum.sort_by` on the label is wrong
  in a way no client can see until it pages two dimensions and gets two orderings.
  """

  @doc "Whether `label` matches `text` as a substring, blank text matching everything."
  def matches?(_label, ""), do: true
  def matches?(label, text), do: String.contains?(String.downcase(label), String.downcase(text))

  @doc "The total sort key for an option, matching a portal dimension's `ORDER BY label, id`."
  def sort_key({id, label}), do: {String.downcase(label), id}

  @doc """
  Escapes a caller's search text so `%` and `_` mean themselves.

  A portal dimension interpolates the text into `LIKE '%…%'`, where those are wildcards, while a
  static dimension compares it as a substring, where they are not. Unescaped, the same search means
  two different things depending on the kind, and `%` alone matches every portal row, which defeats
  the guard that keeps an unnarrowed student count from running. Backslash is MySQL's default
  `LIKE` escape character, so no `ESCAPE` clause is needed.
  """
  def escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
