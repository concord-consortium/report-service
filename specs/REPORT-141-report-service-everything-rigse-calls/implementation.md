# Implementation Plan: report-service: everything rigse calls

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-141
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

Seven steps, one commit each. report-server's three come first (key verification, token expiry, the mint endpoint), then the function's four (key verification, the dashboard function with validation and queueing, the VM ensure step, configuration). Every step is independently testable: report-server's with `mix test` against the port-3406 MySQL, the function's with Jest on Node 22 using injected fakes for Firestore, the MicroVM API and `fetch`, as the spike's `run-package.test.ts` does.

### report-server: verify rigse's portal tokens by `kid`, bound to an issuer

**Summary**: Adds `joken`, a `PortalKeys` config read from `PORTAL_PUBLIC_KEYS`, and `PortalToken.verify/2`, which picks the key by `kid`, requires that key's issuer, pins RS256, and checks `aud` and `exp` itself. A `PortalTokenPlug` exposes the verified claims for a given audience. Nothing routes through it yet. Covers R1 to R5 (report-server).

**Files affected**:
- `server/mix.exs`, `server/mix.lock` — `{:joken, "~> 2.7"}`
- `server/config/runtime.exs` — `config :report_server, :portal_public_keys, System.get_env("PORTAL_PUBLIC_KEYS")`
- `server/config/test.exs` — a test key set (see below)
- `server/lib/report_server_web/api/portal_keys.ex` — new
- `server/lib/report_server_web/api/portal_token.ex` — new
- `server/lib/report_server_web/api/portal_token_plug.ex` — new
- `server/test/report_server_web/api/portal_token_test.exs` — new
- `server/test/support/portal_token_fixture.ex` — new: generates keypairs and signs test tokens

**Estimated diff size**: ~300 lines

`PORTAL_PUBLIC_KEYS` is a JSON array, the same value the function takes:

```json
[{"kid": "production-2026-09", "iss": "https://learn.concord.org/", "pem": "-----BEGIN PUBLIC KEY-----\n...\n-----END PUBLIC KEY-----\n"}]
```

```elixir
defmodule ReportServerWeb.Api.PortalKeys do
  @moduledoc """
  rigse's public keys, one entry per portal key: its kid, the PEM, and the one issuer
  (portal site URL) that key may sign for. One report-server serves the staging and the
  production portals, so a key is trusted only for its own issuer; picking by kid alone
  would let the staging key sign for production.
  """

  @spec lookup(String.t()) :: {:ok, %{pem: String.t(), iss: String.t()}} | {:error, :unknown_kid}
  def lookup(kid) when is_binary(kid) do
    case Map.fetch(keys(), kid) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :unknown_kid}
    end
  end
  def lookup(_), do: {:error, :unknown_kid}

  defp keys do
    case Application.get_env(:report_server, :portal_public_keys) do
      json when is_binary(json) and json != "" ->
        json
        |> Jason.decode!()
        |> Map.new(fn %{"kid" => kid, "iss" => iss, "pem" => pem} -> {kid, %{iss: iss, pem: pem}} end)
      _ -> %{}
    end
  end
end
```

```elixir
defmodule ReportServerWeb.Api.PortalToken do
  @moduledoc """
  Verifies an RS256 token rigse signed. The key comes from the kid, the issuer must be
  that key's, the algorithm is pinned, and aud and exp are checked here: Joken.verify/2
  checks neither, and accepts an aud list (REPORT-141 Verification).
  """
  alias ReportServerWeb.Api.PortalKeys

  @spec verify(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def verify(token, audience) when is_binary(token) do
    with {:ok, %{"alg" => "RS256", "kid" => kid}} <- peek_header(token),
         {:ok, %{pem: pem, iss: iss}} <- PortalKeys.lookup(kid),
         {:ok, claims} <- Joken.verify(token, Joken.Signer.create("RS256", %{"pem" => pem})),
         :ok <- check(claims["iss"] == iss, :wrong_issuer),
         :ok <- check(claims["aud"] == audience, :wrong_audience),
         :ok <- check_expiry(claims["exp"]) do
      {:ok, claims}
    else
      {:ok, _header} -> {:error, :unsupported_header}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid}
    end
  end
  def verify(_, _), do: {:error, :invalid}

  defp peek_header(token) do
    case Joken.peek_header(token) do
      {:ok, header} -> {:ok, header}
      _ -> {:error, :malformed}
    end
  end

  defp check(true, _), do: :ok
  defp check(_, reason), do: {:error, reason}

  defp check_expiry(exp) when is_integer(exp) do
    if exp > System.system_time(:second), do: :ok, else: {:error, :expired}
  end
  defp check_expiry(_), do: {:error, :no_expiry}
end
```

The header's `alg` is only compared against `"RS256"` to refuse early; the key and algorithm used to verify come from the configuration, never from the token.

```elixir
defmodule ReportServerWeb.Api.PortalTokenPlug do
  @moduledoc "Authenticates a request by an rigse-signed token for one audience, and assigns its claims."
  import Plug.Conn
  alias ReportServerWeb.Api.{ErrorHelpers, PortalToken}

  def init(opts), do: Keyword.fetch!(opts, :audience)

  def call(conn, audience) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- PortalToken.verify(token, audience) do
      assign(conn, :portal_claims, claims)
    else
      _ -> conn |> ErrorHelpers.not_authenticated() |> halt()
    end
  end
end
```

