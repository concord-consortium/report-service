defmodule ReportServer.Packages do
  @moduledoc """
  The package catalog. Every package belongs to one portal, since one report-server serves
  several portals whose user and project ids overlap, so every lookup is confined to a portal.
  """
  import Ecto.Query, warn: false

  alias ReportServer.Repo
  alias ReportServer.Accounts.User
  alias ReportServer.Packages.Identity

  @doc """
  Whether a caller administers a package: they are its maintainer, or it is maintained by a
  project among their allowed project ids (`:all` for a site admin).
  """
  def administers?(%{maintainer: maintainer}, portal_user_id, allowed_project_ids) do
    case Identity.parse_origin(maintainer) do
      {:ok, {:users, id}} -> id == portal_user_id
      {:ok, {:projects, id}} -> project_allowed?(id, allowed_project_ids)
      :error -> false
    end
  end

  def project_allowed?(_project_id, :all), do: true
  def project_allowed?(project_id, ids) when is_list(ids), do: project_id in ids
  def project_allowed?(_project_id, _), do: false

  @doc """
  The publisher role, the only one that may set or clear `official`: every portal site admin,
  and any user an operator has granted it with `ReportServer.Release.grant_package_publisher/2`.
  """
  def publisher?(%User{package_publisher: true}), do: true
  def publisher?(%User{portal_is_admin: true}), do: true
  def publisher?(_user), do: false

  @spec set_publisher(String.t(), integer(), boolean()) :: :ok | {:error, :not_found}
  def set_publisher(portal_server, portal_user_id, value) when is_boolean(value) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(u in User, where: u.portal_server == ^portal_server and u.portal_user_id == ^portal_user_id)
    |> Repo.update_all(set: [package_publisher: value, updated_at: now])
    |> case do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end
end
