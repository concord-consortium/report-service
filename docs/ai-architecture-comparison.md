# AI Integration Architectures at Concord — Inventory and Comparison

**Status:** review draft for the CTO and the developer picking up the follow-on spike.
**Written:** 2026-08-10. **Basis:** direct reading of the code in `davai-plugin` (all three backends,
including the three stacked open AgentCore PRs), `collaborative-learning`, `report-service`, and
`activity-player`, plus a scan of every other `concord-consortium` repo for LLM SDK usage.

---

## 1. What this is

We have grown six distinct architectures for connecting our SPAs to LLMs. They were each built for a
real reason, they each work, and no two of them share a line of infrastructure code. This document says
what each one actually is, where they genuinely differ, where they are accidentally different, and what
a consolidation would have to preserve.

It ends with a point of view — AgentCore looks like the best of the designs — and with the specific
question that point of view does not yet answer: whether it can serve the CLUE features, whose data
lives in Google Cloud.

---

## 2. Executive summary

**Six live architectures, three substrates, three places conversation state lives.**

| # | System | Substrate | Transport to client | Conversation state | Agentic? |
|---|---|---|---|---|---|
| A | DAVAI — SAM/Lambda (production) | AWS Lambda + SQS + RDS Postgres | HTTP polling | Postgres (LangGraph `PostgresSaver`) | **Yes — client-side tools** |
| B | DAVAI — AgentCore (3 open PRs) | AWS Bedrock AgentCore microVM | WebSocket | In-VM, re-seeded from client transcript | **Yes — client-side tools** |
| C | DAVAI — in-browser (shipping) | The student's GPU (WebLLM/WASM) | none — same process | In-page | No |
| D | CLUE — document analysis + AI comments | Firebase Functions (gen 2) | Firestore docs (comments) | Stateless, one-shot + vector RAG | No |
| E | CLUE — class summary + AI tile | Firebase Functions (gen 2, scheduled + callable) | Firestore docs / callable return | Stateless, cached | No |
| F | CLUE + Activity Player — chat tutor | Firebase Functions (gen 1) | Firestore docs | **On OpenAI's servers** (Conversations API) | No |

**The five findings that matter most:**

1. **F is two copies of the same code in two repos, already diverging.** `report-service/functions/src/chat/`
   and `collaborative-learning/functions-v2/src/chat/` share file names, structure, and even comment
   text. The drain engine, the lock protocol, and the OpenAI wrapper are near-identical; only the
   context-assembly layer genuinely differs. This is the cheapest, highest-certainty consolidation
   available and it does not require agreeing on anything architectural.

2. **The newest code has the sharpest vendor lock-in.** The chat tutors (F) are built on OpenAI's
   *proprietary* Conversations + Responses API surface — conversation objects, persistent
   developer-role conversation items, `text.format: json_schema`. Anthropic and Google have no
   equivalent primitive. Swapping providers there is a rewrite of the state model, not a config
   change. Meanwhile DAVAI (A/B), the oldest system, is the only one that is genuinely
   multi-provider (OpenAI / Anthropic / Google, selected per request by the user).

3. **We have re-invented "durable job queue" four times, in four different ways.** SQS + a Postgres
   `jobs` table (A); Firestore collections as a pipeline with `pending`→`imaged`→`done`/`failed*`
   (D); a Firestore-doc mutex with 1-second polling (E); a per-conversation compare-and-set lock
   plus a persisted drain cursor (F, twice). The F drain engine in particular is ~390 lines of
   genuinely subtle concurrency code — window saturation, atomic idle commit, poison-pill skip,
   stale-lock reclaim. It is well-commented and emulator-tested, and it exists twice.

4. **Only DAVAI is agentic, and its tools run on the *client*.** The server declares
   `create_request` and `sonify_graph`, but they do not execute server-side — they echo the model's
   arguments, the browser executes them against the CODAP document via `codapInterface.sendRequest`,
   and the result is fed back as a `ToolMessage`. Any unified architecture must keep this. It is
   the hardest capability in the estate and the one most likely to be quietly dropped by a design
   that optimizes for the Firebase-side workloads.

5. **Nothing server-side deploys from CI.** DAVAI's `sam-server` is hand-deployed to three
   CloudFormation stacks; CLUE's `functions-v2` and report-service's `functions` are hand-deployed
   with `firebase deploy`. CI lints, builds, and tests all three — and then stops. Our SPAs have far
   better release hygiene than the services holding the API keys.

**Nothing else in the org.** A dependency scan of every locally checked-out repo, plus a name and
description scan of all 400+ repos in the organization, found no other LLM integration. Two adjacent
things exist and are scoped out: `cc-data-cli` and `google-docs-mcp` implement the *inverse* pattern —
exposing our data and tools to an external agent over a CLI and MCP, rather than embedding a model in
an SPA. `davai-openai-proxy` (2024) is the superseded original DAVAI architecture: browser → thin
bearer-token proxy → OpenAI Assistants API.

---

## 3. The systems in detail

### A. DAVAI — SAM / Lambda / SQS / Postgres (production today)

`davai-plugin/sam-server/`

