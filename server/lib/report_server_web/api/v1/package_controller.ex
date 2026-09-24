defmodule ReportServerWeb.Api.V1.PackageController do
  use ReportServerWeb, :controller

  alias ReportServer.{Packages, PortalDbs}
  alias ReportServer.Packages.{Archive, Identity}
  alias ReportServerWeb.Api.ErrorHelpers
  alias ReportServerWeb.Api.V1.PackageJSON

  @error_codes %{
    bad_request: "BAD_REQUEST",
    unprocessable: "UNPROCESSABLE",
    forbidden: "FORBIDDEN",
    not_found: "NOT_FOUND",
    not_authenticated: "NOT_AUTHENTICATED",
    already_exists: "ALREADY_EXISTS",
    portal_unavailable: "SERVICE_UNAVAILABLE",
    busy: "SERVICE_UNAVAILABLE",
    store_failed: "SERVICE_UNAVAILABLE"
  }

  # The zip is the raw body: Plug.Parsers passes application/zip through unread.
  def create(conn, params) do
    with :ok <- zip_content_type(conn),
         {:ok, body, conn} <- read_archive(conn),
         {:ok, official?} <- official_param(params["official"]),
         {:ok, %{package: package, version: version}} <-
           Packages.publish(conn.assigns.current_user, body, params["origin"], official?) do
      conn
      |> put_status(:created)
      |> json(%{
        catalog_id: package.id,
        identity: package.identity,
        version: version.version,
        checksum: version.checksum,
        visibility: package.visibility,
        official: package.official,
        current_version: package.current_version
      })
    else
      {:error, kind, message} -> ErrorHelpers.render_error(conn, Map.fetch!(@error_codes, kind), message)
    end
  end

  def update_state(conn, %{"kind" => kind, "owner_id" => owner_id, "name" => name, "state" => state} = params) do
    identity = Identity.identity("#{kind}/#{owner_id}", name)

    with :ok <- known_identity(identity),
         {:ok, package} <- Packages.change_state(conn.assigns.current_user, identity, state, params) do
      json(conn, %{
        catalog_id: package.id,
        identity: package.identity,
        visibility: package.visibility,
        project_id: package.project_id,
        official: package.official,
        archived: package.archived,
        current_version: package.current_version
      })
    else
      {:error, kind, message} -> ErrorHelpers.render_error(conn, Map.fetch!(@error_codes, kind), message)
    end
  end

  def index(conn, params) do
    result =
      case conn.assigns[:portal_claims] do
        nil ->
          with {:ok, server} <- portal_param(params["portal"]), do: {:ok, Packages.list_official(server)}

        claims ->
          with {:ok, reader} <- Packages.reader(claims), do: {:ok, Packages.list_visible(reader)}
      end

    case result do
      {:ok, entries} -> conn |> no_store() |> json(PackageJSON.index(entries))
      {:error, kind, message} -> ErrorHelpers.render_error(conn, Map.fetch!(@error_codes, kind), message)
    end
  end

  def resolve(conn, params) do
    with {:ok, claims} <- bearer_claims(conn),
         {:ok, identity, version} <- resolve_params(params),
         {:ok, reader} <- Packages.reader(claims),
         {:ok, resolved} <- Packages.resolve(reader, identity, version) do
      conn |> no_store() |> json(PackageJSON.resolve(resolved))
    else
      {:error, kind, message} -> ErrorHelpers.render_error(conn, Map.fetch!(@error_codes, kind), message)
    end
  end

  # CatalogCors has already refused an origin outside the allowlist and set the headers.
  def preflight(conn, _params), do: send_resp(conn, 204, "")

  defp portal_param(portal) when is_binary(portal) and portal != "" do
    server = PortalDbs.get_server_for_portal_url(if String.contains?(portal, "://"), do: portal, else: "https://" <> portal)
    if is_binary(server), do: {:ok, server}, else: {:error, :bad_request, "portal must be a portal host or URL"}
  end

  defp portal_param(_), do: {:error, :bad_request, "an anonymous read names its portal with ?portal="}

  defp bearer_claims(conn) do
    case conn.assigns[:portal_claims] do
      nil -> {:error, :not_authenticated, "resolving a package needs a launch token"}
      claims -> {:ok, claims}
    end
  end

  defp resolve_params(%{"identity" => identity, "version" => version}) when is_binary(identity) and is_binary(version),
    do: {:ok, identity, version}

  defp resolve_params(_), do: {:error, :bad_request, "resolve needs identity and version"}

  defp no_store(conn) do
    if conn.assigns[:portal_claims], do: put_resp_header(conn, "cache-control", "no-store"), else: conn
  end

  defp known_identity(identity) do
    case Identity.parse(identity) do
      {:ok, _} -> :ok
      :error -> {:error, :not_found, "no package #{identity}"}
    end
  end

  defp zip_content_type(conn) do
    case get_req_header(conn, "content-type") do
      ["application/zip" <> _] -> :ok
      _ -> {:error, :bad_request, "the package must be sent as the request body with Content-Type: application/zip"}
    end
  end

  # Bandit reads a chunked body whole, ignoring read_body's :length, so the size must be declared.
  defp read_archive(conn) do
    with {:ok, declared} <- content_length(conn),
         :ok <- if(declared > Archive.max_archive_bytes(), do: {:error, :unprocessable, "the archive exceeds 10 MiB"}, else: :ok) do
      read_declared(conn)
    end
  end

  defp content_length(conn) do
    with [value] <- get_req_header(conn, "content-length"),
         {length, ""} when length >= 0 <- Integer.parse(value) do
      {:ok, length}
    else
      _ -> {:error, :bad_request, "the request must declare its Content-Length"}
    end
  end

  defp read_declared(conn) do
    case read_body(conn, length: Archive.max_archive_bytes()) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, _conn} -> {:error, :unprocessable, "the archive exceeds 10 MiB"}
      {:error, _reason} -> {:error, :bad_request, "the request body could not be read"}
    end
  end

  defp official_param(nil), do: {:ok, false}
  defp official_param("false"), do: {:ok, false}
  defp official_param("true"), do: {:ok, true}
  defp official_param(_), do: {:error, :bad_request, "official must be true or false"}
end
