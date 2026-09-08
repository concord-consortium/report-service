defmodule ReportServerWeb.Api.V1.FilterOptionsJSON do
  alias ReportServerWeb.Api.V1.Params

  @doc """
  The API's paged envelope plus the three count fields.

  The count has three states, each readable without parsing the reason string: a number with
  `count_skipped` false is the total, `null` with `count_skipped` true and a reason was asked for
  and refused, and `null` with `count_skipped` false was never asked for. `count` is never omitted,
  because an absent JSON number decodes to zero in Go.
  """
  def index(options, cursor, count) do
    %{items: options, next_page_token: Params.encode_cursor(cursor)}
    |> Map.merge(count_json(count))
  end

  defp count_json({:ok, count}), do: %{count: count, count_skipped: false, count_skipped_reason: nil}

  defp count_json({:skipped, reason}),
    do: %{count: nil, count_skipped: true, count_skipped_reason: reason}

  defp count_json(:not_requested),
    do: %{count: nil, count_skipped: false, count_skipped_reason: nil}
end