A CODAP plugin for blind and low-vision users. The client never talks to a provider; it posts to an
API Gateway and polls.

- **Request lifecycle.** `POST /message` → authorize, `nanoid()` → `messageId`, `INSERT` a `jobs` row
  (`status='queued'`, `input` JSONB), enqueue `{messageId}` to SQS, return **202**. SQS triggers
  `JobProcessorFunction` (BatchSize 1, 300 s timeout), which compiles the LangGraph app and streams.
  Partial tokens are written back into the *same* `jobs` row (`status='streaming'`). The client polls
  `GET /status?messageId=…` at **1 s** idle / **0.5 s** while streaming, with a 60 s no-progress budget.
- **Agent.** LangChain JS + LangGraph `StateGraph`, single node `START→model→END`. History trimmed at
  100k tokens. System prompt = instructions + CODAP API documentation + live `dataContexts`/`graphs`.
- **Multi-provider.** `createModelInstance()` switches on the per-request `llmId` — a JSON string like
  `{"id":"gpt-5.5","provider":"OpenAI"}` — to build `ChatOpenAI` / `ChatAnthropic` /
  `ChatGoogleGenerativeAI`. Provider quirks are handled explicitly (OpenAI Responses reasoning effort;
  Anthropic no-sampling models omit temperature). The user picks the model in the UI; the list lives in
  `src/app-config.json` and covers OpenAI, Google, Anthropic, `Local`, and `Mock`.
- **Tools are client-executed.** `create_request` and `sonify_graph` are declared with LangChain's
  `tool()` but do not execute — they normalize and echo the model's arguments. The job returns
  `{status:"requires_action", request, tool_call_id}`; the client runs it against CODAP and `POST`s the
  result to `/tool`, creating a **second** queued job that feeds it back as a `ToolMessage`. There is
  substantial tool-repair logic (`buildToolRepairMessages`) that synthesizes error results for orphaned
  `tool_use` blocks so Anthropic threads don't break.
- **Cancellation** uses a Postgres trigger (`notify_job_cancelled`) + `LISTEN` to abort an in-flight run.
- **Auth.** A single shared static bearer secret, baked into the client bundle at build time. **No user
  identity of any kind.** `/status` is unauthenticated.
- **Infrastructure.** 6 Lambdas, API Gateway, SQS (no DLQ), RDS Postgres `db.t3.micro` in a VPC with NAT,
  Secrets Manager. Three independent stacks (prod, staging-a, staging-b), each with its own database.
- **Deployment.** Manual `sam deploy` from a developer machine. CI deploys only the client, to S3, with
  the server URL chosen by git ref (tags → prod, everything else including `main` → staging-a).

**Cost shape:** an always-on RDS instance and a NAT gateway are the floor — you pay whether or not anyone
uses DAVAI. Lambda and SQS are negligible. LLM tokens dominate the variable cost.

### B. DAVAI — AWS Bedrock AgentCore (three stacked open PRs)

`davai-plugin` PRs **#116** (backend container, parity harness, docs) → **#117** (CloudFormation staging
stack + Cognito public access) → **#115** (direct browser WebSocket transport, Cognito + SigV4). Also
published as `concord-consortium/davai-agentcore`. Design write-ups in `docs/agentcore/`.

The same LangGraph agent, ported verbatim, in a bring-your-own container on AgentCore. **The only change
to the agent itself was `PostgresSaver` → in-VM `MemorySaver`.**

- **Deleted:** SQS, the RDS Postgres instance, the `jobs` table, the `/status` endpoint, and the entire
  poll loop.
- **Runtime contract.** ARM64 container (325 MB) serving `POST /invocations` + `GET /ping` on port 8080,
  plus a `/ws` WebSocket. AgentCore routes a `runtimeSessionId` to the same microVM for the session's
  life, so conversation state simply lives in that VM.
- **Transport.** One WebSocket per conversation. Tokens stream as `{type:"token"}` frames. **A tool call
  is answered over the same open socket** — no second job, no second poll cycle.
- **Durability is the client's job.** On microVM idle-out the client replays its `ChatTranscriptModel`
  history via a `seed` frame, which injects messages into the checkpointer with `updateState` (no model
  call). Zero server-side persistence.
- **LLM calls stay direct-to-provider,** not through Bedrock — so the execution role deliberately does
  *not* have `bedrock:InvokeModel`.
- **Infrastructure is now a single CloudFormation template** (`infra/cloudformation.yml`), one stack per
  environment, parameterized for staging (QA account) and production. It creates the execution role, the
  AgentCore runtime pointing at an ECR image, and the Cognito Identity Pool. Deploy is
  `./infra/deploy-staging.sh [image-uri]`; teardown is a single `delete-stack`. The earlier hand-rolled
  resources were deleted and replaced by the stack on 2026-08-07.
- **Anonymous browser access is built and verified live.** Anonymous client → Cognito `GetId` +
  `GetOpenIdToken` → `sts:AssumeRoleWithWebIdentity` (**classic flow** — the enhanced flow's service
  allowlist excludes `bedrock-agentcore`) → SigV4 pre-signed `wss://` URL → runtime `/ws` → streaming
  token frames. The unauth role may *only* invoke this one runtime. No proxy, no Lambda shim. A smoke
  script (`scripts/agentcore-cognito-smoke.mjs`) is both the repro and the client transport's reference
  implementation.
