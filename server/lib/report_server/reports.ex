defmodule ReportServer.Reports do
  import Ecto.Query, warn: false

  alias ReportServer.Repo
  alias ReportServer.Accounts.User
  alias ReportServer.Reports.ReportRun

  @root_slug "new-reports"

  def get_root_slug(), do: @root_slug
  def get_root_path(), do: "/#{@root_slug}"

  @doc """
  Returns the list of all report_runs.

  ## Examples

      iex> list_all_report_runs()
      [%ReportRun{}, ...]

  """
  def list_all_report_runs do
    query = from r in ReportRun,
      order_by: [desc: r.inserted_at],
      preload: [:user]

    Repo.all(query)
  end

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
  def get_report_run!(id), do: Repo.get!(ReportRun, id)

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
