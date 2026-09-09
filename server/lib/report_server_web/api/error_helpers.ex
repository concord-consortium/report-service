defmodule ReportServerWeb.Api.ErrorHelpers do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @statuses %{
    "BAD_REQUEST" => 400,
    "NOT_AUTHENTICATED" => 401,
    "NOT_FOUND" => 404,
    "NOT_READY" => 409,
    "PORTAL_DUPLICATE_UNNECESSARY" => 409,
    "EXPIRED_CURSOR" => 410,
    "UNPROCESSABLE" => 422,
    "SERVER_ERROR" => 500,
    "SERVICE_UNAVAILABLE" => 503
  }

  # The code a raised exception renders as, one per status. Not an inversion of @statuses: more
  # than one code can share a status (409 is both NOT_READY and PORTAL_DUPLICATE_UNNECESSARY),
  # and inverting picks whichever the map happens to yield last.
  @primary_code_by_status %{
    400 => "BAD_REQUEST",
    401 => "NOT_AUTHENTICATED",
    404 => "NOT_FOUND",
    409 => "NOT_READY",
    410 => "EXPIRED_CURSOR",
    422 => "UNPROCESSABLE",
    500 => "SERVER_ERROR",
    503 => "SERVICE_UNAVAILABLE"
  }

  @doc """
  The contract error code for a status, used by ErrorJSON to render raised exceptions in the
  same shape as explicitly rendered errors. Unmapped statuses are 500-class SERVER_ERROR.
  """
  def code_for_status(status), do: Map.get(@primary_code_by_status, status, "SERVER_ERROR")

  @doc """
  The HTTP status each contract error code renders as.
  """
  def statuses, do: @statuses

  @doc """
  The one code each status renders as when no code was named, which every status in `statuses/0`
  must have an entry for.
  """
  def primary_code_by_status, do: @primary_code_by_status

  def render_error(conn, code, message, context \\ %{}) do
    conn
    |> put_status(Map.fetch!(@statuses, code))
    |> json(Map.merge(context, %{error: code, message: message}))
    |> halt()
  end

  def not_authenticated(conn), do: render_error(conn, "NOT_AUTHENTICATED", "You must supply a valid API token.")
  def not_found(conn), do: render_error(conn, "NOT_FOUND", "Not found.")
  def bad_request(conn, message), do: render_error(conn, "BAD_REQUEST", message)
  def unprocessable(conn, message), do: render_error(conn, "UNPROCESSABLE", message)
  def service_unavailable(conn, message), do: render_error(conn, "SERVICE_UNAVAILABLE", message)
  def server_error(conn), do: render_error(conn, "SERVER_ERROR", "An internal error occurred.")
end