- **Measured results.** 40/40 Playwright parity against the real client in real CODAP. Latency vs the
  live deployed staging stack, same model, N=20: describe **−57%**, single-tool modify **−39%**, overall
  **−43%**. Pure transport overhead (LLM removed): **−96%** — ~490 ms/turn, ~970 ms per tool round-trip.
  Multi-tool interactions show a *lower* percentage (−24%) because each tool call is a full extra LLM
  call, so total time grows faster than the transport saving. **Tool turns are LLM-bound, not
  transport-bound** — a useful, generalisable finding.
- **Deliberately deferred to the production-stack work:** per-identity throttling or quotas (WAF or
  Cognito-keyed) on top of the anonymous access model; moving provider keys from stack parameters to
  Secrets Manager ARNs (the backend already resolves ARNs); turning the release-build staging fallback
  into a build failure once the production stack exists.
- **The structural gap.** AgentCore has no per-caller throttle — every quota is per-agent-per-account.
  Per-session budgets live inside one microVM, so **they cannot stop one client opening 500 sessions.**
  Cross-session rate limiting needs shared state, which is exactly what this design deletes. Worth
  keeping in proportion: the legacy SAM stack has the same exposure class, since its `AUTH_TOKEN` also
  ships in the public bundle.

**Cost shape:** idle-billed at roughly cents; no always-on database or NAT. Strictly cheaper at low
utilization than A.

### C. DAVAI — in-browser inference (shipping in `main`)

`davai-plugin/src/utils/local-llm/`

`@mlc-ai/web-llm` 0.2.84 loading Qwen3-1.7B or Qwen3-4B (q4f16 MLC builds) into a Web Worker, exposed as
a `Local` provider alongside the hosted ones. Careful engineering around load generations, worker
supersession, and a 300 s generate watchdog, plus a dedicated eval runner under `local-llm/eval/`.

No server, no API key, no per-token cost, and **no student data leaves the browser**. The obvious
constraints are model capability (particularly for tool calling), a multi-gigabyte first-load, and a hard
dependency on the student's hardware. Worth keeping visible in any architecture conversation: it is the
only option that makes the data-residency question disappear entirely.

### D. CLUE — document analysis and AI comments

`collaborative-learning/functions-v2/`, `shared/ai-summarizer/`, `functions-v2/lib/src/ai-categorize-document.ts`

A three-stage pipeline using **Firestore collections as the queue**:

1. `onAnalyzableTestDocWritten` / `onAnalyzableProdDocWritten` — RTDB `onValueWritten` on
   `…/documentMetadata/{docId}/evaluation/{evaluator}` → writes a doc into the `pending` queue.
2. `onAnalysisDocumentPending` — reads the document content from RTDB, then **either** runs the shared
   markdown summarizer (`documentSummarizer`, tile-by-tile handlers for table/graph/drawing/dataflow/
   simulator/text/image) **or** renders a screenshot via Shutterbug → writes into the `imaged` queue,
   deletes from `pending`.
3. `onAnalysisDocumentImaged` — calls OpenAI, writes a comment document into the document's `comments`
   collection under a synthetic analyzer user, then writes into the `done` queue. Failures go to
   `failedImaging` / `failedAnalyzing`.

No LangChain. Raw `openai` SDK, `chat.completions.parse` with a **zod** structured-output schema built
dynamically from the unit's authored `aiPrompt` (`systemPrompt`, `mainPrompt`, `categories`,
`keyIndicatorsPrompt`, `discussionPrompt`). Model **hardcoded to `gpt-4o-mini`**.

Notably, the prompt is *data*: authored per unit, carried through the queue, and used to build both the
messages and the response schema. That is a real capability the chat tutors only partially have.

**The feedback / RAG loop.** When a user sets `agreeWithAi` on a comment, `onDocumentSummarized`
regenerates the document's markdown summary, embeds it (`text-embedding-3-small`), and stores it as a
Firestore vector field on `/summaries/{root}-{space}-{docId}` alongside a map of agreements. The next
text-summarizer categorization runs `findNearest` (EUCLIDEAN, limit 5) over same-class/unit/problem/
investigation summaries that have agreements, and injects those summaries plus agreement counts into the
prompt. In-context RAG over human agreement signal — no fine-tuning. Currently gated to the `cas` unit.

### E. CLUE — class-wide summary and the AI tile

Two related paths sharing one Firestore document.

- **Summarization.** `atMidnight` (scheduled, 07:00 UTC) → `updateClassDataDocs` collects student and
  teacher work per class/unit into `/{realm}/{realmId}/aicontent/{unit}/classes/{classId}`. Writing that
  doc triggers `onClassDataDocWritten`, which uses **LangChain** `ChatOpenAI` + `MarkdownTextSplitter`
  (64k-char chunks) to map/reduce the content into `studentSummary` and `teacherSummary`. Currently
  scoped to `learn.concord.org`, the `AITEST` demo, and two units.
