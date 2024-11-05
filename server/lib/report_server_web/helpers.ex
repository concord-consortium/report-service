defmodule ReportServerWeb.Helpers do
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?([]), do: true
  def blank?(_), do: false

  def singular(s) do
    cond do
      String.ends_with?(s, "es") -> String.slice(s, 0..-3//1)
      String.ends_with?(s, "s") -> String.slice(s, 0..-2//1)
      true -> s
    end
  end
end
