defmodule ReportServer.Packages do
  @moduledoc """
  The package catalog. Every package belongs to one portal, since one report-server serves
  several portals whose user and project ids overlap, so every lookup is confined to a portal.
  """
  import Ecto.Query, warn: false

  require Logger

  alias ReportServer.{PortalDbs, Repo}
  alias ReportServer.Accounts.User
  alias ReportServer.Packages.{Archive, Identity, Manifest, Package, PackageEvent, PackageVersion, Store}

  # a portal read on a request path fails fast rather than inheriting PortalDbs' five minutes
  @portal_timeout_ms 5_000
  # covers the two S3 puts made before the commit (Store.S3Store's HTTP timeouts)
  @publish_transaction_timeout_ms 120_000

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

  @doc """
  Publishes a package version from its zip. The owner comes from the token's user, never the
  manifest. The rows are inserted before the S3 writes and committed after them, so a
  concurrent publish of the same version waits on the unique index and fails rather than
  overwriting the winner's object, and a failed write leaves no rows.

  Errors are `{:error, kind, message}`, where kind is `:unprocessable`, `:forbidden`,
  `:already_exists`, `:portal_unavailable`, `:store_failed` or `:busy` (a lock conflict; retry).
  """
  def publish(%User{} = user, body, origin_param, official?) do
    with :ok <- check_publisher(user, official?),
         {:ok, manifest, entries} <- tag(Archive.read_manifest(body), :unprocessable),
         {:ok, attrs} <- tag(Manifest.project(manifest, entries), :unprocessable),
         {:ok, bucket} <- tag(Store.bucket_for(user.portal_server), :unprocessable),
         {:ok, origin} <- publish_origin(user, origin_param),
         identity = Identity.identity(origin, attrs.name),
         {:ok, allowed} <- allowed_project_ids(user, [origin, maintainer_of(user.portal_server, identity)]) do
      checksum = "sha256:" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower)

      Repo.transaction(fn ->
        {package, created?} = lock_or_insert_package(user, identity, origin, attrs.name)

        unless administers?(package, user.portal_user_id, allowed) do
          Repo.rollback({:forbidden, "you do not administer #{identity}"})
        end

        version = insert_version(package, attrs, identity, checksum, user)
        move_pointer? = created? or package.visibility == "private"
        package = if official?, do: make_official(package, user), else: package
        package = if move_pointer?, do: move_pointer(package, version.version, user), else: package

        with :ok <- Store.put(bucket, version.s3_key, body),
             :ok <- Store.put(bucket, Identity.s3_key(identity, version.version, "sha256"), checksum) do
          %{package: package, version: version}
        else
          {:error, reason} ->
            Logger.error("package store write failed for #{identity}: #{inspect(reason)}")
            Repo.rollback({:store_failed, "the package could not be stored"})
        end
      end, timeout: @publish_transaction_timeout_ms)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, {kind, message}} -> {:error, kind, message}
      end
    end
  rescue
    e in MyXQL.Error -> busy_or_reraise(e, __STACKTRACE__)
  end

  defp busy_or_reraise(error, stacktrace) do
    if lock_conflict?(error),
      do: {:error, :busy, "another change to this package is in progress; retry"},
      else: reraise(error, stacktrace)
  end

  # a lock wait timeout or a deadlock, which a retry resolves
  defp lock_conflict?(%MyXQL.Error{mysql: %{code: code}}), do: code in [1205, 1213]
  defp lock_conflict?(_error), do: false

  @doc """
  Changes one state of a package on the caller's portal, writing an audit row per field that
  changes, in one transaction. A change to the current value writes nothing and succeeds.

  `official` is the publisher role's alone, and setting it also makes the package public; the
  other states are its administrators'. Errors are `{:error, kind, message}`, where kind is
  `:bad_request`, `:not_found`, `:forbidden`, `:unprocessable`, `:portal_unavailable` or `:busy`
  (a lock conflict; retry).
  """
  def change_state(%User{} = user, identity, state, params) do
    with {:ok, change} <- parse_change(state, params),
         %Package{} = package <- package_query(user.portal_server, identity) |> Repo.one() || {:error, :not_found, "no package #{identity}"},
         {:ok, allowed} <- allowed_project_ids(user, grant_origins(change, package)),
         :ok <- authorize_change(change, package, user, allowed) do
      Repo.transaction(fn ->
        package = lock_package!(user.portal_server, identity)

        case apply_change(change, package, user) do
          {:ok, package} -> package
          {:error, kind, message} -> Repo.rollback({kind, message})
        end
      end)
      |> case do
        {:ok, package} -> {:ok, package}
        {:error, {kind, message}} -> {:error, kind, message}
      end
    end
  rescue
    e in MyXQL.Error -> busy_or_reraise(e, __STACKTRACE__)
  end

  # project_id is a signed 32-bit column
  defp parse_change("visibility", %{"visibility" => "project", "project_id" => id})
       when is_integer(id) and id > 0 and id <= 2_147_483_647,
    do: {:ok, {:visibility, "project", id}}

  defp parse_change("visibility", %{"visibility" => "project"}),
    do: {:error, :bad_request, "project visibility needs a positive integer project_id"}

  defp parse_change("visibility", %{"visibility" => v}) when v in ["private", "public"], do: {:ok, {:visibility, v, nil}}
  defp parse_change("visibility", _), do: {:error, :bad_request, "visibility must be private, project or public"}
  defp parse_change("official", %{"official" => v}) when is_boolean(v), do: {:ok, {:official, v}}
  defp parse_change("archived", %{"archived" => v}) when is_boolean(v), do: {:ok, {:archived, v}}
  defp parse_change("current_version", %{"current_version" => v}) when is_binary(v), do: {:ok, {:current_version, v}}

  defp parse_change(state, _) when state in ["official", "archived", "current_version"],
    do: {:error, :bad_request, "#{state} is missing or of the wrong type"}

  defp parse_change(state, _), do: {:error, :not_found, "no state #{state}; it is one of visibility, official, archived or current_version"}

  # official is the publisher role's alone, so no grant decides it
  defp grant_origins({:official, _}, _package), do: []
  defp grant_origins({:visibility, "project", id}, package), do: [package.maintainer, Identity.origin(:projects, id)]
  defp grant_origins(_change, package), do: [package.maintainer]

  defp authorize_change({:official, _}, _package, user, _allowed) do
    if publisher?(user), do: :ok, else: {:error, :forbidden, "only a package publisher may set official"}
  end

  defp authorize_change(change, package, user, allowed) do
    cond do
      not administers?(package, user.portal_user_id, allowed) ->
        {:error, :forbidden, "you do not administer #{package.identity}"}

      match?({:visibility, "project", _}, change) and not project_allowed?(elem(change, 2), allowed) ->
        {:error, :forbidden, "you hold no grant on project #{elem(change, 2)}"}

      true ->
        :ok
    end
  end

  defp apply_change({:visibility, visibility, project_id}, package, user) do
    if package.official and visibility != "public" do
      {:error, :unprocessable, "an official package is public; clear official first"}
    else
      {:ok, package |> record_change(:visibility, visibility, user) |> record_change(:project_id, project_id, user)}
    end
  end

  defp apply_change({:official, true}, package, user), do: {:ok, make_official(package, user)}
  defp apply_change({:official, false}, package, user), do: {:ok, record_change(package, :official, false, user)}
  defp apply_change({:archived, archived}, package, user), do: {:ok, record_change(package, :archived, archived, user)}

  defp apply_change({:current_version, version}, package, user) do
    if Repo.exists?(from v in PackageVersion, where: v.package_id == ^package.id and v.version == ^version),
      do: {:ok, move_pointer(package, version, user)},
      else: {:error, :unprocessable, "#{package.identity} has no version #{version}"}
  end

  defp check_publisher(user, true) do
    if publisher?(user), do: :ok, else: {:error, :forbidden, "only a package publisher may publish an official package"}
  end

  defp check_publisher(_user, _official?), do: :ok

  defp tag({:error, message}, kind), do: {:error, kind, message}
  defp tag(ok, _kind), do: ok

  defp publish_origin(user, nil), do: {:ok, Identity.origin(:users, user.portal_user_id)}

  defp publish_origin(_user, origin) do
    case Identity.parse_origin(origin) do
      {:ok, {:projects, _}} -> {:ok, origin}
      _ -> {:error, :unprocessable, "origin must be projects/<id>; a user origin is always your own"}
    end
  end

  defp maintainer_of(portal_server, identity) do
    package_query(portal_server, identity) |> select([p], p.maintainer) |> Repo.one()
  end

  defp allowed_project_ids(user, origins) do
    if Enum.any?(origins, &match?({:ok, {:projects, _}}, Identity.parse_origin(&1))) do
      case portal().get_allowed_project_ids(user, timeout: @portal_timeout_ms) do
        ids when is_list(ids) or ids in [:all, :none] -> {:ok, ids}
        _error -> {:error, :portal_unavailable, "the portal could not be asked for your project grants"}
      end
    else
      {:ok, :none}
    end
  end

  # No locking read of an absent row: two such reads take gap locks that deadlock both inserts.
  defp lock_or_insert_package(user, identity, origin, name) do
    if package_query(user.portal_server, identity) |> Repo.exists?() do
      {lock_package!(user.portal_server, identity), false}
    else
      %Package{}
      |> Package.create_changeset(%{portal_server: user.portal_server, origin: origin, name: name, maintainer: origin})
      |> Repo.insert()
      |> case do
        {:ok, package} -> {package, true}
        {:error, %{errors: [identity: _]}} -> {lock_package!(user.portal_server, identity), false}
      end
    end
  end

  defp package_query(portal_server, identity),
    do: from(p in Package, where: p.portal_server == ^portal_server and p.identity == ^identity)

  defp lock_package!(portal_server, identity),
    do: package_query(portal_server, identity) |> lock("FOR UPDATE") |> Repo.one!()

  defp insert_version(package, attrs, identity, checksum, user) do
    %PackageVersion{}
    |> PackageVersion.changeset(
      Map.merge(attrs, %{
        package_id: package.id,
        checksum: checksum,
        s3_key: Identity.s3_key(identity, attrs.version, "zip"),
        published_at: DateTime.utc_now() |> DateTime.truncate(:second),
        published_by: user.id
      })
    )
    |> Repo.insert()
    |> case do
      {:ok, version} -> version
      {:error, _changeset} -> Repo.rollback({:already_exists, "#{identity} #{attrs.version} is already published"})
    end
  end

  defp make_official(package, user) do
    package
    |> record_change(:official, true, user)
    |> record_change(:visibility, "public", user)
    |> record_change(:project_id, nil, user)
  end

  defp move_pointer(package, version, user), do: record_change(package, :current_version, version, user)

  defp record_change(package, field, new_value, user) do
    previous = Map.fetch!(package, field)

    if previous == new_value do
      package
    else
      package = package |> Package.state_changeset(%{field => new_value}) |> Repo.update!()

      Repo.insert!(%PackageEvent{
        package_id: package.id,
        user_id: user.id,
        field: Atom.to_string(field),
        previous_value: audit_value(previous),
        new_value: audit_value(new_value)
      })

      package
    end
  end

  defp audit_value(nil), do: nil
  defp audit_value(value), do: to_string(value)

  defp portal, do: Keyword.get(Application.get_env(:report_server, :packages, []), :portal, PortalDbs)
end