`config/test.exs` sets `:portal_public_keys` at test start from `PortalTokenFixture`, which generates a "staging" and a "production" keypair once per test run with `:public_key.generate_key({:rsa, 2048, 65537})`, holds the private keys for signing, and exposes `sign(key, claims, opts)` (with overrides for the header, so the alg-confusion and `none` cases can be built).

**Tests** (`portal_token_test.exs`), the Verification matrix as assertions: accepted for a correct token; refused for the staging key claiming production's `iss` (`:wrong_issuer`), the production key under the staging `kid`, an unknown `kid`, no `kid`, HS256 signed with the public PEM, `alg: none`, a wrong `aud`, an `aud` list containing the expected value, an expired token, and one with no `exp`. `PortalTokenPlug`: assigns claims for its audience and answers `NOT_AUTHENTICATED` for a token of another audience.

---

### report-server: dashboard tokens expire, and expired tokens are not live

**Summary**: Adds `api_tokens.expires_at`, makes `verify_api_token/1` and the four listing and lookup queries treat a passed `expires_at` as dead, and lets `create_api_token` take an expiry. Independent of the previous step. Covers R10.

**Files affected**:
- `server/priv/repo/migrations/20260924120000_add_expires_at_to_api_tokens.exs` — new
- `server/lib/report_server/accounts/api_token.ex` — `field :expires_at, :utc_datetime`, cast
- `server/lib/report_server/accounts.ex` — a `live/1` query helper used by `verify_api_token`, `list_active_api_tokens`, `get_user_api_token`, `get_active_api_token`, `list_all_active_api_tokens`; `create_api_token(user, label, opts \\ [])` with `expires_in:`
- `server/test/report_server/accounts_test.exs` (or the existing token tests) — expiry cases

**Estimated diff size**: ~120 lines

```elixir
defmodule ReportServer.Repo.Migrations.AddExpiresAtToApiTokens do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      # Nullable: set only on dashboard tokens. cc-data's CLI tokens share the table and never expire.
      add :expires_at, :utc_datetime
    end
  end
end
```

```elixir
  # Not revoked, and not past an expiry if it has one.
  defp live(query) do
    now = DateTime.utc_now(:second)
    from t in query, where: is_nil(t.revoked_at) and (is_nil(t.expires_at) or t.expires_at > ^now)
  end
```

Each of the five queries replaces its `is_nil(t.revoked_at)` clause with a pipe through `live/1`; `revoke_api_token/2` keeps its own `is_nil(t.revoked_at)`, since revoking an expired token is harmless and keeps the audit trail.

**Tests**: a token with `expires_at` in the past fails `verify_api_token` and is absent from both listings and both lookups; one in the future passes; a token with `expires_at` `NULL` passes (the CLI case). The existing CLI-token and all-tokens LiveView tests pass unchanged.

---

### report-server: the mint endpoint, with single-use assertions

**Summary**: Adds `POST /api/v1/dashboard-tokens` behind `PortalTokenPlug` for `aud: report-server`, a `used_portal_assertions` table that makes each `jti` single-use, and `Accounts.mint_dashboard_token/1`, which finds or creates the user from the claims, revokes their live dashboard tokens and mints one expiring in nine hours. Covers R6 to R9.

**Files affected**:
- `server/priv/repo/migrations/20260924120100_create_used_portal_assertions.exs` — new
- `server/lib/report_server/accounts/used_portal_assertion.ex` — new schema
- `server/lib/report_server/accounts.ex` — `claim_assertion_jti/2`, `mint_dashboard_token/1`, `revoke_dashboard_tokens/1`
- `server/lib/report_server_web/api/v1/dashboard_token_controller.ex` — new
- `server/lib/report_server_web/router.ex` — a `:api_portal_assertion` pipeline and the route, above the `/api/v1` catch-all
- `server/test/report_server_web/api/v1/dashboard_token_controller_test.exs` — new

**Estimated diff size**: ~320 lines

```elixir
  def change do
    create table(:used_portal_assertions) do
      add :jti, :string, null: false
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end
    create unique_index(:used_portal_assertions, [:jti])
  end
```

```elixir
  @doc """
  Records an assertion's jti, or refuses one already used. The unique index makes the
  insert the check, so it holds across restarts and more than one node. Expired rows are
  pruned on the way in; they could never match a live assertion again.
  """
  def claim_assertion_jti(jti, exp) when is_binary(jti) and jti != "" and is_integer(exp) do
    now = DateTime.utc_now(:second)
    Repo.delete_all(from u in UsedPortalAssertion, where: u.expires_at < ^now)

    %UsedPortalAssertion{}
    |> UsedPortalAssertion.changeset(%{jti: jti, expires_at: DateTime.from_unix!(exp)})
    |> Repo.insert()
    |> case do
      {:ok, _} -> :ok
      {:error, _changeset} -> {:error, :replayed}
    end
  end
  def claim_assertion_jti(_, _), do: {:error, :no_jti}
```

```elixir
  @dashboard_token_label "researcher-dashboard"
  # Just past the eight-hour maximum life of the VM that holds it. Nothing revokes the token
  # of a VM that dies without running /terminate, so this is the backstop.
  @dashboard_token_ttl_seconds 9 * 60 * 60

  def mint_dashboard_token(portal_user_info = %PortalUserInfo{}) do
    Repo.transaction(fn ->
      with {:ok, user} <- find_or_create_user(portal_user_info),
           {:ok, _count} <- revoke_dashboard_tokens(user),
           {:ok, raw, token} <- create_api_token(user, @dashboard_token_label, expires_in: @dashboard_token_ttl_seconds) do
        {user, raw, token}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
```

