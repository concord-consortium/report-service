defmodule ReportServerWeb.ReportLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServerWeb.{Auth, TokenService, Aws}
  alias ReportServerWeb.ReportLive.QueryComponent

  @impl true
  def mount(_params, session, socket) do
    if Auth.logged_in?(session) do
      portal_credentials = Auth.get_portal_credentials(session)

      {:ok,
      socket
        # assign the session vars for the login/logout links
        |> assign(Auth.public_session_vars(session))
        # get the aws data from the token service via async (the fn is wrapped in a task)
        |> assign_async(:aws_data, fn -> async_get_aws_data(portal_credentials) end)
      }
    else
      {:ok, redirect(socket, to: ~p"/auth/login?return_to=/reports")}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    socket =
      socket
      |> assign(:page_title, "Your Reports")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:trigger_poll, query_id}, socket) do
    # Components send the trigger_poll message after a timeout when the query state is queued or running
    # so we then send an update message to that component telling it to poll for changes.
    # This code is here instead of the component as components do not get info messages.
    send_update QueryComponent, id: query_id, poll: true
    {:noreply, socket}
  end

  defp async_get_aws_data(portal_credentials) do
    with {:ok, jwt} <- TokenService.get_firebase_jwt(portal_credentials),
         {:ok, workgroup} <- TokenService.get_athena_workgroup(jwt),
         {:ok, workgroup_credentials} <- TokenService.get_workgroup_credentials(jwt, workgroup),
         {:ok, query_ids} <- Aws.get_workgroup_query_ids(workgroup_credentials, workgroup) do
      {:ok, %{
        aws_data: %{
          jwt: jwt,
          workgroup: workgroup,
          workgroup_credentials: workgroup_credentials,
          query_ids: query_ids
        }
      }}
    else
      error -> error
    end
  end
end
