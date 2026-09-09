defmodule ReportServerWeb.Api.V1.FilterOptionsController do
  @moduledoc """
  `POST /api/v1/reports/filter-options`, the values a report filter dimension offers a caller.

  What narrows a dimension's options: the other dimensions in `report_filter`, the `search` text,
  and `exclude_internal` on the `teacher` dimension, which costs a second portal query to resolve
  Concord's own teacher ids. `start_date`, `end_date` and `hide_names` narrow nothing here, because
  `GET /api/v1/reports/:id` emits them on every run and a caller adjusting a run's filter must not
  be rejected for sending them back. Their types are still checked, so a filter shape this endpoint
  accepts is one `POST /api/v1/reports` parses too, though that endpoint applies rules this one has
  no use for; `hide_names` is decided by the caller's role instead.
  A static dimension ignores all narrowing, having no cascade to narrow through.

  Within `report_filter`, `null` and `[]` mean different things. `null` is "not selected". `[]` is
  "selected nothing", which narrows to nothing, so the response is an empty `items` with `count` 0
  and no field explaining why: zero is the true answer and the caller has the `[]` it sent.

  Paging parameters, `limit` and `page_token`, are read from the body or the query string.
  """

  use ReportServerWeb, :controller

  require Logger

  alias ReportServer.Reports.{FilterOptions, FilterValidation, Report, ReportFilter, Tree}
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
      opts =
        [limit: limit, cursor: cursor, like_text: search] ++ allowed_opt(dimension, user)

      with {:ok, options, next_cursor} <- FilterOptions.page(dimension, report_filter, user, opts),
           {:ok, count} <- maybe_count(dimension, report_filter, user, opts, count?) do
        json(conn, FilterOptionsJSON.index(options, next_cursor, count))
      else
        {:error, reason} ->
          Logger.error("Filter options failed for #{dimension}: #{inspect(reason)}")
          ErrorHelpers.server_error(conn)
      end
    else
      {:error, :not_found} -> ErrorHelpers.not_found(conn)
      {:error, message} -> ErrorHelpers.bad_request(conn, message)
    end
  end

  # A static dimension does no project scoping, so resolving the caller's allowed projects for one
  # would spend a portal query nothing reads, and would fail the whole request when the portal is
  # down for a vocabulary this application holds in its own code. Resolved here rather than lazily
  # inside FilterOptions so a counted request still resolves exactly once.
  defp allowed_opt(dimension, user) do
    case FilterOptions.static_dimension(dimension) do
      {:ok, _module} -> []
      :error -> [allowed: FilterOptions.allowed_projects(user)]
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
    if FilterValidation.offered?(dimension, report) do
      :ok
    else
      {:error, "#{slug} does not filter on #{dimension}"}
    end
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

  defp maybe_count(_dimension, _report_filter, _user, _opts, false), do: {:ok, :not_requested}

  # A broken count query is a server error, not a skipped count: count_skipped means the count was
  # refused for a reason the caller can act on, and folding a query regression into it would hide
  # the regression behind a 200.
  defp maybe_count(dimension, report_filter, user, opts, true) do
    case FilterOptions.count(dimension, report_filter, user, opts) do
      {:ok, count} -> {:ok, {:ok, count}}
      {:skipped, reason} -> {:ok, {:skipped, reason}}
      {:error, reason} -> {:error, reason}
    end
  end
end