- **Teacher view.** `src/components/navigation/ai-summary.tsx`, with a `generateClassData_v2` callable to
  regenerate on demand.
- **AI tile.** `getAiContent_v2` — a callable that takes an authored `dynamicContentPrompt` +
  `systemPrompt`, prepends the class student/teacher summaries, calls `gpt-4o-mini`, and caches the
  result per (class, document, tile). Concurrency is handled by a **Firestore document used as a mutex**
  with an `expiresAt` field, stale-lock stealing, and **1-second recursive polling** while waiting. This
  is the third distinct locking scheme in the estate.

Note that the class summary feeds the AI tile and the teacher view. It does **not** feed the AI comments —
those get their cross-document context from the vector/agreement loop in D.

### F. CLUE and Activity Player — the chat tutor (two copies)

`report-service/functions/src/chat/` + `activity-player/src/components/chat/`
`collaborative-learning/functions-v2/src/chat/` + `collaborative-learning/src/components/chat-tutor/`

AP is the origin; CLUE is a port. Shared design:

- **Firestore documents are the wire protocol.** The client `add()`s a `kind:"user"` message doc; a gen-1
  `onWrite` trigger fires; the function writes a `kind:"assistant"` doc; the client's `onSnapshot`
  renders it. The parent conversation doc carries a function-owned `status` field
  (`idle`/`generating`/`error`) that drives the typing indicator.
- **Gen 1 on purpose.** Gen-2 Eventarc at-least-once semantics would reintroduce the infinite re-drain
  that the default no-retry policy prevents. Both files carry an explicit "do not enable retries" warning.
- **Concurrency.** A per-conversation lock (compare-and-set `idle`→`generating` in a transaction, 5-minute
  stale reclaim) plus a drain loop with a persisted cursor. The drain handles window saturation from
  accumulated assistant docs, commits idle atomically inside a transaction so a message arriving during
  the check is never orphaned, batches the assistant doc + parent state + cursor advance so a crash can't
  duplicate a reply, and steps over permanently-failing units so one poison pill can't wedge a
  conversation. ~390 lines in AP, ~230 in CLUE, near-identical in intent.
- **State lives on OpenAI.** `openai.conversations.create()` returns a `conv_…` id stored on the parent
  doc. The system prompt is installed **once** as a persistent developer-role conversation *item* (not
  `instructions`, which is per-request). Each turn sends only the new message with `store: true`.
- **Structured output.** Strict `json_schema` with a nullable `userText`, so the model can decline to
  say anything.
- **The model** comes from an `OPENAI_MODEL` `defineString` param; the key is a `defineSecret`.

**Where they diverge — and it is only here:**

| | Activity Player (report-service) | CLUE |
|---|---|---|
| Path | `sources/{source}/chats/{key}/activities/{a}/pages/{p}/messages/{m}` | `{root}/{rootId}/chatTutor/{conversationId}/messages/{m}` |
| Context source | **Server-side**: fetches the LARA activity JSON over HTTP, converts it to page markdown (`convert.ts`, `chat-context.ts`), adds per-interactive prompt fragments (`sim-prompts.ts`) | **Client-side**: the client writes `leftContext` (problem JSON) and `rightContext` (workspace markdown) onto the message doc |
| Context refresh | Installed once per page | `rightContext` re-sent when the workspace changes, wrapped in a `seq`-stamped "supersedes earlier" envelope |
| Telemetry | Accepts `kind:"log"` docs — interactive telemetry coalesced (≤20 events, ≤20k chars) into one billed developer-role turn, with the reply suppressed | None |
| SSRF surface | Real — `resolveActivityUrl` validates the client-supplied URL against an authoring-host allowlist | None (no server-side fetch) |
| Prompt overrides | Source constant | Unit-authored `promptReplace` / `promptAppend` |
| Identity | Anonymous runs (`run_key`) or platform user | Platform user, class-hash pinned |

Everything else — the lock, the drain, the cursor, the OpenAI wrapper, the structured-output contract,
the status protocol, the transport class shape — is the same code written twice.

---

## 4. Comparison across dimensions

### Transport and latency

| | A: DAVAI SAM | B: DAVAI AgentCore | C: In-browser | D/E: CLUE analysis | F: Chat tutor |
|---|---|---|---|---|---|
| Protocol | HTTP poll (1 s / 0.5 s) | WebSocket | in-process | Firestore docs | Firestore docs |
| Token streaming to user | ❌ (internal only) | ✅ | ✅ | n/a | ❌ |
| Tool round-trip cost | 2nd queued job + 2nd poll cycle | same socket | n/a | n/a | n/a |
| Measured transport overhead | ~500 ms/turn, ~1 s/tool | ~20 ms / ~40 ms | 0 | batch, latency irrelevant | Firestore round-trip + cold start |
| Reload / multi-tab | poll resumes | client re-seeds from its transcript | n/a | n/a | full history rehydrates from Firestore |

Firestore-as-transport gets reload and multi-tab rehydration free, which is genuinely valuable for
classroom use. It costs streaming — a student waits for the entire reply with only a typing indicator.
That is the single biggest UX difference between the DAVAI line and the education-app line.

### Conversation state and vendor lock-in

