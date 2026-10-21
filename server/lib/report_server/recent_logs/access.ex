defmodule ReportServer.RecentLogs.Access do
  @moduledoc """
  The caller of a class read and the class's learners as that caller. An access-token caller is
  resolved to its report-server user row, created or refreshed from the portal's user row, so its
  Athena workgroup and audit rows are the ones its report runs use; its role flags are therefore
  read from the portal on every request.
  """
  alias ReportServer.{Accounts, PortalDbs}
  alias ReportServer.Reports.ReportFilter

  @portal_timeout_ms 5_000

  @doc """
  The `%User{}` asking, or `{:error, :forbidden | :not_authenticated | :portal_unavailable}`. A
  portal user whose row cannot be stored as a report-server user (a required field blank) is
  `:not_authenticated` on every call.
  """
  def caller(%{assigns: %{current_user: user}}, _class_id), do: {:ok, user}

  def caller(%{assigns: %{portal_claims: claims}}, class_id) do
    with :ok <- context_names(claims["context"], class_id),
         server = PortalDbs.get_server_for_portal_url(claims["iss"]),
         true <- (is_binary(server) and PortalDbs.has_db_connection?(server)) || {:error, :not_authenticated},
         {:ok, info} <- user_info(server, claims["uid"]),
         true <- Accounts.storable_portal_user?(info) || {:error, :not_authenticated},
         {:ok, user} <- stored_user(info) do
      {:ok, user}
    end
  end

  # concurrent first requests can both insert; the loser's retry finds the winner's row
  defp stored_user(info) do
    Accounts.find_or_create_user(info)
  rescue
    Ecto.ConstraintError -> Accounts.find_or_create_user(info)
  end

  defp context_names(%{"type" => "class", "id" => id}, id), do: :ok
  defp context_names(_, _), do: {:error, :forbidden}

  defp user_info(server, uid) when is_integer(uid) do
    case PortalDbs.get_user_info_by_id(server, uid, timeout: @portal_timeout_ms) do
      {:ok, info} -> {:ok, info}
      {:error, :not_found} -> {:error, :not_authenticated}
      _ -> {:error, :portal_unavailable}
    end
  end

  defp user_info(_, _), do: {:error, :not_authenticated}

  @doc """
  The class's learners as `user` sees them, or `{:error, :forbidden}` when the class is outside
  the caller's grants (whether or not it exists), `{:error, :portal_unavailable}` when the portal
  cannot be asked.
  """
  def learners(user, class_id) do
    filter = %ReportFilter{class: [class_id]}

    with {:ok, _values} <- ReportFilter.get_filter_values(filter, user),
         {:ok, groups} <- learner_data().fetch(filter, user, allow_empty: true) do
      {:ok, Enum.flat_map(groups, & &1.learners)}
    else
      {:error, :out_of_scope, _missing} -> {:error, :forbidden}
      {:error, _reason} -> {:error, :portal_unavailable}
    end
  end

  defp learner_data, do: Application.get_env(:report_server, :learner_data, ReportServer.Reports.Athena.LearnerData)
end
