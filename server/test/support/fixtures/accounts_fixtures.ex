defmodule ReportServer.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `ReportServer.Accounts` context.
  """

  alias ReportServer.Accounts
  alias ReportServer.Accounts.User
  alias ReportServer.Repo

  def user_fixture(attrs \\ %{}) do
    defaults = %{
      portal_server: "learn.concord.org",
      portal_user_id: System.unique_integer([:positive]),
      portal_login: "user#{System.unique_integer([:positive])}",
      portal_first_name: "Test",
      portal_last_name: "User",
      portal_email: "test#{System.unique_integer([:positive])}@example.com",
      portal_is_admin: false,
      portal_is_project_admin: false,
      portal_is_project_researcher: true
    }

    struct(User, Map.merge(defaults, Map.new(attrs))) |> Repo.insert!()
  end

  def api_token_fixture(user, label \\ nil) do
    {:ok, raw_token, api_token} = Accounts.create_api_token(user, label)
    {raw_token, api_token}
  end
end
