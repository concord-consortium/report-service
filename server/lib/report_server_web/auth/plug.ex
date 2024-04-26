defmodule ReportServerWeb.Auth.Plug do
  import Plug.Conn

  alias ReportServerWeb.Auth

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
      # save off the portal param to the session if it exists
      |> Auth.save_portal_url()
      # this enables us to know which link to show: login or logout
      |> merge_assigns(Auth.public_session_vars(get_session(conn)))
  end

end
