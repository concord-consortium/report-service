defmodule ReportServerWeb.Api.V1.PackageController do
  use ReportServerWeb, :controller

  alias ReportServer.{Packages, PortalDbs}
  alias ReportServer.Packages.{Archive, Identity, Patterns}
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
    store_failed: "SERVICE_UNAVAILABLE",
    unavailable: "SERVICE_UNAVAILABLE"
  }

  # a profile's 500 assignment URLs plus its 500 interactive URLs, each within the deriver's limit
  @max_scope_urls 1_000
  @max_url_length 2_048

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

  # Never answers 404: cc-data reads a 404 from this route as a server without it.
  def validate(conn, params) do
    with :ok <- zip_content_type(conn),
         {:ok, body, conn} <- read_archive(conn),
         {:ok, official?} <- official_param(params["official"]),
         {:ok, validated} <- Packages.validate(conn.assigns.current_user, body, params["origin"], official?) do
      json(conn, validated)
    else
      {:error, kind, message} -> ErrorHelpers.render_error(conn, Map.fetch!(@error_codes, kind), message)
    end
  end

  # Never answers 404, as validate. Assignment URLs are followed by report-service's deriver; scope
  # URLs are matched as given.
  def applies(conn, params) do
    with {:ok, urls} <- applies_patterns(params["urls"]),
         {:ok, assignment_urls} <- string_list(params, "assignment_urls"),
         {:ok, scope_urls} <- scope_urls(params),
         {:ok, derived} <- derive(assignment_urls) do
      verdict = Patterns.applies(urls, assignment_urls ++ derived["interactive_urls"] ++ scope_urls)

      json(conn, %{
        applies: verdict == :ok,
        reason: with({:error, reason} <- verdict, do: reason, else: (_ -> nil)),
        interactive_urls: derived["interactive_urls"],
        unread: derived["unread"],
        truncated: derived["truncated"]
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

  def index(conn, params), do: list_packages(conn, params, nil)

  # The list with each row marked as applying to the scope's URLs or not, which a GET cannot carry.
  # scope_urls is required, so a body that was never read is refused rather than read as no URLs.
  def list(conn, params) do
    with true <- Map.has_key?(params, "scope_urls") || {:error, :bad_request, "scope_urls is required, possibly empty"},
         {:ok, urls} <- scope_urls(params) do
      list_packages(conn, params, urls)
    else
      {:error, kind, message} -> ErrorHelpers.render_error(conn, Map.fetch!(@error_codes, kind), message)
    end
  end

  defp list_packages(conn, params, scope_urls) do
    result =
      case conn.assigns[:portal_claims] do
        nil ->
          with {:ok, server} <- portal_param(params["portal"]), do: {:ok, Packages.list_official(server)}

        claims ->
          with {:ok, reader} <- Packages.reader(claims), do: {:ok, Packages.list_visible(reader)}
      end

    case result do
      {:ok, entries} -> conn |> no_store() |> json(PackageJSON.index(entries, scope_urls))
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

  # Parsed, so parameters and case are allowed and a longer subtype such as application/zipfoo is not.
  defp zip_content_type(conn) do
    with [value] <- get_req_header(conn, "content-type"),
         {:ok, "application", "zip", _params} <- Plug.Conn.Utils.media_type(value) do
      :ok
    else
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

  # Required, so a body that was never read (not JSON) is refused rather than read as "no
  # patterns". cc-data builds the groups from Go slices, and a nil slice arrives as null.
  defp applies_patterns(urls) when is_map(urls) do
    urls |> Map.reject(fn {_group, patterns} -> is_nil(patterns) end) |> Patterns.validate() |> bad_request()
  end

  defp applies_patterns(_urls), do: {:error, :bad_request, "urls must be an object of all, any and none arrays"}

  defp bad_request({:error, message}), do: {:error, :bad_request, message}
  defp bad_request(ok), do: ok

  # code points, the unit Manifest counts: never more than the function's UTF-16 count of the same
  # URL, so a URL the deriver keeps always passes, and unlike graphemes they bound the matcher's work
  defp scope_urls(params) do
    with {:ok, urls} <- string_list(params, "scope_urls") do
      if length(urls) <= @max_scope_urls and Enum.all?(urls, &(length(String.codepoints(&1)) <= @max_url_length)),
        do: {:ok, urls},
        else: {:error, :bad_request, "scope_urls must hold at most #{@max_scope_urls} URLs of at most #{@max_url_length} characters"}
    end
  end

  defp string_list(params, key) do
    case Map.get(params, key) do
      nil -> {:ok, []}
      list when is_list(list) -> if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: {:error, :bad_request, "#{key} must be an array of strings"}
      _ -> {:error, :bad_request, "#{key} must be an array of strings"}
    end
  end

  defp derive([]), do: {:ok, %{"interactive_urls" => [], "unread" => [], "truncated" => false}}

  # the function's bounds on assignment URLs are the only copy, so its 400 comes back as a 400
  defp derive(assignment_urls) do
    case report_service().derive_urls(assignment_urls) do
      {:ok, derived} -> {:ok, derived}
      {:error, {:bad_request, message}} -> {:error, :bad_request, message}
      {:error, _} -> {:error, :unavailable, "report-service could not derive the assignments' interactive URLs; retry"}
    end
  end

  defp report_service, do: Application.get_env(:report_server, :report_service_client, ReportServer.ReportService)

  defp official_param(nil), do: {:ok, false}
  defp official_param("false"), do: {:ok, false}
  defp official_param("true"), do: {:ok, true}
  defp official_param(_), do: {:error, :bad_request, "official must be true or false"}
end
