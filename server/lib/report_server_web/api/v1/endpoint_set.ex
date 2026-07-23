defmodule ReportServerWeb.Api.V1.EndpointSet do
  @moduledoc """
  Derives the ordered, authorized per-learner endpoint set for a report run — the once-derived snapshot the
  bulk-read scratch is built from, and the durable authorization basis the attachment endpoint re-derives.
  Shared by BulkExportController and AttachmentController.
  """
  alias ReportServer.PortalDbs
  alias ReportServer.Reports.{ReportFilter, SourceKey}

  @doc """
  Returns {:ok, [%{"remote_endpoint" => ..., "source" => ...}, ...]} | {:ok, []} | {:error, reason}.
  """
  def derive_endpoint_set(user, report_run) do
    case allowed_project_ids_source().get_allowed_project_ids(user) do
      # defensive/unreachable (all role flags false -> AuthPlug 401s before here)
      :none ->
        {:ok, []}

      # empty-permission short-circuit BEFORE any SQL (list_to_in([]) -> "()", so "... IN ()" -> 500)
      [] ->
        {:ok, []}

      # portal permission query FAILED: return it so the caller maps it to a controlled SERVER_ERROR.
      {:error, _reason} = err ->
        err

      _allowed ->
        # nil is a live state; fetch(nil, ...) would FunctionClauseError
        filter = report_run.report_filter || %ReportFilter{}

        case learner_data().fetch(filter, user, allow_empty: true) do
          {:ok, learner_groups} -> {:ok, to_endpoints(learner_groups)}
          {:error, _msg} = err -> err
        end
    end
  end

  # LearnerData.fetch returns groups (grouped by runnable_url); each group's learners carry
  # run_remote_endpoint + runnable_url. Ordered, stable snapshot; source per learner.
  defp to_endpoints(learner_groups) do
    learner_groups
    |> Enum.flat_map(fn group -> Map.get(group, :learners, []) end)
    |> Enum.map(fn l ->
      %{"remote_endpoint" => l.run_remote_endpoint, "source" => derive_source(l.runnable_url)}
    end)
    # Drop any learner whose DERIVED source is not a usable single path segment: nil/"" (hostless url) or one
    # containing "/" (an answersSourceKey with a slash) would make Node build a bad path and silently miss data.
    |> Enum.filter(fn ep ->
      is_binary(ep["source"]) and ep["source"] != "" and not String.contains?(ep["source"], "/")
    end)
  end

  # Total wrapper: a non-binary runnable_url yields nil (then filtered) rather than a FunctionClauseError.
  defp derive_source(url) when is_binary(url), do: SourceKey.from_runnable_url(url)
  defp derive_source(_), do: nil

  def learner_data,
    do: Application.get_env(:report_server, :learner_data, ReportServer.Reports.Athena.LearnerData)

  def allowed_project_ids_source,
    do: Application.get_env(:report_server, :allowed_project_ids_source, PortalDbs)
end
