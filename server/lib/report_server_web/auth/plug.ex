defmodule ReportServerWeb.Auth.Plug do
  import Plug.Conn

  alias ReportServerWeb.Auth

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    # save off the portal param to the session if it exists
    conn = conn |> Auth.save_portal_url()

    # this enables us to know which link to show: login or logout
    session = conn |> get_session()
    conn |> merge_assigns(Auth.public_session_vars(session))
  end

end
