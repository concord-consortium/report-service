defmodule ReportServerWeb.Api.V1.FilterParams do
  @moduledoc """
  Parses the `report_filter` object of a request body into a `%ReportFilter{}`.

  The object is byte-identical to what `GET /api/v1/reports/:id` emits under the same key, so a
  caller can take a run's filter, adjust it and send it back. Unknown keys are ignored rather than
  rejected, which is what keeps a client holding a cached filter working against a server that has
  since gained a dimension.

  `filters` is the one emitted key not read back: it is derived from the dimensions a filter
  carries, so accepting it would be a second source of truth for what is already in the struct.
  `hide_names` is parsed but the caller's role decides it, through `HideNames.enforce/2` on both
  the option and the run paths.
  """

  alias ReportServer.Reports.{DimensionScope, FilterValidation, ReportFilter}
  alias ReportServerWeb.Api.V1.Params

  def parse(nil), do: {:ok, %ReportFilter{}}
  def parse(filter) when not is_map(filter), do: {:error, "report_filter must be an object"}

  def parse(filter) do
    with {:ok, base} <- base(filter) do
      Enum.reduce_while(ReportFilter.dimensions(), {:ok, base}, fn dimension, {:ok, acc} ->
        case parse_dimension(filter, dimension) do
          {:ok, values} -> {:cont, {:ok, Map.put(acc, dimension, values)}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
    end
  end

  defp base(filter) do
    with {:ok, exclude_internal} <- boolean(filter, "exclude_internal"),
         {:ok, hide_names} <- boolean(filter, "hide_names"),
         {:ok, app} <- app(filter),
         {:ok, start_date} <- date(filter, "start_date"),
         {:ok, end_date} <- date(filter, "end_date") do
      check_dates(%ReportFilter{
        exclude_internal: exclude_internal,
        hide_names: hide_names,
        app: app,
        start_date: start_date,
        end_date: end_date
      })
    end
  end

  defp boolean(filter, key) do
    case Map.get(filter, key, false) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, "#{key} must be true or false"}
    end
  end

  defp app(filter) do
    case Map.get(filter, "app") do
      nil -> {:ok, nil}
      apps when is_list(apps) -> app_values(apps)
      _ -> {:error, "app must be a list or null"}
    end
  end

  defp app_values(apps) do
    if Enum.all?(apps, &is_binary/1), do: {:ok, apps}, else: {:error, "app values must be strings"}
  end

  # The shape check a JSON body needs on top of the ISO rule, since a number or an object arrives
  # here where only a binary can arrive at check_dates/1. A blank control submits "", which the
  # form stores as absent.
  defp date(filter, key) do
    case Map.get(filter, key) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "#{key} must be a string"}
    end
  end

  defp check_dates(report_filter) do
    case FilterValidation.check_dates(report_filter) do
      :ok -> {:ok, report_filter}
      {:error, :invalid, message} -> {:error, message}
    end
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

  defp parse_values(values, dimension) do
    case DimensionScope.id_type(dimension) do
      :string -> parse_string_values(values, dimension)
      :integer -> parse_id_values(values, dimension)
    end
  end

  defp parse_string_values(values, dimension) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error, "#{dimension} values must be strings"}
    end
  end

  defp parse_id_values(values, dimension) do
    case Enum.reduce_while(values, {:ok, []}, &collect_id(&1, &2, dimension)) do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp collect_id(value, {:ok, acc}, dimension) do
    case to_id(value) do
      {:ok, id} -> {:cont, {:ok, [id | acc]}}
      :error -> {:halt, {:error, "#{dimension} values must be integer ids"}}
    end
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