`revoke_dashboard_tokens/1` is the spike's (`accounts.ex` on the spike branch): live dashboard-labeled tokens for the user, `revoked_by_user_id` set to the user themselves.

The controller reads everything from `conn.assigns.portal_claims`:

```elixir
  def create(conn, _params) do
    claims = conn.assigns.portal_claims
    server = PortalDbs.get_server_for_portal_url(claims["iss"])

    with :ok <- known_portal(server, claims["portal_server"]),
         :ok <- Accounts.claim_assertion_jti(claims["jti"], claims["exp"]),
         {:ok, info} <- portal_user_info(claims, server),
         {:ok, {user, raw_token, api_token}} <- Accounts.mint_dashboard_token(info) do
      conn |> put_status(:created) |> json(%{token: raw_token, expires_at: api_token.expires_at, user_id: user.id})
    else
      {:error, :replayed} -> ErrorHelpers.not_authenticated(conn)
      {:error, :no_jti} -> ErrorHelpers.not_authenticated(conn)
      {:error, :unknown_portal} -> ErrorHelpers.not_authenticated(conn)
      {:error, message} when is_binary(message) -> ErrorHelpers.bad_request(conn, message)
      _ -> ErrorHelpers.server_error(conn)
    end
  end

  # The portal is the token's iss, which the signature binds; portal_server must agree, and
  # report-server must be connected to it.
  defp known_portal(server, claimed) do
    if claimed == server and PortalDbs.has_db_connection?(server), do: :ok, else: {:error, :unknown_portal}
  end
```

`portal_user_info/2` builds `%PortalUserInfo{}` from `portal_user_id` (required integer), `server`, `login`, `first_name`, `last_name`, `email` and the three flags (`!!`), and returns `{:error, "..."}` naming a missing required field.

Router, above the catch-all scope:

```elixir
  pipeline :api_portal_assertion do
    plug :force_json
    plug ReportServerWeb.Api.PortalTokenPlug, audience: "report-server"
  end

  scope "/api/v1", ReportServerWeb.Api.V1 do
    pipe_through :api_portal_assertion
    post "/dashboard-tokens", DashboardTokenController, :create
  end
```

**Tests** (tests set `LEARN_PORTAL_STAGING_CONCORD_ORG_DB` for the portal's `has_db_connection?`): 201 with a token that `verify_api_token` accepts and whose `expires_at` is nine hours out; a second mint revokes the first; a replayed assertion is 401 and mints nothing; an assertion without `jti` is 401; one for a portal with no DB connection, or whose `portal_server` disagrees with `iss`, is 401; one of another audience is 401; the body is ignored (a body naming another user changes nothing); the user row is created on first mint and its flags updated on the next; a jti row older than its expiry is pruned.

---

### function: verify rigse's portal tokens

**Summary**: Adds `jsonwebtoken` 9 and `researcher-dashboard/portal-token.ts`, the function-side twin of report-server's verifier: key by `kid` from `PORTAL_PUBLIC_KEYS`, bound issuer, RS256 pinned, `aud` and `exp` checked explicitly. Covers R1 to R4 (function).

**Files affected**:
- `functions/package.json`, `functions/package-lock.json` — `jsonwebtoken@^9`, `@types/jsonwebtoken@^9`
- `functions/src/researcher-dashboard/portal-token.ts` — new
- `functions/src/researcher-dashboard/portal-token.test.ts` — new

**Estimated diff size**: ~200 lines

```ts
import jwt from "jsonwebtoken"
import { createPublicKey, KeyObject } from "crypto"

export interface PortalKey { kid: string; iss: string; pem: string }
export interface PortalClaims { iss: string; uid: number; aud: string; exp: number; [k: string]: unknown }

export class PortalTokenError extends Error {}

// Parsed once per configuration string. A KeyObject, never a PEM string, is what reaches
// the verifier, so no code path can hand the public key to an HMAC check.
export function parsePortalKeys(json: string): Map<string, { iss: string; key: KeyObject }> {
  const entries = JSON.parse(json || "[]") as PortalKey[]
  return new Map(entries.map(e => [e.kid, { iss: e.iss, key: createPublicKey(e.pem) }]))
}

export function verifyPortalToken(token: string, audience: string, keys: Map<string, { iss: string; key: KeyObject }>): PortalClaims {
  const decoded = jwt.decode(token, { complete: true })
  const kid = decoded?.header?.kid
  const entry = kid ? keys.get(kid) : undefined
  if (!entry) throw new PortalTokenError("unknown or missing kid")
  // jsonwebtoken accepts a token with no exp and an aud array containing the expected
  // value (REPORT-141 Verification), so both are checked here as well.
  const claims = jwt.verify(token, entry.key, { algorithms: ["RS256"], issuer: entry.iss, audience }) as PortalClaims
  if (typeof claims.aud !== "string") throw new PortalTokenError("aud must be a single string")
  if (typeof claims.exp !== "number") throw new PortalTokenError("exp is required")
  if (typeof claims.uid !== "number") throw new PortalTokenError("uid is required")
  return claims
}
```

**Tests**: the Verification matrix again, generated with `crypto.generateKeyPairSync` for two keys: accepted; staging key claiming production's `iss`; production key under the staging `kid`; unknown and missing `kid`; HS256 signed with the public PEM; `alg: none`; wrong `aud`; `aud` array; expired; no `exp`. `parsePortalKeys` accepts the single-quoted `.env` form (the value `firebase-tools`' parser produces, checked in stage 5) and throws on malformed JSON.

