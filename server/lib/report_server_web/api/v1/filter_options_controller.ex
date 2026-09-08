defmodule ReportServerWeb.Api.V1.FilterOptionsController do
  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.Reports.{FilterOptions, Report, ReportFilter, Tree}
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.{FilterOptionsJSON, FilterParams, Params}

  @max_search_length 200

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, dimension} <- parse_dimension(params),
         :ok <- check_report(params, dimension),
         {:ok, report_filter} <- FilterParams.parse(params["report_filter"]),
         {:ok, limit} <- Params.parse_limit(params),
         {:ok, cursor} <- Params.parse_cursor(params),
         {:ok, search} <- parse_search(params),
         {:ok, count?} <- parse_include_count(params, cursor) do
      opts = [limit: limit, cursor: cursor, like_text: search]

      case FilterOptions.page(dimension, report_filter, user, opts) do
        {:ok, options, next_cursor} ->
          count = maybe_count(dimension, report_filter, user, opts, count?)
          json(conn, FilterOptionsJSON.index(options, next_cursor, count))

        {:error, reason} ->
          Logger.error("Filter options failed for #{dimension}: #{inspect(reason)}")
          ErrorHelpers.server_error(conn)
      end
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
      {:error, message} -> ErrorHelpers.bad_request(conn, message)
    end
  end

  defp parse_dimension(params) do
    case Map.fetch(params, "dimension") do
      :error -> {:error, "dimension is required and must be one of: " <> known_dimensions()}
      {:ok, raw} -> resolve_dimension(raw)
    end
  end

  # The registry and ReportFilter hand back the atom they already hold, so a caller-supplied string
  # is never converted: atoms are not garbage collected, and this endpoint is called repeatedly.
  defp resolve_dimension(raw) do
    with :error <- FilterOptions.dimension_from_string(raw),
         :error <- ReportFilter.dimension_from_string(raw) do
      {:error, "dimension must be one of: " <> known_dimensions()}
    end
  end

  defp known_dimensions do
    (ReportFilter.dimensions() ++ Map.keys(FilterOptions.static_dimensions()))
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  # The slug is optional, so the endpoint doubles as a standalone data browser. When it is given,
  # a dimension the report does not filter on is a client error rather than an empty list.
  defp check_report(params, dimension) do
    case Map.get(params, "report_slug") do
      nil -> :ok
      slug when is_binary(slug) -> check_slug(slug, dimension)
      _ -> {:error, "report_slug must be a string"}
    end
  end

  defp check_slug(slug, dimension) do
    case Tree.find_report(slug) do
      %Report{} = report -> check_dimension_offered(report, dimension, slug)
      _ -> {:error, :not_found}
    end
  end

  defp check_dimension_offered(report, dimension, slug) do
    offered? =
      case FilterOptions.static_dimension(dimension) do
        {:ok, module} -> module.enabled_for_report?(report)
        :error -> dimension in report.include_filters
      end

    if offered?, do: :ok, else: {:error, "#{slug} does not filter on #{dimension}"}
  end

  defp parse_search(params) do
    case Map.get(params, "search") do
      nil -> {:ok, ""}
      search when is_binary(search) and byte_size(search) <= @max_search_length -> {:ok, search}
      search when is_binary(search) -> {:error, "search must be at most #{@max_search_length} bytes"}
      _ -> {:error, "search must be a string"}
    end
  end

  # A count costs what a page costs, since the wrap materializes the whole distinct set either way,
  # so counting every page of a walk would double it for one unchanged number. The default serves
  # the interactive first page, and the flag overrides it in either direction.
  defp parse_include_count(params, cursor) do
    case Map.get(params, "include_count", is_nil(cursor)) do
      wanted? when is_boolean(wanted?) -> {:ok, wanted?}
      _ -> {:error, "include_count must be true or false"}
    end
  end

  defp maybe_count(_dimension, _report_filter, _user, _opts, false), do: :not_requested

  defp maybe_count(dimension, report_filter, user, opts, true) do
    case FilterOptions.count(dimension, report_filter, user, opts) do
      {:error, reason} ->
        Logger.error("Filter option count failed for #{dimension}: #{inspect(reason)}")
        {:skipped, "the count could not be produced"}

      result ->
        result
    end
  end
end
