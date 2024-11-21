defmodule ReportServer.Reports.ReportFilter do
  alias ReportServer.Reports.ReportFilter

  defstruct filters: [], cohort: [], school: [], teacher: [], assignment: [], permission_form: [],
    start_date: nil, end_date: nil

  @valid_filter_types ~w"cohort school teacher assignment permission_form"

  def from_form(form, filter_index) do
    if (filter_index < 1) do
      %ReportFilter{}
    else
      Enum.reduce(1..filter_index, %ReportFilter{}, fn i, acc ->
        filter_type = get_filter_type!(form, i)
        filter_value = get_filter_value(form, i)
        acc
        |> Map.put(filter_type, filter_value)
        |> Map.put(:filters, [filter_type | acc.filters])
      end)
      # NOTE: we do not reverse the filters as they need to be processed from right to left
    end
    |> Map.put(:start_date, form.params["start_date"])
    |> Map.put(:end_date, form.params["end_date"])
  end

  def get_filter_type!(form, i) do
    filter_type = form.params["filter#{i}_type"]
    if Enum.member?(@valid_filter_types, filter_type) do
      String.to_atom(filter_type)
    else
      raise "Invalid filter type: #{filter_type}"
    end
  end

  defp get_filter_value(form, i) do
    (form.params["filter#{i}"] || [])
    |> Enum.map(&String.to_integer/1)
  end
end