---

### function: the dashboard function, `/run-package` validation and queueing

**Summary**: Adds a separate HTTPS function, `researcherDashboard`, an express app with no shared-bearer middleware, and its `POST /run-package` handler up to and including the atomic queue write. The VM step is a no-op seam in this commit and is filled in by the next one. Covers R11 to R15, and R20's validation and 202.

**Files affected**:
- `functions/src/researcher-dashboard/app.ts` — new: the express app, auth middleware for `aud: report-service-functions`, the route
- `functions/src/researcher-dashboard/run-package.ts` — new: `makeRunPackage(deps)` with validation, identity from the assertion, and the Firestore write
- `functions/src/researcher-dashboard/firestore-paths.ts` — new: `portalSegment(iss)`, `packageKey(identity)`, the document paths
- `functions/src/researcher-dashboard/run-package.test.ts` — new
- `functions/src/researcher-dashboard/config.ts` — new: the function's params and secrets, `defineSecret("RD_AWS_KEY")`, `defineSecret("RD_AWS_SECRET_KEY")`, `defineString` for `PORTAL_PUBLIC_KEYS`, `RD_MICROVM_IMAGE_ARN`, `RD_EXECUTION_ROLE_ARN`, `RD_DATA_BUCKET`, `RD_REPORT_SERVER_URL`, an optional `RD_FUNCTION_URL`, and `defineInt("RD_QUEUE_CAP", { default: 20 })`, declared here because this step's function references the secrets
- `functions/src/index.ts` — `researcherDashboard` declared and added to the `module.exports` object

**Estimated diff size**: ~480 lines

The function is declared in `index.ts` beside `api`, holding only its own secrets (added in the configuration step). It is exported as a key of the `module.exports` object the file ends with, not with `export const`:

```ts
const researcherDashboard = functions
  .runWith({ secrets: [rdAwsKey, rdAwsSecretKey], timeoutSeconds: 60 })
  .https.onRequest(researcherDashboardApp())

module.exports = {
  api: wrappedApi,
  // ...the existing keys...
  researcherDashboard,
}
```

The auth middleware verifies the bearer with `verifyPortalToken(token, "report-service-functions", keys)` and sets `res.locals.researcher = { platformUserId: String(claims.uid), platformId: claims.iss, portal: portalSegment(claims.iss) }`; anything else is 401. A bearer in the query or body is refused as `requireHeaderBearer` does.

`firestore-paths.ts`:

```ts
// The portal host with dots as underscores, the convention CLUE and report-service share.
export const portalSegment = (iss: string) => new URL(iss).host.replace(/\./g, "_")
// Identity with "/" as "__": single segment, reversible, readable (final-design 9).
export const packageKey = (identity: string) => identity.replace(/\//g, "__")
export const root = (portal: string) => `researcher_dashboard/${portal}`
```

Validation, before any write (R13, R14): `packages` a non-empty array of `{identity, version, checksum, catalog_id}` with `identity` matching `^(users|projects)/[0-9]+/[a-z0-9][a-z0-9-]{0,62}$`, `checksum` matching `^sha256:[0-9a-f]{64}$` (the catalog's form, which rigse forwards unchanged and the runner compares against), `catalog_id` a positive integer; `scope.kind === "class"`, `scope.classes` exactly one `{class_hash, class_id}`, `scope.assignments` an array of `{offering_id, runnable_id, name, url}` with the two ids positive integers, `name` a string or null and `url` a string, which may be empty (the portal's stored value, RIGSE-368 R8); `class_tokens` a non-empty object; `session_token` and `firebase_project` non-empty strings; `report_server_assertion` verifies as `aud: report-server` with the same `uid` and `iss` (R13). Any failure is 400 with the field named. The queue cap is checked inside the transaction below, where the current queue is known, and is 409 with `queue at its cap (N outstanding)`.

The write (R15) is one Firestore transaction:

```ts
await deps.db.runTransaction(async tx => {
  const workRef = deps.db.doc(`${root(portal)}/work/${platformUserId}`)
  const work = (await tx.get(workRef)).data() as WorkDoc | undefined
  const entryKey = (e: { class_hash: string; identity: string }) => `${e.class_hash}/${packageKey(e.identity)}`
  // Keyed by class and package: the same package queued for two classes is two entries.
  const queued = new Set((work?.packages ?? []).map(entryKey))
  const appended = body.packages
    .map(p => ({ ...p, class_hash: classHash }))
    .filter(p => !queued.has(entryKey(p)))
  if (queued.size + appended.length > deps.config.queueCap) {
    throw new Refusal(409, `queue at its cap (${deps.config.queueCap} outstanding)`)
  }

  tx.set(workRef, {
    packages: [...(work?.packages ?? []), ...appended],
    // One scope block and one set of class tokens per class, so a second class's request
    // never overwrites the first's.
    scopes: { [classHash]: { scope: body.scope, class_tokens: body.class_tokens } },
    session_token: body.session_token,
    firebase_project: body.firebase_project,
    updated_at: now
  }, { merge: true })
  for (const p of appended) {
    tx.set(deps.db.doc(`${root(portal)}/classes/${classHash}/researchers/${platformUserId}/results/${packageKey(p.identity)}`),
           { status: "queued", queued_at: now, updated_at: now, platform_id: platformId,
             package: { identity: p.identity, version: p.version, checksum: p.checksum } })
  }
  const queue = [...(work?.packages ?? []), ...appended].map(e => ({ class_hash: e.class_hash, package_key: packageKey(e.identity) }))
  tx.set(deps.db.doc(`${root(portal)}/runners/${platformUserId}`), { queue, platform_id: platformId, updated_at: now }, { merge: true })
})
```

