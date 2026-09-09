defmodule ReportServer.Reports.FilterOptions do
  @moduledoc """
  Paged, keyset-ordered access to the report form's cascading filter-option lookup.

  Wraps `ReportFilterQuery.get_options_sql/1` rather than changing it, so the form keeps
  calling the unwrapped builder and its SQL cannot drift. The wrap names its own columns
  because an unaliased value expression's derived column is named with the expression text.
  """

  alias ReportServer.Accounts.User
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.{AllowedProjectsLookupError, HideNames, OptionLabel, ReportFilter, ReportFilterQuery}
  alias ReportServer.Reports.FilterOptions.AppDimension

  @static_dimensions %{app: AppDimension}
  @static_names Map.new(@static_dimensions, fn {name, _module} -> {to_string(name), name} end)

  # Both the page and the count are bounded well under PortalDbs' five-minute module default: a
  # request a client calls interactively has no business holding one of five shared connections for
  # minutes, and the wrap materializes the dimension's whole distinct option set per page.
  @portal_timeout_ms 5_000

  @doc "The static dimensions, keyed by the dimension name."
  def static_dimensions, do: @static_dimensions

  @doc "The module serving `dimension`, or `:error` when it is not a static dimension."
  def static_dimension(dimension), do: Map.fetch(@static_dimensions, dimension)

  @doc """
  Resolves a caller-supplied static dimension name to its atom.

  The registry hands back the atom it already holds, so no caller-supplied string is ever converted.
  """
  def dimension_from_string(raw) when is_binary(raw), do: Map.fetch(@static_names, raw)
  def dimension_from_string(_raw), do: :error

  @doc """
  One page of options for `dimension`, narrowed by the rest of `report_filter`.

  `:limit` is required rather than defaulted so `Api.V1.Params` stays the only definition of the
  paging default and maximum, which is why there is no `page/3`.
  """
  def page(dimension, report_filter = %ReportFilter{}, user = %User{}, opts) do
    limit = Keyword.fetch!(opts, :limit)
    # limit is interpolated into the portal statement and drives the arithmetic in cursor_after/2,
    # so the guard is what makes both safe rather than trusting the caller to have validated it.
    true = is_integer(limit) and limit > 0

    case static_dimension(dimension) do
      {:ok, module} -> static_page(module, limit, opts)
      :error -> portal_page(dimension, report_filter, user, limit, opts)
    end
  end

  defp portal_page(dimension, report_filter, user, limit, opts) do
    case query_and_params(dimension, report_filter, user, opts) do
      {nil, _params} ->
        {:ok, [], nil}

      {query, params} ->
        {where, cursor_params} = cursor_clause(Keyword.get(opts, :cursor))

        sql = """
        SELECT o.opt_id, COALESCE(o.opt_label, '') AS opt_label
        FROM (#{ReportFilterQuery.get_options_sql(query)}) AS o (opt_id, opt_label)
        #{where}
        ORDER BY COALESCE(o.opt_label, ''), o.opt_id
        LIMIT #{limit + 1}
        """

        case PortalDbs.query(user.portal_server, sql, params ++ cursor_params,
               timeout: @portal_timeout_ms
             ) do
          {:ok, result} ->
            rows = Enum.map(result.rows, fn [id, label] -> {id, label} end)
            {:ok, take_options(rows, limit), cursor_after(rows, limit)}

          error ->
            error
        end
    end
  end

  @doc """
  The total, `:skipped` with an accurate reason when one could not be produced, or `{:error, _}`
  when the query itself is broken. Three shapes get a count skipped rather than one: the unbounded
  student request, which never runs; a count that consumed its whole budget; and a portal too busy
  to hand out a connection. Only the last is a genuine failure.
  """
  def count(dimension, report_filter = %ReportFilter{}, user = %User{}, opts \\ []) do
    case static_dimension(dimension) do
      {:ok, module} -> {:ok, length(static_rows(module, opts))}
      :error -> portal_count(dimension, report_filter, user, opts)
    end
  end

  defp portal_count(dimension, report_filter, user, opts) do
    if unbounded?(dimension, report_filter, search_text(opts)) do
      {:skipped, "counting every student without a narrowing selection is unbounded"}
    else
      case query_and_params(dimension, report_filter, user, opts) do
        {nil, _params} ->
          {:ok, 0}

        {query, params} ->
          sql = "SELECT COUNT(*) FROM (#{ReportFilterQuery.get_options_sql(query)}) AS o (opt_id, opt_label)"

          # query_with_reason, not query: query/4 flattens every failure to a message string and the
          # driver's timeout text is itself ambiguous, so a real error would otherwise be reported
          # to the caller as a comforting "we ran out of time".
          case PortalDbs.query_with_reason(user.portal_server, sql, params,
                 timeout: @portal_timeout_ms
               ) do
            {:ok, result} -> {:ok, result.rows |> List.first() |> List.first()}
            {:error, :timeout, _} -> {:skipped, "the count did not complete within the time budget"}
            {:error, :busy, _} -> {:skipped, "the portal database was too busy to answer the count"}
            {:error, :db, message} -> {:error, message}
            # get_or_start_pool/1 fails before MyXQL is reached and returns a two element tuple,
            # which query_with_reason/4 passes straight through.
            {:error, message} -> {:error, message}
          end
      end
    end
  end

  # A static dimension owns the narrowing and this module owns the ordering, cursor and page
  # mechanics, which is the split that keeps a caller from telling the two kinds apart.
  defp static_page(module, limit, opts) do
    rows = module |> static_rows(opts) |> drop_through_cursor(Keyword.get(opts, :cursor))

    {:ok, take_options(rows, limit), cursor_after(rows, limit)}
  end

  defp static_rows(module, opts) do
    opts
    |> search_text()
    |> module.options()
    |> Enum.sort_by(&OptionLabel.sort_key/1)
  end

  defp drop_through_cursor(rows, nil), do: rows

  defp drop_through_cursor(rows, {label, id}) do
    cursor_key = OptionLabel.sort_key({id, label})
    Enum.drop_while(rows, &(OptionLabel.sort_key(&1) <= cursor_key))
  end

  defp query_and_params(dimension, report_filter, user, opts) do
    filter = prepare(dimension, report_filter, user)

    ReportFilterQuery.get_query_and_params(
      filter,
      allowed_projects(user, opts),
      OptionLabel.escape_like(search_text(opts)),
      user.portal_server
    )
  end

  defp search_text(opts), do: Keyword.get(opts, :like_text, "")

  # The target dimension is the primary filter: get_query_and_params/4 takes hd(filters), an empty
  # filters list short-circuits to no options, and the tail is never read. Narrowing comes from the
  # struct's own values, so the caller's filters list is replaced rather than merged with. Clearing
  # the target dimension's own value is what makes "show me the other schools" work rather than
  # narrowing the answer to what is already picked.
  defp prepare(dimension, report_filter, user) do
    report_filter
    |> HideNames.enforce(user)
    |> Map.put(:filters, [dimension])
    |> Map.put(dimension, nil)
  end

  defp unbounded?(:student, %ReportFilter{} = filter, ""), do: no_narrowing?(filter)
  defp unbounded?(_dimension, _filter, _like), do: false

  @narrowing ~w(cohort school teacher assignment class permission_form)a
  # `nil` is "not selected"; `[]` is a selection of nothing, which short-circuits the query to no
  # options, so it is narrowing and the count is the free, exact zero the query builder already
  # gives. The taxonomy dimensions are absent because none of them narrows the student query.
  defp no_narrowing?(filter), do: Enum.all?(@narrowing, &(Map.get(filter, &1) == nil))

  @doc """
  The caller's allowed projects, bounded like every other portal query this endpoint makes.

  The controller resolves this once and passes it to `page/4` and `count/4` through `:allowed`, so a
  counted request does not run the same permission query twice.
  """
  def allowed_projects(user = %User{}, opts \\ []) do
    Keyword.get_lazy(opts, :allowed, fn -> allowed_project_ids(user) end)
  end

  # A failed permission lookup is not "no projects": passing the {:error, _} tuple on reaches
  # list_to_in/1, which raises Protocol.UndefinedError from inside the query builder. Raise the
  # exception the report path already raises for this, so the failure is legible rather than a
  # zero-row answer. What a caller does with it is the caller's: this endpoint renders the
  # contract's SERVER_ERROR, and label derivation turns it back into an error tuple.
  defp allowed_project_ids(user) do
    case PortalDbs.get_allowed_project_ids(user, timeout: @portal_timeout_ms) do
      {:error, reason} ->
        raise AllowedProjectsLookupError, message: "allowed-projects lookup failed: #{inspect(reason)}"

      allowed ->
        allowed
    end
  end

  defp cursor_clause(nil), do: {"", []}

  defp cursor_clause({label, id}),
    do: {"WHERE (COALESCE(o.opt_label, ''), o.opt_id) > (?, ?)", [label, id]}

  # Both kinds reach here as {id, label} tuples, so the wire shape has one definition rather than
  # two that happen to agree.
  defp take_options(rows, limit) do
    rows |> Enum.take(limit) |> Enum.map(fn {id, label} -> %{id: to_string(id), label: label} end)
  end

  # A row beyond the page is how the next cursor is known without a second query.
  defp cursor_after(rows, limit) do
    if length(rows) > limit do
      {id, label} = Enum.at(rows, limit - 1)
      {label, to_string(id)}
    end
  end
end