| | Where history lives | Portability |
|---|---|---|
| A | Postgres, LangGraph `checkpoints` | **High** — LangChain abstracts the provider; swap models per request |
| B | The microVM, re-seeded from the client transcript | **High** — same agent code; the client is the source of truth |
| C | In the page | **High** — but capped by what runs locally |
| D/E | Nowhere (one-shot); embeddings in Firestore | Medium — OpenAI SDK + zod, but the calls are simple |
| F | **On OpenAI's servers** | **Low** — Conversations API is proprietary; there is no Anthropic or Google equivalent |

F is worth restating plainly: it is our newest, most student-facing AI feature, and it is the one we
could not move to another provider without redesigning how conversation state works. It also means
conversation content is retained by OpenAI (`store: true`), which is a policy question as much as an
architectural one and should be answered explicitly rather than inherited from a code default.

### Model and provider flexibility

| | Provider(s) | Model selection |
|---|---|---|
| A / B | OpenAI, Anthropic, Google, Local, Mock | **Per request, chosen by the user in the UI**, with per-model effort levels |
| C | Local only (Qwen3) | User-selected from the same list |
| D | OpenAI | **Hardcoded `gpt-4o-mini`** in `ai-categorize-document.ts` |
| E | OpenAI | **Hardcoded `gpt-4o-mini`** in two files |
| F | OpenAI | `OPENAI_MODEL` deploy-time param |

DAVAI's `llmId` mechanism — a `{id, provider}` pair travelling with each request, plus a per-provider
adapter and a documented effort-level model — is the best piece of prior art we have for this, and it is
the one part of the estate nothing else borrows from.

### Agency and tool use

Only A and B have it, and it is the client-side variety: the model asks, the browser acts on the CODAP
document, the result goes back into the thread. The Firebase-side systems (D, E, F) are strictly
request→response; the tutor cannot look at the student's work unless the client or the server has already
serialized it into the prompt.

That asymmetry is probably the most consequential thing in this document. If the chat tutor ever needs to
*inspect* the current workspace on demand — rather than receive a snapshot pushed with each message — it
needs the tool-calling round-trip DAVAI already has, and Firestore-doc transport makes that round-trip
expensive (two extra document writes and two trigger cold starts per tool call).

### Context assembly

Every system solved this differently, and the differences are mostly *not* accidental:

- **A/B**: CODAP API documentation + live `dataContexts`/`graphs` injected into the system prompt each turn.
- **D**: whole document → markdown (a substantial shared tile-by-tile summarizer) **or** → screenshot → vision model.
- **E**: whole class's work → chunk → map/reduce summarize → cache.
- **F/AP**: activity JSON fetched server-side → page markdown + per-interactive prompt fragments, installed once.
- **F/CLUE**: problem JSON + workspace markdown pushed by the client, with a supersession envelope.

`shared/ai-summarizer/` (CLUE) and `functions/src/chat/convert.ts` + `chat-context.ts` (report-service)
are both mature, well-tested "domain object → LLM-friendly text" layers. They are the pieces most worth
treating as reusable products in their own right, independent of any hosting decision.

### Concurrency, retries, and failure

| | Mechanism | Retry semantics |
|---|---|---|
| A | SQS (BatchSize 1, 300 s visibility, **no DLQ**) | SQS redrive; poison messages recycle |
| B | One turn per socket; concurrent turns rejected | Client retries |
| D | Firestore collections as pipeline stages; failures diverted to `failed*` collections | Gen-2 at-least-once; each stage idempotent by overwrite |
| E | Firestore doc as mutex, `expiresAt`, stale-lock stealing, 1 s polling wait | Caller waits or uses cache |
| F | CAS lock + persisted drain cursor + atomic idle commit + poison-pill skip | **Retries deliberately disabled** |

Four mechanisms, four sets of edge cases, four sets of tests. None is wrong for its context; the cost is
that the concurrency expertise doesn't transfer between them.

### Security, identity, and spend control

| | Client auth | Per-user identity | Rate limiting | Spend guard |
|---|---|---|---|---|
| A | Shared static bearer in the bundle | **None** | API Gateway defaults | Provider caps only |
| B | Cognito Identity Pool unauth → SigV4 pre-signed WSS; unauth role scoped to one runtime | **None** | **None per-caller** (deferred to production hardening) | Provider caps + per-session in-container budget |
| C | n/a | n/a | n/a | Free |
| D/E | Firebase callable + `validateUserContext` (portal claim, class hash) | ✅ Real | Firebase defaults + `maxInstances: 2` | Batch-shaped, bounded by document volume |
| F | Firestore security rules (owner field / class hash) | ✅ Real (or `run_key` for anonymous AP runs) | Per-conversation lock only | Log coalescing caps; no per-user cap |

The Firebase systems inherit real identity from the portal; DAVAI has none at all. Nothing anywhere
limits how much a single user can spend. Provider-side budget caps are the only true backstop, and the
AgentCore work is the only place in the estate that says so out loud.

### Development pipeline and testability

