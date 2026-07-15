defmodule ReportServer.Exports do
  @moduledoc """
  Server-side scratch store for STORY-3 bulk exports: the once-derived authorized endpoint snapshot,
  keyed by an unguessable `scratch_id` capability, with a two-step (404 vs 410) read-time expiry lookup,
  an absolute sliding TTL, and a periodic + boot sweep (see `ReportServer.Exports.SweepServer`).
  """
  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Multi
  alias ReportServer.Repo
  alias ReportServer.Exports.ExportScratch
  alias ReportServer.AuditLog.DataAccessLogEntry

  @ttl_seconds 60 * 60

  @doc "Mint an unguessable capability (NOT the table PK), reusing the auth_grants/api_token idiom."
  def mint_scratch_id, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  def ttl_expires_at, do: DateTime.utc_now(:second) |> DateTime.add(@ttl_seconds)

  @doc """
  Page-1 atomicity: insert the scratch row and its intent audit row both-or-neither.
  Returns {:ok, %{scratch: %ExportScratch{}, intent: %DataAccessLogEntry{}}} | {:error, step, changeset, _}.
  """
  def create_scratch_with_intent(scratch_attrs, intent_attrs) do
    Multi.new()
    |> Multi.insert(:scratch, ExportScratch.changeset(%ExportScratch{}, scratch_attrs))
    |> Multi.insert(:intent, DataAccessLogEntry.changeset(%DataAccessLogEntry{}, intent_attrs))
    |> Repo.transaction()
  end

  @doc """
  Two-step read-time lookup for a page load. Ownership+route identity match with NO expiry predicate:
    * no row                       -> :not_found  (forged / cross-user / cross-run / cross-route / swept)
    * matched but expires_at <= now -> delete (scoped) and return :expired (-> 410 EXPIRED_CURSOR)
    * matched and active            -> bump TTL absolutely and return {:ok, scratch}
  """
  def fetch_for_page(scratch_id, user_id, report_run_id, data_type) do
    now = DateTime.utc_now(:second)

    query =
      from s in ExportScratch,
        where:
          s.scratch_id == ^scratch_id and s.user_id == ^user_id and
            s.report_run_id == ^report_run_id and s.data_type == ^data_type

    case Repo.one(query) do
      nil ->
        :not_found

      %ExportScratch{expires_at: expires_at} = scratch ->
        if DateTime.compare(expires_at, now) == :gt do
          {:ok, bump_ttl(scratch)}
        else
          delete_scoped(scratch_id, user_id, report_run_id, data_type)
          :expired
        end
    end
  end

  # absolute SET (never expires_at + delta) so concurrent same-token retries converge and stay idempotent
  defp bump_ttl(%ExportScratch{} = scratch) do
    new_expires_at = ttl_expires_at()

    {_n, _} =
      from(s in ExportScratch, where: s.scratch_id == ^scratch.scratch_id)
      |> Repo.update_all(set: [expires_at: new_expires_at])

    %ExportScratch{scratch | expires_at: new_expires_at}
  end

  defp delete_scoped(scratch_id, user_id, report_run_id, data_type) do
    from(s in ExportScratch,
      where:
        s.scratch_id == ^scratch_id and s.user_id == ^user_id and
          s.report_run_id == ^report_run_id and s.data_type == ^data_type
    )
    |> Repo.delete_all()
  end

  @doc """
  Merge Node's freshly-derived LTI tuples into the cached snapshot (tuple cache), so the per-learner
  `answers ... limit 1` derivation runs once per export. `touched` is [%{"remote_endpoint" => e,
  "lti_tuple" => t}, ...]. Idempotent; persists the updated endpoint_set.
  """
  def merge_touched_endpoints(%ExportScratch{} = scratch, touched) when is_list(touched) do
    by_endpoint = Map.new(touched, fn t -> {t["remote_endpoint"], t["lti_tuple"]} end)

    if map_size(by_endpoint) == 0 do
      scratch
    else
      updated =
        Enum.map(scratch.endpoint_set, fn ep ->
          case Map.get(by_endpoint, ep["remote_endpoint"]) do
            nil -> ep
            tuple -> Map.put(ep, "lti_tuple", tuple)
          end
        end)

      # fail-OPEN, and ONLY here: the tuple cache is a pure optimization (Node re-derives a nil lti_tuple),
      # so a cache-write failure must never fail an already-successful page. Every audit write stays fail-closed.
      case scratch |> Ecto.Changeset.change(endpoint_set: updated) |> Repo.update() do
        {:ok, updated_scratch} ->
          updated_scratch

        {:error, _changeset} ->
          Logger.warning(
            "Exports.merge_touched_endpoints: tuple-cache update failed; will re-derive next page"
          )

          scratch
      end
    end
  end

  def merge_touched_endpoints(scratch, _), do: scratch

  @doc "Storage-reclaim sweep (periodic + boot). Correctness never depends on it — expired rows are already invisible."
  def sweep_expired do
    now = DateTime.utc_now(:second)
    {count, _} = from(s in ExportScratch, where: s.expires_at < ^now) |> Repo.delete_all()
    count
  end
end
