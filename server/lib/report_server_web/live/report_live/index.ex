defmodule ReportServerWeb.ReportLive.Index do
  use ReportServerWeb, :live_view

  alias ReportServerWeb.{Auth, TokenService, Aws}
  alias ReportServerWeb.ReportLive.QueryComponent

  @impl true
  def mount(params, session, socket) do
    mode = Map.get(params, "mode", "live")

    if Auth.logged_in?(session) || mode == "demo" do
      portal_credentials = Auth.get_portal_credentials(session)

      {:ok,
      socket
        # assign the session vars for the login/logout links
        |> assign(Auth.public_session_vars(session))
        # track the mode
        |> assign(:mode, mode)
        # get the aws data from the token service via async (the fn is wrapped in a task)
        |> assign_async(:aws_data, fn -> async_get_aws_data(mode, portal_credentials) end)
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

  @impl true
  def handle_info({:jobs, query_id, jobs}, socket) do
    # the job server sends the jobs via a pubsub message to the topic subscribed to in the initial update
    send_update QueryComponent, id: query_id, jobs: jobs
    {:noreply, socket}
  end

  defp async_get_aws_data(mode, portal_credentials) do
    with {:ok, env} <- TokenService.get_env(mode, portal_credentials),
         {:ok, jwt} <- TokenService.get_firebase_jwt(mode, portal_credentials),
         {:ok, workgroup} <- TokenService.get_athena_workgroup(mode, env, jwt),
         {:ok, workgroup_credentials} <- TokenService.get_workgroup_credentials(mode, env, jwt, workgroup),
         {:ok, query_ids} <- Aws.get_workgroup_query_ids(mode, workgroup_credentials, workgroup) do
      {:ok, %{
        aws_data: %{
          mode: mode,
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