| | CI | Deploy | Local loop | Tests |
|---|---|---|---|---|
| A | lint/build/test `sam-server` | **manual** `sam deploy` ×3 stacks | docker-compose + ElasticMQ + local Postgres + `dev-job-poller` | Jest units; Cypress on the client |
| B | (PRs open) | one CloudFormation stack per environment; `./infra/deploy-staging.sh` | **the same container runs locally and on AgentCore** | Jest; Playwright "done-loop" driving real CODAP; latency harnesses; a live Cognito smoke script |
| C | in client CI | with the client | webpack dev server | Jest + a dedicated eval runner |
| D/E | lint/build/test with Firestore+RTDB emulators | **manual** `firebase deploy` | emulator suite | Emulator tests in CI |
| F | AP: emulator tests in CI. CLUE: same workflow | **manual** `firebase deploy` | emulator suite | Drain logic deliberately importable without `firebase-functions` so it is emulator-testable |

Two things stand out. First, B's "the same container runs locally and on AgentCore" is a materially better
development story than anything else here, and it came free with the substrate choice. Second, the F drain
engine's deliberate avoidance of `firebase-functions` imports purely so the logic can be emulator-tested is
a good pattern that deserves to survive any refactor.

### Cost shape

- **A** has a real fixed floor: RDS `db.t3.micro` + NAT gateway + VPC endpoints, always on.
- **B** is idle-billed to roughly cents.
- **C** is free at the margin.
- **D/E/F** are Firebase invocations plus Firestore reads/writes — effectively free at our scale.
- **In every case LLM tokens dominate**, and nowhere do we attribute token spend to a user, a class, or a
  feature. D records `promptTokens`/`completionTokens` into its `done` queue; nothing else tracks usage at
  all. That is a gap worth closing regardless of what architecture we land on.

---

## 5. Where consolidation is real, and where it isn't

**Genuinely duplicated — consolidate:**

1. The chat drain/lock engine and OpenAI wrapper (F ×2). Same code, two repos, already drifting.
2. Provider abstraction and model selection. DAVAI has a good one; everything else hardcodes OpenAI.
3. "Domain object → LLM text" summarizers. Two mature implementations that know nothing about each other.
4. Prompt/config authoring. CLUE's analysis path treats prompts as authored data with a derived response
   schema; the chat tutors have a weaker version; DAVAI has none.
5. Eval and regression harnesses. DAVAI's done-loop and the local-LLM eval runner are the only ones. Every
   AI feature we ship needs this and only one project has it.
6. Token accounting and spend attribution. Absent almost everywhere.

**Genuinely different — do not force together:**

1. **Interactive/agentic vs batch/analysis.** DAVAI needs sub-second transport, streaming, and tool
   round-trips. The CLUE analysis pipeline needs throughput, retries, and cheap idle. These are different
   workloads and probably want different substrates even under one architecture.
2. **Firestore-as-transport.** It buys reload, multi-tab, offline queuing, and rules-based authorization
   essentially free, and it fits how the education apps already work. It costs streaming. That trade is
   correct for the tutor and wrong for DAVAI.
3. **Where context comes from.** Server-side fetch (AP) vs client-push (CLUE) is a real design difference
   driven by where the authoritative content lives, not an accident.

---

## 6. A point of view: AgentCore looks like the best of these designs

Stated as a position to be tested, not a conclusion.

Of the six, **B is the only one that gets multi-turn conversation state without either a database or a
vendor's conversation API.** That is a genuinely unusual property and it is worth naming precisely:

- **A** needs an always-on Postgres instance to hold LangGraph checkpoints, and a queue to get work to it.
- **F** avoids the database only by handing conversation state to OpenAI — trading an operational
  dependency for a vendor dependency, on a proprietary API with no equivalent elsewhere.
- **B** keeps state in the microVM for the session's life, with the client's transcript as the durable
  record and a cheap re-seed path when a VM idles out. No database, no queue, no vendor state API, and
  the provider stays swappable because the agent is still plain LangGraph.

The rest of the argument:

- **It is agentic**, with client-executed tools already working in production-shaped code.
- **Local development is the same artefact as production.** It is fundamentally "a VM running the agent
  that the client talks to." You can run the container on your laptop, point the client at it, and get
  identical behavior. Nothing else here has that — A needs docker-compose plus ElasticMQ plus Postgres
  plus a job poller to approximate itself.
- **Simple agents stay simple.** Setting up a new agent configuration does not require standing up a
  queue, a job table, a status endpoint, and a poll loop before the first token appears. The message
  never has to be queued in an external system at all.
- **It has the best evidence behind it** of anything in the estate: 40/40 parity in the real client,
  measured latency, an honest write-up of what it could not solve, and now a CloudFormation stack with a
  live-verified anonymous browser access path.

The costs are real and should be stated alongside: it is a **second cloud** next to Firebase, it is a
**young AWS service**, and it has **no per-caller throttling** — a gap that is deferred rather than
solved, and that the shared-state-free design cannot close on its own.

---

## 7. The open question: would AgentCore serve the CLUE features?

This is the part the DAVAI work does not answer, and it is the main reason to run a spike rather than
just adopt B.

