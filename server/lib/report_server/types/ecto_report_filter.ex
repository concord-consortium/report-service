# this enables ecto to load/store tagged ReportFilter structs instead of just plain maps
defmodule ReportServer.Types.EctoReportFilter do
  use Ecto.Type

  alias ReportServer.Reports.ReportFilter

  def type, do: :map

  def cast(%ReportFilter{} = report_filter), do: {:ok, report_filter}
  def cast(_), do: :error

  def load(data) when is_map(data) do
    data =
      for {key, val} <- data do
        {String.to_atom(key), val}
      end
    {:ok, struct!(ReportFilter, data)}
  end

  def dump(%ReportFilter{} = report_filter), do: {:ok, Map.from_struct(report_filter)}
  def dump(_), do: :error
end