`{ merge: true }` on `work/` merges the `scopes` map key by key, so `scopes.{class_hash}` for another class survives. `session_token` and `firebase_project` are per researcher rather than per class and are simply refreshed.

`now` is `admin.firestore.FieldValue.serverTimestamp()`, imported as `import * as admin from "firebase-admin"` because Jest 24 cannot resolve the `firebase-admin/firestore` subpath (checked in stage 7; the repo's own `chat/drain.test.ts` imports it this way), so the timestamps are Firestore timestamps (the watchdog queries them as ranges, REPORT-143). A `Refusal` thrown inside aborts the transaction, so a 409 writes nothing.

The response is 202 `{ queue: [...package keys], appended: [...], vm: <from the VM step> }`.

**Tests** (a Firestore fake behind `deps.db` implementing `doc`, `runTransaction`, `get`, `set`): a valid request writes the work document, one `queued` result per package and the runner queue in one transaction; a second request with one overlapping package appends only the new one; the same package requested for a second class is appended as a second entry, and the first class's `scopes` entry and class tokens are untouched; a malformed body of each kind is 400 and writes nothing, including a bare-hex checksum without its `sha256:` prefix; an assignment with `url: ""` and `name: null` is accepted; a request over the cap is 409 and writes nothing; a bearer of another audience, the shared `AUTH_BEARER_TOKEN`, and a bearer in the body are 401; `platform_user_id` or `portal` in the body are ignored and the documents land under the assertion's researcher; a `report_server_assertion` for another `uid` or `iss` is 400 and writes nothing.

---

### function: ensure one VM, relay the mint on launch, write the launch documents

**Summary**: Fills the VM step: read `vms/{uid}`, ask `GetMicrovm`, and launch, resume or leave it, under a transaction that stops two requests launching two VMs. On launch only, exchange the relayed assertion at report-server and build `runHookPayload`. Covers R16 to R20.

**Files affected**:
- `functions/package.json`, `package-lock.json` — `@aws-sdk/client-lambda-microvms`
- `functions/src/researcher-dashboard/microvm.ts` — new: `MicrovmApi` with `get`, `run`, `resume`, `currentImageVersion`; no auth-token method
- `functions/src/researcher-dashboard/ensure-vm.ts` — new
- `functions/src/researcher-dashboard/ensure-vm.test.ts` — new
- `functions/src/researcher-dashboard/run-package.ts` — calls `ensureVm` after the queue write

**Estimated diff size**: ~420 lines

```ts
const LAUNCH_STATES = [undefined, "TERMINATING", "TERMINATED"]   // undefined: none recorded or not found
const LEAVE_STATES = ["PENDING", "RUNNING"]
// A claim on vms/{uid} that stops a second request launching while the first is. Longer
// than RunMicrovm plus the mint round trip, short enough that a crashed launcher does not
// block the researcher for long.
const LAUNCH_CLAIM_SECONDS = 60

export async function ensureVm(deps, who, body): Promise<"launched" | "resumed" | "running" | "resume-pending"> {
  const vmRef = deps.db.doc(`${root(who.portal)}/vms/${who.platformUserId}`)
  // The MicroVM API is asked outside any transaction: a transaction can retry, and must
  // not span a network call.
  const seen = (await vmRef.get()).data() as VmDoc | undefined
  const state = seen?.microvm_id ? (await deps.microvms.get(seen.microvm_id))?.state : undefined

  if (state === "SUSPENDED") return resume(deps, seen!.microvm_id)
  if (state === "SUSPENDING") return "resume-pending"          // REPORT-143's watchdog resumes it (R16)
  if (!LAUNCH_STATES.includes(state)) return "running"            // PENDING, RUNNING

  // Claim the launch. The transaction re-reads the document and only claims if nobody
  // launched or claimed since it was read above, so two requests launch at most once.
  const claimed = await deps.db.runTransaction(async tx => {
    const vm = (await tx.get(vmRef)).data() as VmDoc | undefined
    if (vm?.launching_until && vm.launching_until.toMillis() > deps.now()) return false
    if ((vm?.microvm_id ?? null) !== (seen?.microvm_id ?? null)) return false
    tx.set(vmRef, { launching_until: admin.firestore.Timestamp.fromMillis(deps.now() + LAUNCH_CLAIM_SECONDS * 1000) }, { merge: true })
    return true
  })
  return claimed ? launch(deps, who, body) : "running"
}
```

`launch`: `currentImageVersion`, then `mintReportServerToken(deps, body.report_server_assertion)` (the spike's POST to `${reportServerUrl}/api/v1/dashboard-tokens`, answering `{token}`), then `RunMicrovm` with `imageIdentifier`, the pinned `imageVersion`, `executionRoleArn`, `maximumDurationInSeconds: 8 * 60 * 60`, `egressNetworkConnectors: ["INTERNET_EGRESS"]`, no `idlePolicy`, no `ingressNetworkConnectors`, and `runHookPayload` exactly:

```ts
JSON.stringify({
  session_token: body.session_token,
  platform_user_id: who.platformUserId,
  platform_id: who.platformId,
  portal: who.portal,
  firebase_project: body.firebase_project,
  bucket: deps.config.bucket,
  report_server_token: minted,
  report_server_url: deps.config.reportServerUrl,
  function_url: deps.config.functionUrl,   // RD_FUNCTION_URL, or the derived first-gen URL
})
```

then one batch: `vms/{uid}` `{microvm_id, image_version, launching_until: delete}`, and `runners/{uid}` merged with `{state: "starting", microvm_id, platform_id, started_at, updated_at}` (the queue is already there from the previous step). A failure before `RunMicrovm`, or a definite 4xx from it, clears `launching_until` so the next request can try again. A failure after a VM may have been created (`RunMicrovm` timing out or failing without a 4xx, or the launch not being recorded) leaves the claim to lapse after 60 seconds, so the next request cannot launch a second VM. The payload is checked against the platform's 16,384-byte cap before `RunMicrovm`, failing with a reason rather than a service error.

`resume`: `ResumeMicrovm`, no mint (R17). `running`: nothing. `resume-pending`: nothing either, answered as `vm: "suspending"` so the 202 says what happened; REPORT-143's watchdog resumes the VM once it is `SUSPENDED` with work outstanding (R16).

Any upstream failure (report-server's mint answering non-2xx, the MicroVM API throwing) becomes a 502 whose message carries the upstream status and reason, and is logged with the researcher and portal; the queue write has already happened, so the work is kept for the next request or the VM that takes it.

**Tests** (fakes for `microvms`, `fetchImpl`, `db`): no VM recorded launches, mints once, and the payload has exactly the nine fields with the assertion's researcher and no `secret_name`, no `idlePolicy`, no auth token requested; `TERMINATED` and a not-found VM launch; `SUSPENDED` resumes and does not mint; `RUNNING` and `PENDING` do nothing and do not mint; two concurrent calls (the fake transaction serializes) launch once; a live `launching_until` claim does nothing; report-server's refusal is a 502 naming it and clears the claim; an oversized payload is refused before `RunMicrovm`; `RunMicrovm` failing with a timeout or a 5xx, and a launch that cannot be recorded, keep the claim; nothing in the module imports `CreateMicrovmAuthToken`.

---

### function and report-server: configuration and deploy order

**Summary**: Fills both `.env.report-service-*` files with the values for the params declared in the dashboard-function step, documents `PORTAL_PUBLIC_KEYS` for report-server, and states the deploy order. Covers R21.

**Files affected**:
- `functions/.env.report-service-dev`, `functions/.env.report-service-pro` — the values (none secret); `PORTAL_PUBLIC_KEYS` single-quoted
- `functions/README.md` or the repo `README.md` — a "Researcher Dashboard function" section
- `server/README.md` — `PORTAL_PUBLIC_KEYS` in the environment list

**Estimated diff size**: ~120 lines

The README sections state: the keys come from rigse's `rake portal_signing_key:public` per portal, with that portal's site URL as `iss`; one report-server lists every portal it serves; the two launcher secrets are set with `firebase functions:secrets:set` in each project **before** the first deploy of `researcherDashboard`, since a deploy of a function declaring an unset secret fails; `function_url` is the deployed URL of `researcherDashboard` itself (the runner's `/work`, `/idle` and `/storage-credentials` live there, REPORT-143); it defaults to the first-generation URL `https://us-central1-${GCLOUD_PROJECT}.cloudfunctions.net/researcherDashboard`, built at runtime from the project, and `RD_FUNCTION_URL` overrides it only if the function ever moves region or behind a custom domain; and report-server deploys before the function, since the function's launch path calls its mint endpoint.

## Open Questions

<!-- Implementation-focused questions only. Requirements questions go in requirements.md. -->

### RESOLVED: How does work queued against a `SUSPENDING` VM get the VM resumed?
**Context**: R16 requires that it does, and `ResumeMicrovm` cannot be issued until the VM reaches `SUSPENDED`, which can take up to the `/suspend` hook's 60-second flush. The function must not wait (R20).
**Options considered**:
- A) The function enqueues a Cloud Task, delayed ~30 seconds, to a follow-up route on `researcherDashboard` that re-runs the ensure step; the repo already uses `@google-cloud/tasks` (`tasks/submit-task.ts`). Needs an authenticated route for Cloud Tasks (an OIDC token from the function's service account) and the queue created per project.
- B) REPORT-143's per-minute watchdog, which already reads sessions and holds the MicroVM API, resumes any `SUSPENDED` VM whose `work/` document has packages outstanding. No new route or queue; up to a minute of latency in a rare race; moves the guarantee into REPORT-143.
- C) Do nothing here; the researcher's next request resumes it.

**Decision**: B (Doug, 2026-09-23). The function does nothing more on `SUSPENDING` than on `RUNNING`; REPORT-143's watchdog gains a clause resuming any `SUSPENDED` VM whose `work/` document has packages outstanding. Recorded in R16.

### RESOLVED: Judgment call: `jsonwebtoken` rather than hand-rolled `crypto.verify`
**Options considered**:
- A) `jsonwebtoken` 9, which loads under the repo's Jest 24 and whose refusals are in the Verification table.
- B) Verify RS256 directly with Node's `crypto.verify`, no dependency.

