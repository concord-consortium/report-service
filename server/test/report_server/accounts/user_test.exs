defmodule ReportServer.Accounts.UserTest do
  alias ReportServer.Accounts.User

  use ReportServer.DataCase, async: true

  test "users are unique by portal and user_id" do
    params = %{
      portal_server: "example.com",
      portal_user_id: 1,
      portal_login: "test",
      portal_first_name: "Test",
      portal_last_name: "Testerson",
      portal_email: "test@example.com",
      portal_is_admin: false,
    }

    {:ok, _result} = %User{}
      |> User.changeset(params)
      |> Repo.insert()

    # inserting the same portal_server+portal_user_id should fail
    {:error, changeset} = %User{}
      |> User.changeset(params)
      |> Repo.insert()

    refute changeset.valid?

    # changing the portal server should be ok
    {:ok, _result} = %User{}
      |> User.changeset(%{params | portal_server: "example2.com"})
      |> Repo.insert()

    # changing the portal user id should be ok
    {:ok, _result} = %User{}
      |> User.changeset(%{params | portal_user_id: 2})
      |> Repo.insert()
  end
end
