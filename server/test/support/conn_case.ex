defmodule ReportServerWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ReportServerWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ReportServerWeb.Endpoint

      use ReportServerWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ReportServerWeb.ConnCase
    end
  end

  setup tags do
    ReportServer.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Setup helper that registers a user with an API token and puts the raw token in the
  request's Authorization header.

      setup :register_and_put_bearer_token
  """
  def register_and_put_bearer_token(%{conn: conn}) do
    user = ReportServer.AccountsFixtures.user_fixture()
    {raw_token, api_token} = ReportServer.AccountsFixtures.api_token_fixture(user)
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer #{raw_token}")
    %{conn: conn, user: user, raw_token: raw_token, api_token: api_token}
  end
end
