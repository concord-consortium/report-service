defmodule ReportServerWeb.Api.ErrorHelpers do
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  @statuses %{
    "BAD_REQUEST" => 400,
    "NOT_AUTHENTICATED" => 401,
    "NOT_FOUND" => 404,
    "NOT_READY" => 409,
    "SERVER_ERROR" => 500
  }

  @codes_by_status Map.new(@statuses, fn {code, status} -> {status, code} end)

  @doc """
  The contract error code for a status, used by ErrorJSON to render raised exceptions in the
  same shape as explicitly rendered errors. Unmapped statuses are 500-class SERVER_ERROR.
  """
  def code_for_status(status), do: Map.get(@codes_by_status, status, "SERVER_ERROR")

  def render_error(conn, code, message, context \\ %{}) do
    conn
    |> put_status(Map.fetch!(@statuses, code))
    |> json(Map.merge(context, %{error: code, message: message}))
    |> halt()
  end

  def not_authenticated(conn), do: render_error(conn, "NOT_AUTHENTICATED", "You must supply a valid API token.")
  def not_found(conn), do: render_error(conn, "NOT_FOUND", "Not found.")
  def bad_request(conn, message), do: render_error(conn, "BAD_REQUEST", message)
  def server_error(conn), do: render_error(conn, "SERVER_ERROR", "An internal error occurred.")
end