**The concern.** CLUE's data lives in Google Cloud — Firebase RTDB for document content, Firestore for
metadata, comments, queues, and the summary vector store. An agent running in an AWS microVM in
`us-east-1` reaching a Firebase project whose functions run in `us-central1` is a cross-cloud,
cross-region hop on every read and write, over the public internet, using a service-account credential
that would have to live in AWS. Today those reads are in-region calls with ambient credentials.

**A hypothesis worth testing, because it changes the answer a lot.** The concern may apply mostly to the
features you would *not* move, and barely at all to the ones you would:

| Feature | Google-cloud data the *server* needs | Fit for AgentCore |
|---|---|---|
| **F — CLUE chat tutor** | **None.** Context already comes from the client (`leftContext` / `rightContext` pushed on the message doc). | Good — the client could send the same context over a socket |
| **F — AP chat tutor** | **None.** Context is fetched from the authoring host over plain HTTP, which is cloud-neutral. | Good |
| **D — document analysis** | Heavy: RTDB document content, Firestore queue docs, comments, vector search | Poor — and it is batch work, the worst fit for a per-session microVM anyway |
| **E — class summary / AI tile** | Heavy: RTDB + Firestore across a whole class | Poor — scheduled batch, same reasoning |

If that holds, the split is clean: **the interactive, agentic, latency-sensitive features have almost no
Google-cloud data dependency and could move; the batch analysis features have a heavy one and should
stay where the data is.** Which is the same line as the "split by workload class" direction below,
arrived at from a different direction.

**What would still need solving even for the chat tutors:**

1. **Triggers.** Firestore `onWrite`, RTDB `onValueWritten`, and the scheduler have no AgentCore
   equivalent. Moving to a socket removes the need for a trigger in the chat case — but anything that
   must react to a data change in Google Cloud needs either a thin Firebase function that forwards the
   event, or Eventarc → Pub/Sub → an AWS endpoint. Either way it is an extra hop and a new failure
   domain.
2. **The durable record.** Today every chat message is a Firestore document, which is simultaneously the
   transport, the reload mechanism, and the research record. On AgentCore the client holds the
   transcript. For education apps we almost certainly still want the Firestore record — so the likely
   shape is **the client writes to Firestore for the record and talks to the agent over the socket for
   the turn**, i.e. Firestore stops being the transport and becomes the log. That is a clean design, but
   it is a real change to the client and to the security-rules story, and it needs to be thought through
   rather than assumed.
3. **Identity.** DAVAI's anonymous Cognito path is fine for a public CODAP plugin. CLUE and AP have real
   portal identity and use Firestore rules to enforce it. An AWS-side agent would need its own way to
   verify a portal-issued identity, and the "unauth role can invoke the runtime" model does not provide
   it.
4. **Latency, measured rather than assumed.** If a server-side Firebase read *is* needed, the cross-cloud
   round-trip cost should be measured, not guessed. The chat drain does several Firestore operations per
   turn; the analysis pipeline does many more.

---

## 8. Directions worth thinking about

The immediate reason to read this document is orientation: the next work on the CLUE document analysis
system (D) goes much better with a picture of the other five systems in your head, because several of
them solved adjacent problems differently and some of those solutions are better than the one in front
of you.

Beyond that, there is an open invitation. Nobody has yet sat down and asked what a **single** design
serving all of these use cases would look like. That question is worth someone's attention, and it is
open to whoever wants it. What follows is not a menu to be priced — it is two shapes the current
evidence points toward, offered as starting points. **Concluding that neither is right and proposing
something else is a perfectly good outcome, as is concluding that the estate is fine as it is.**

**Split by workload class.** One architecture for interactive/agentic work (the AgentCore shape:
container, WebSocket, client-executed tools), one for batch/analysis work (the CLUE shape: event-driven
functions and document queues, sitting next to the data). Two architectures on purpose instead of six by
accident. Section 7 suggests this line falls in a natural place — the features with no server-side
Google-cloud dependency are exactly the interactive ones.

**One agent service, multiple transports.** A single agent runtime fronted by an adapter layer:
WebSocket for DAVAI and for the chat tutors, with Firestore demoted from transport to durable record.
The larger claim, and the more interesting one. The unproven parts are the identity story (§7) and the
client rework.

**Two things deliberately left off this list.** Extracting shared libraries — a provider abstraction, a
drain/lock engine, a summarizer contract — would remove real duplication, and it will probably be worth
doing eventually. But it is the small version of this question: it deletes duplicate code without asking
whether the shapes being deduplicated are the right shapes. It should not be allowed to crowd out the
big-picture work. And consolidating everything onto Firebase is not a candidate, because we do want
agentic behavior in the other apps (§9) and Firestore-document transport makes tool round-trips
expensive.

---

## 9. What is settled, and what is open

### Settled — treat these as constraints, not questions

1. **The education apps do want agentic behavior.** Client-side tool calling — a tutor that can inspect
   or act on the student's work, rather than only receive whatever snapshot was pushed with the message
   — is wanted in CLUE and AP, not only in DAVAI. A design that cannot get there is not a candidate.
2. **Do not stay on OpenAI's Conversations API.** Conversation state should move to something we own.
   Doing it while there are two implementations rather than five is much cheaper than doing it later.
