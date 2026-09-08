defmodule ReportServerWeb.Api.V1.FilterParams do
  @moduledoc """
  Parses the `report_filter` object of a request body into a `%ReportFilter{}`.

  The object is byte-identical to what `GET /api/v1/reports/:id` emits under the same key, so a
  caller can take a run's filter, adjust it and send it back. Unknown keys are ignored rather than
  rejected, which is what keeps a client holding a cached filter working against a server that has
  since gained a dimension.
  """

  alias ReportServer.Reports.ReportFilter
  alias ReportServerWeb.Api.V1.Params

  @string_dimensions [:state]

  def parse(nil), do: {:ok, %ReportFilter{}}
  def parse(filter) when not is_map(filter), do: {:error, "report_filter must be an object"}

  def parse(filter) do
    Enum.reduce_while(ReportFilter.dimensions(), {:ok, base(filter)}, fn dimension, {:ok, acc} ->
      case parse_dimension(filter, dimension) do
        {:ok, values} -> {:cont, {:ok, Map.put(acc, dimension, values)}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  # start_date, end_date and hide_names are accepted and ignored: the API emits them on every run,
  # so a caller adjusting a run's filter must not be rejected for sending them back. hide_names is
  # then overridden by the caller's role. exclude_internal is not inert and does narrow.
  defp base(filter) do
    %ReportFilter{
      exclude_internal: filter["exclude_internal"] == true,
      start_date: filter["start_date"],
      end_date: filter["end_date"]
    }
  end

  # nil means "not selected" and [] means "select nothing", which short-circuits the query to no
  # options, so the two are preserved as themselves rather than coalesced.
  defp parse_dimension(filter, dimension) do
    case Map.get(filter, to_string(dimension)) do
      nil -> {:ok, nil}
      values when is_list(values) -> parse_values(values, dimension)
      _ -> {:error, "#{dimension} must be a list or null"}
    end
  end

  defp parse_values(values, dimension) when dimension in @string_dimensions do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, "#{dimension} values must be strings"}
    end
  end

  defp parse_values(values, dimension) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case to_id(value) do
        {:ok, id} -> {:cont, {:ok, acc ++ [id]}}
        :error -> {:halt, {:error, "#{dimension} values must be integer ids"}}
      end
    end)
  end

  defp to_id(value) when is_integer(value) and value > 0 do
    if value <= Params.max_id(), do: {:ok, value}, else: :error
  end

  defp to_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> to_id(id)
      _ -> :error
    end
  end

  defp to_id(_value), do: :error
end
