defmodule ReportServer.Reports do
  import Ecto.Query, warn: false

  alias ReportServer.Pagination
  alias ReportServer.Repo
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.{AthenaRunOps, FilterValidation, HideNames, Report, ReportFilter, ReportRun, Tree}

  @root_slug "new-reports"

  def get_root_slug(), do: @root_slug
  def get_root_path(), do: "/#{@root_slug}"

  @doc """
  Returns the list of all report_runs for a user.

  ## Examples

      iex> list_user_report_runs(user)
      [%ReportRun{}, ...]

      iex> list_user_report_runs(user, "example_report_slug")
      [%ReportRun{}, ...]

  """
  def list_user_report_runs(user = %User{}, report_slug \\ nil) do
    query = from r in ReportRun,
      where: r.user_id == ^user.id,
      order_by: [desc: r.inserted_at],
      preload: [:user]

    query = if report_slug do
      from q in query, where: q.report_slug == ^report_slug
    else
      query
    end

    Repo.all(query)
  end

  @doc """
  Gets a single report_run.

  Raises `Ecto.NoResultsError` if the Report run does not exist.

  ## Examples

      iex> get_report_run!(123)
      %ReportRun{}

      iex> get_report_run!(456)
      ** (Ecto.NoResultsError)

  """
  def list_user_report_runs_paginated(user = %User{}, page) do
    from(r in ReportRun, where: r.user_id == ^user.id, order_by: [desc: r.inserted_at, desc: r.id], preload: [:user])
    |> Pagination.paginate(page)
  end

  def list_all_report_runs_paginated(page) do
    from(r in ReportRun, order_by: [desc: r.inserted_at, desc: r.id], preload: [:user])
    |> Pagination.paginate(page)
  end

  def get_report_run!(id), do: Repo.get!(ReportRun, id)

  @doc """
  Lists the caller's API-exposed report runs (Athena and Portal), newest id first, keyset-paginated.
  """
  def list_api_report_runs(user = %User{}, limit, before_id \\ nil) do
    query = from r in ReportRun,
      where: r.user_id == ^user.id,
      where: r.report_slug in ^Tree.api_report_slugs(),
      order_by: [desc: r.id],
      limit: ^limit

    query = if before_id do
      from r in query, where: r.id < ^before_id
    else
      query
    end

    Repo.all(query)
  end

  @doc """
  Gets one of the caller's API-exposed report runs (Athena or Portal) by id, with the user preloaded.
  Not-owned ids, and ids of runs whose slug is not API-exposed, are indistinguishable from
  non-existent (`{:error, :not_found}`).
  """
  def get_api_report_run(user = %User{}, id) when is_integer(id) do
    query = from r in ReportRun,
      where: r.id == ^id,
      where: r.user_id == ^user.id,
      where: r.report_slug in ^Tree.api_report_slugs(),
      preload: [:user]

    case Repo.one(query) do
      nil -> {:error, :not_found}
      report_run -> {:ok, report_run}
    end
  end

  @doc """
  Gets a report run the caller may act on: their own, or any run when they are a portal admin.

  The own-or-admin rule the run page and the runs tables share, in one place, so an action carrying
  a run id from the DOM is authorized the same way the page that rendered it was.
  """
  def get_report_run_for_user(user = %User{}, id) when is_integer(id) do
    query = from r in ReportRun, where: r.id == ^id, preload: [:user]
    query = if user.portal_is_admin, do: query, else: from(q in query, where: q.user_id == ^user.id)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      report_run -> {:ok, report_run}
    end
  end

  @doc """
  Gets a single report_run with the user pre-loaded.

  Raises `Ecto.NoResultsError` if the Report run does not exist.

  ## Examples

      iex> get_report_run_with_user!(123)
      %ReportRun{}

      iex> get_report_run_with_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_report_run_with_user!(id), do: Repo.get!(ReportRun, id) |> Repo.preload(:user)

  @doc """
  Creates a report_run.

  ## Examples

      iex> create_report_run(%{field: value})
      {:ok, %ReportRun{}}

      iex> create_report_run(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_report_run(attrs \\ %{}) do
    %ReportRun{}
    |> ReportRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a run from a caller-supplied filter, deriving the labels and starting an Athena query.

  Returns the run with `:user` loaded. `report_filter_values` is always derived here and never
  accepted from a caller: a stored label is a point-in-time snapshot, so trusting one lets a
  renamed cohort keep its old name forever.

  Failures are tagged by kind: `{:error, :invalid, message}` is the caller's filter, which the
  message describes; `{:error, :out_of_scope, dimensions}` names ids the caller cannot see; and
  `{:error, :derivation_failed, reason}` is the portal, whose reason is not the caller's to read.
  """
  def create_api_report_run(user = %User{}, report = %Report{}, report_filter = %ReportFilter{}) do
    report_filter = HideNames.enforce(report_filter, user)

    with :ok <- FilterValidation.validate(report_filter, report),
         :ok <- FilterValidation.check_dates(report_filter),
         :ok <- FilterValidation.check_no_empty_selections(report_filter),
         :ok <- check_yields_query(report_filter, report, user),
         {:ok, values} <- derive_values(report_filter, user),
         stored_filter = store_filter(report_filter, values),
         {:ok, report_run} <-
           create_report_run(%{
             user_id: user.id,
             report_slug: report.slug,
             report_filter: stored_filter,
             report_filter_values: values
           }) do
      {:ok, report_run |> Repo.preload(:user) |> start_athena_query_async(report)}
    end
  end

  @doc """
  Creates a run from an existing run's slug and filter.

  The clone carries the slug and the filter and nothing else, so it starts its own Athena query
  rather than reporting the source's finished one, and its labels are derived again rather than
  copied from a snapshot taken when the source was created.
  """
  def duplicate_api_report_run(user = %User{}, report = %Report{}, source = %ReportRun{}) do
    report_filter = source.report_filter || %ReportFilter{}

    create_api_report_run(user, report, drop_empty_selections(report_filter))
  end

  # A stored run carrying [] on a dimension is already unconstrained: cohort: [] and cohort: nil
  # build the same SQL. Dropping it cannot move a row, and it keeps a run the user can re-run from
  # being one they cannot duplicate.
  defp drop_empty_selections(report_filter) do
    Enum.reduce(ReportFilter.dimensions(), report_filter, fn dimension, acc ->
      if Map.get(acc, dimension) == [], do: Map.put(acc, dimension, nil), else: acc
    end)
  end

  defp derive_values(report_filter, user) do
    case ReportFilter.get_filter_values(report_filter, user) do
      {:ok, values} -> {:ok, values}
      {:error, :out_of_scope, missing} -> {:error, :out_of_scope, missing}
      {:error, reason} -> {:error, :derivation_failed, reason}
    end
  end

  defp store_filter(report_filter, values) do
    report_filter = canonicalize_ids(report_filter, values)
    %{report_filter | filters: derive_filters(report_filter)}
  end

  # MySQL's collation is case insensitive and the state dimension's id is synthesized, so the id a
  # caller sends is not always the id the portal holds. Storing what resolved is what keeps two
  # runs over the same filter from being stored differently.
  defp canonicalize_ids(report_filter, values) do
    Enum.reduce(values, report_filter, fn {dimension, labels}, acc ->
      Map.put(acc, dimension, Map.keys(labels))
    end)
  end

  # Display metadata, derived rather than accepted: a client-supplied list would be a second source
  # of truth for which dimensions a filter carries. Reversed because the runs table reverses it
  # again to display. Derived on a duplicate too, since it round trips as strings, not atoms.
  defp derive_filters(report_filter) do
    ReportFilter.dimensions()
    |> Enum.filter(&(Map.get(report_filter, &1) not in [nil, []]))
    |> Enum.reverse()
  end

  # A Portal report's get_query is a pure builder, so building the query and throwing it away is
  # the exact answer for the price of the allowed-projects lookup. An Athena report's runs the
  # portal learner query and uploads the learner file, so it gets the input rule instead.
  defp check_yields_query(report_filter, %Report{type: :portal} = report, user) do
    case report.get_query.(report_filter, user) do
      {:ok, _query} -> :ok
      {:error, message} when is_binary(message) -> {:error, :invalid, message}
      {:error, reason} -> {:error, :derivation_failed, reason}
    end
  end

  defp check_yields_query(report_filter, _report, _user),
    do: FilterValidation.check_constrains_anything(report_filter)

  # Starting an Athena query runs the portal learner query and uploads the learner file before
  # Athena is contacted, so it is far too slow to hold a request open for. ensure_current/1's
  # atomic claim is what keeps a concurrent GET /reports/:id from starting the same query twice.
  defp start_athena_query_async(report_run, %Report{type: :athena}) do
    run_starter().(report_run)
    report_run
  end

  defp start_athena_query_async(report_run, _report), do: report_run

  # Injectable because a task started from Task.Supervisor owns none of the test sandbox's
  # connection, so a hard-wired starter dies inside the task and takes every assertion about the
  # kickoff with it.
  defp run_starter,
    do: Application.get_env(:report_server, :athena_run_starter, &start_athena_query_task/1)

  defp start_athena_query_task(report_run) do
    Task.Supervisor.start_child(ReportServer.PostProcessingTaskSupervisor, fn ->
      AthenaRunOps.ensure_current(report_run)
    end)
  end

  @doc """
  Updates a report_run.

  ## Examples

      iex> update_report_run(report_run, %{field: new_value})
      {:ok, %ReportRun{}}

      iex> update_report_run(report_run, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_report_run(%ReportRun{} = report_run, attrs) do
    report_run
    |> ReportRun.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a report_run.

  ## Examples

      iex> delete_report_run(report_run)
      {:ok, %ReportRun{}}

      iex> delete_report_run(report_run)
      {:error, %Ecto.Changeset{}}

  """
  def delete_report_run(%ReportRun{} = report_run) do
    Repo.delete(report_run)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking report_run changes.

  ## Examples

      iex> change_report_run(report_run)
      %Ecto.Changeset{data: %ReportRun{}}

  """
  def change_report_run(%ReportRun{} = report_run, attrs \\ %{}) do
    ReportRun.changeset(report_run, attrs)
  end
end