**Decision**: A. The library's alg handling was checked (it refuses the confusion token even with HS256 allowed), and the two gaps it has, `exp` and `aud` arrays, are covered by explicit checks. Hand-rolling base64url parsing and signature checks is where a verifier's subtle bugs live.

### RESOLVED: Judgment call: a launch claim on `vms/{uid}`, not a lock on `work/`
**Options considered**:
- A) The ensure step's own transaction on `vms/{uid}`, setting a short `launching_until` before calling `RunMicrovm`.
- B) Hold the queue transaction open across the launch.

**Decision**: A. A Firestore transaction must not span a network call as slow as `RunMicrovm` and the mint round trip (transactions retry and hold contention), and the queue write is already committed before the VM step, which is what lets a failed launch keep the work for next time.

## Self-Review

Roles: whoever reviews the commits, whoever runs the tests, Security Engineer, Senior Engineer, the operator deploying it. The riskiest pieces were built as throwaway code and run before and during this review: report-server's `PortalKeys` and `PortalToken` compiled with `--warnings-as-errors` and passed the verification matrix in the real test environment; the function's `portal-token.ts` compiled under the repo's TypeScript 4.9 and passed eight Jest cases on Node 22, the `.env` round trip included. Dropped after checking: `mint_dashboard_token`'s `with` inside `Repo.transaction` (the three-tuple from `create_api_token` and the controller's `{:ok, {user, raw, token}}` match line up); consuming the `jti` before the mint can fail (rigse signs a fresh assertion per call, so a consumed one is never needed twice); and step sizes, all under 500 lines.

### Reviewer of the commits

#### RESOLVED: The dashboard-function step referenced secrets declared only in the last step
`researcherDashboard` is declared with `runWith({ secrets: [rdAwsKey, rdAwsSecretKey] })` in the queueing step, but `config.ts`, which defines them, was in the configuration step at the end, so that commit would not compile. Fixed: `config.ts` moves into the queueing step, and the last step only fills values and documentation.

### Engineer running the tests

#### RESOLVED: `firebase-admin/firestore` cannot be imported under the repo's Jest
Checked with a scratch test: `import { FieldValue, Timestamp } from "firebase-admin/firestore"` fails with `Cannot find module` under Jest 24, which predates package subpath exports; `import * as admin from "firebase-admin"` with `admin.firestore.FieldValue` and `admin.firestore.Timestamp` passes, and is what `src/chat/drain.test.ts` already does. Fixed throughout the plan.

### Operator

#### RESOLVED: `function_url` could not be known before the first deploy
The plan had the operator deploy, read the function's URL, set `RD_FUNCTION_URL` and redeploy. A first-generation HTTPS function's URL is fixed by region, project and name, and `GCLOUD_PROJECT` is set at runtime, so it defaults to the derived URL, with the param kept as an override. Fixed in the queueing and configuration steps.

### Senior Engineer

#### RESOLVED: One scope per researcher's queue runs a second class's packages against the first class's scope
`final-design.md` gives `work/{platform_user_id}` one scope block ("also holds the scope block rigse sent"), de-duplicates appended packages by package key, and mirrors a flat list of package keys onto `runners/{platform_user_id}`'s `queue`; this plan followed it. A researcher who runs packages from two class dashboards before their VM takes the work overwrites the first class's scope and class tokens with the second's, so the first class's queued packages run over the second class's data. A package already queued for class A and then requested for class B is skipped as a duplicate, and `queue` cannot say which class an entry is for. Checked against the design's text and the plan's transaction. The fix is to key queue entries by class and package (for example `scopes: {class_hash: {scope, class_tokens}}` beside `packages: [{class_hash, identity, ...}]`, and `queue` entries naming the class), which changes the `/work` response REPORT-143 returns, what RD-4's runner reads, and the `queue` field RD-3's page renders. Left open because it changes a contract three other stories consume.

**Decision**: key by class (Doug, 2026-09-23). Applied to R15 and the queueing step: entries carry `class_hash`, scope and class tokens live under `scopes.{class_hash}`, de-duplication is by class and package, and `queue` holds `{class_hash, package_key}` pairs. REPORT-143, RD-4 and RD-3 read these shapes.

### Reviewer of the commits (found while speccing REPORT-142)

#### RESOLVED: `export const researcherDashboard` would never be deployed
`functions/src/index.ts` ends by assigning `module.exports = { api: wrappedApi, ... }`, which replaces the whole exports object, so an `export const` anywhere in the file is dropped from the compiled module. A throwaway `tsc` build of that shape (`export const researcherDashboard = 1` followed by `module.exports = { api }`) exported only `api`, so Firebase would never have seen the function. Fixed: `researcherDashboard` is added as a key of that object (Doug, 2026-09-24).

## As built (2026-09-24)

The seven steps landed as planned, one commit each (`50c303a` to `ee6a7a4`), each reviewed until a pass found nothing to act on. Every requirement R1 to R21 has code and tests behind it. These are the departures from the text above, most from the per-step review:

**report-server**
- The test keys are installed from `test/test_helper.exs` (`PortalTokenFixture.install!/0`), not `config/test.exs`: `runtime.exs` runs after `test.exs` and would overwrite it, and `test/support` is not compiled when `test.exs` is evaluated.
- `PortalKeys` logs and ignores an entry it cannot trust: a missing field, an unreadable PEM, or a `kid` listed twice, where it trusts neither entry because which issuer the `kid` is bound to would be a guess. Unset or malformed, it trusts no key and every assertion is refused.
- The live-token predicate is `live_api_tokens/0`, a base query, rather than `live/1`. `revoke_dashboard_tokens/1` uses it too, so an already-expired dashboard token is left unrevoked, which is harmless.
- The mint endpoint stores a role flag as true only when its claim is literally `true` (not `!!`). It requires `login`, `first_name`, `last_name` and `email` as non-empty strings and `portal_user_id` as a positive integer, answering 400 naming the claim, because `create_user` would store a missing field as NULL and `update_user`'s changeset would fail on it. A `jti` over 255 characters is refused as not authenticated, and `used_portal_assertions` also has an index on `expires_at` for the prune.

**The function**
- `parsePortalKeys` throws on a malformed `PORTAL_PUBLIC_KEYS` (including an empty field or a repeated `kid`), which the auth middleware answers as 500 naming the setting. It is the only configuration of a function whose every route needs it, so failing loudly is right there, where report-server has other routes that must keep working. `verifyPortalToken` re-checks `iss` itself, since jsonwebtoken skips its issuer check for a falsy issuer.
- `/run-package` validates more than the plan listed: `scope.collection` must be `"classes"`, `scope.id` must be the class's `class_hash`, `class_hash` must be 48 lowercase hex (rigse's `SecureRandom.hex(24)`, and what REPORT-142's `/derive-profile` validates), every class token must be a non-empty string, and a package named twice in one batch is a 400.
- The work document is written with `mergeFields` rather than `{merge: true}`, so a later request for a class replaces that class's `scopes.{class_hash}` whole and a stale class token cannot survive, while other classes' entries are kept.
- The 202 body is `{success: true, queue, appended, vm}`, with `queue` as the `{class_hash, package_key}` pairs R15 puts on the runner document, and `vm` one of `launched`, `launching` (another request holds the launch claim, where the plan said `running`), `resumed`, `running` or `suspending`.
- `launching_until` is epoch milliseconds, cleared with `null`, and the launch records are written in a transaction rather than a batch, since the `Db` slice the module uses has no batch. The claim is cleared only when no VM can exist: a failure before `RunMicrovm`, a definite 4xx from it, or the oversized payload. A timeout or 5xx from `RunMicrovm`, or a failure to record a launched VM, leaves it to lapse.
- Each upstream call is made once with a 10-second timeout (the mint including its body, and the SDK client with `maxAttempts: 1` and `throwOnRequestTimeout`), so the four calls a launch makes fit inside the function's 60 seconds. A throttled call is answered 502 with the work kept rather than retried. The mint's timeout stops waiting but does not abort the socket: `ensure-vm.test.ts` runs in Jest 24's jsdom environment, whose `AbortSignal` has no `timeout()`, and the node environment has no `AbortSignal` at all.
- The payload-size check runs after the mint, since the minted token is part of the payload. On the launch branch no live VM holds the revoked token, and rigse signs a fresh assertion per call.
- A Firestore failure inside the VM step (reading `vms/` or the claim) is a generic 500. Two concurrent requests against a `SUSPENDED` VM both call `ResumeMicrovm`, and the loser's error is answered 502 with its work already queued.
- Every dashboard string param defaults to `""` (`RD_QUEUE_CAP` defaults to 20), and `/run-package` answers 503 naming the unset launch settings (image, role, bucket, report-server URL) before writing anything. Both `.env` files list every param, empty where it has no value yet, because firebase-tools prompts for (or, non-interactively, fails on) a declared param a file leaves out, whatever its default.
- `microvm.test.ts` replaces the SDK module with `jest.mock`, because Jest 24 cannot resolve the SDK's `node:` builtins. The Firestore fake is shared at `functions/src/test/researcher-dashboard-fake-db.ts`. It runs transactions one at a time, models `merge` and `mergeFields`, and copies only maps and arrays, so a `Timestamp` written through it reads back as a `Timestamp`. `package-lock.json` was regenerated with Node 22's npm 10, the package's engine.

**Not configured yet, so not deployable end to end**
- No rigse signing key exists for either portal, so `PORTAL_PUBLIC_KEYS` is `'[]'` in both functions `.env` files and every assertion is refused until entries from `rake portal_signing_key:public` are added.
- report-server reads `PORTAL_PUBLIC_KEYS` from its task environment, which comes from cloud-formation's `fargate/report-server.yml` in another repository. The variable has to be added to that stack.
- There is no production runner stack yet, so production's image, role and bucket are empty and `/run-package` answers 503 there. `RD_AWS_KEY` and `RD_AWS_SECRET_KEY` must still be set in both projects before the first deploy, as the functions README says.

Checks on the head commit: report-server 1062 tests pass (7 skipped) and compiles with `--warnings-as-errors`; the functions' 609 tests pass (31 suites, 8 emulator tests skipped), with `tsc` and `tslint` clean.