3. **Retaining student conversation content on OpenAI is not acceptable.** `store: true` has to go.
   This and the previous point are really one decision: the Conversations API is not usable without
   server-side retention.
4. **Shared state for throttling and accounting is fine.** The AgentCore design's avoidance of shared
   state was aimed at a specific thing — using a database to *pass data between queued jobs*, which is
   an inefficient way to move a conversation through a pipeline. A small store whose job is to
   **record, track, and throttle requests** is a different animal, and adding one is not a regression
   against what that design bought. This closes the per-caller-throttling gap named in §6, and it makes
   the spend-attribution gap in §4 straightforwardly solvable.

### Open — worth considering

1. **Can the CLUE chat tutor run on AgentCore with no server-side Firebase access at all** — the client
   pushing context over the socket and writing the Firestore record itself? If yes, most of the
   cross-cloud concern evaporates for exactly the features worth moving (§7).
2. Where server-side Firebase access *is* needed, **what does a cross-cloud RTDB/Firestore round-trip
   actually cost** from `us-east-1`, and what is the credential-handling story for a service account
   living in AWS?
3. Given decision 2 above, **where does conversation state go instead?** The in-VM checkpointer plus a
   client-held transcript (the AgentCore answer), a LangGraph checkpointer over a store we run, or
   something else. This is now a design question rather than an open choice.
4. **What is the identity model** for an AWS-hosted agent serving CLUE or AP? DAVAI's anonymous Cognito
   path is fine for a public CODAP plugin; CLUE and AP have real portal identity enforced by Firestore
   rules, and the unauth-role model does not carry it.
5. **How do triggers work** for anything that must react to a data change in Google Cloud from outside
   it? A thin forwarding function, Eventarc → Pub/Sub, or a design that removes the need (§7).
6. Can server-side AI deployment move **into CI** for all three repos? What does staging look like when
   the expensive dependency is a metered third-party API?
7. Where does **in-browser inference** fit? We already ship working WebLLM code; if small local models
   get good enough for routine tutor turns, the cost and privacy calculus changes substantially.
8. Does **AgentCore** hold up as a standard, setting throttling aside? It is a second cloud alongside
   Firebase and a young AWS service.

---

## Appendix — code map

**DAVAI (`concord-consortium/davai-plugin`)**
- `sam-server/template.yaml` — the full production AWS topology
- `sam-server/src/handlers/{message,tool,status,cancel,job-processor}.ts` — the request lifecycle
- `sam-server/src/utils/llm-utils.ts` — `createModelInstance()`, `getLangApp()`, provider switching
- `sam-server/src/utils/tool-utils.ts` — tool declarations + tool-repair logic
- `src/models/assistant-model.ts` — client polling loop, `processToolCall`
- `src/app-config.json` — the selectable model list
- `src/utils/local-llm/` — in-browser inference
- **AgentCore, three stacked open PRs:** #116 `feat/agentcore-backend` (container, parity harness, docs)
  → #117 `feat/agentcore-infra` (CloudFormation + Cognito) → #115 `feat/agentcore-migration-poc`
  (direct browser WebSocket transport). Key files: `backend/src/{server,ws,runner}.ts`,
  `infra/cloudformation.yml`, `infra/DEPLOYED.md`, `src/utils/ws-transport.ts`,
  `scripts/agentcore-cognito-smoke.mjs`, `done-loop/`, and `docs/agentcore/`
  (`P5-final-report.md`, `design.md`, `latency-findings.md`, `research/current-backend-map.md`).
  Experiment repo: `concord-consortium/davai-agentcore`.

**CLUE (`concord-consortium/collaborative-learning`)**
- `functions-v2/src/on-analyzable-doc-written.ts`, `on-analysis-document-pending.ts`,
  `on-analysis-document-imaged.ts` — the three-stage analysis pipeline
- `functions-v2/lib/src/ai-categorize-document.ts` — OpenAI calls, zod schemas, embeddings, `findNearest`
- `functions-v2/src/on-document-summarized.ts` — the agreement → embedding → vector store loop
- `functions-v2/src/on-class-data-doc-written.ts`, `get-ai-content.ts`, `generate-class-data.ts`,
  `at-midnight.ts` — class summary and AI tile
- `functions-v2/src/chat-tutor.ts`, `functions-v2/src/chat/{drain,openai,context-assembly}.ts` — chat tutor
- `shared/ai-summarizer/` — document → markdown
- `src/components/chat-tutor/`, `src/plugins/ai/`, `src/components/navigation/ai-summary.tsx` — clients

**Activity Player chat (`concord-consortium/report-service` + `activity-player`)**
- `functions/src/chat-tutor.ts`, `functions/src/chat/{drain,openai,chat-context,convert,fetch-activity,sim-prompts,page-walk,generic-prompt}.ts`
- `activity-player/src/components/chat/` (on `master`), `src/utilities/chat-context.ts`

**Adjacent (scoped out)**
- `concord-consortium/cc-data-cli` — researcher CLI + MCP server exposing report data to an external agent
- `concord-consortium/google-docs-mcp` — MCP server
- `concord-consortium/davai-openai-proxy` — superseded 2024 bearer-token proxy
