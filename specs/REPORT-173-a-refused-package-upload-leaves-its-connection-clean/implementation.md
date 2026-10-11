# Implementation Plan: A refused package upload leaves its connection clean

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-173
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

One commit (the change and its test), then the staging check after REPORT-168's deploy. All code is in `server/`. No migration.

### Render with the conn that read the body

`server/lib/report_server_web/api/v1/package_controller.ex`. Split each action at the read, so the steps after it run in a function that only ever sees the read conn:

```elixir
def create(conn, params) do
  with :ok <- zip_content_type(conn),
       {:ok, body, conn} <- read_archive(conn) do
    publish(conn, body, params)
  else
    {:error, kind, message} -> ErrorHelpers.render_error(conn, Map.fetch!(@error_codes, kind), message)
  end
end

defp publish(conn, body, params) do
  with {:ok, official?} <- official_param(params["official"]),
       {:ok, %{package: package, version: version}} <- Packages.publish(...) do
    # the existing 201 body, unchanged
  else
    {:error, kind, message} -> ErrorHelpers.render_error(conn, Map.fetch!(@error_codes, kind), message)
  end
end
```

`validate` gets the same shape with a `validate_archive/3`. The outer `else` renders refusals from before the read (R2) and the inner one refusals after it (R1).

The stalled read (R1's `{:more, …}`) returns its conn too: `read_declared/1`'s branch becomes `{:more, _partial, conn} -> {:error, :unprocessable, "the archive exceeds 10 MiB", conn}`, and each outer `else` gains `{:error, kind, message, conn} -> ErrorHelpers.render_error(conn, Map.fetch!(@error_codes, kind), message)`. The order of checks, statuses and bodies are unchanged (R3). This exact change, with the stalled-read clause, was run locally: every reproduction passed and the 309 tests under `test/report_server_web/api/v1/` stayed green.

The comment above `read_archive/1`'s callers should say why the read conn matters, for example on the private functions: "Every response after the read uses the conn read_body returned: rendered with the earlier conn, Bandit would drain the body again from the next request on the connection."

### The regression test

New file `server/test/report_server_web/api/v1/package_controller_connection_test.exs`, `use ReportServerWeb.ConnCase, async: false` (so the sandbox is shared with the listener's processes), with the validate test file's setup (`register_and_put_bearer_token`, `PackagesMemoryStore.start/0`, `PackagesPortalStub`).

- **The listener.** `start_supervised({Bandit, plug: ReportServerWeb.Endpoint, ip: :loopback, port: 0, startup_log: false})`, port from `ThousandIsland.listener_info/1`. ConnCase's `Phoenix.ConnTest` never reaches Bandit, which is why the existing tests can't see this.
- **The client.** A raw `:gen_tcp` socket (`[:binary, active: false]`), HTTP/1.1 with the bearer from setup. Read each response by switching the socket to `packet: :http_bin` for the status line and headers, then `packet: :raw` for `content-length` bytes. Import nothing named `head`: `Phoenix.ConnTest.head/3` is already imported.
- **One test per route** (validate, create): write the headers of a `package_zip(%{"expected_duration_seconds" => 7_201})` upload, sleep 100 ms, then write its body. Assert 422 with the `UNPROCESSABLE` envelope. Then write a whole valid validate (`package_zip(%{"version" => "1.0.2"})`) on the same socket and assert 200 with its JSON. The second request must be longer than the first body (556 bytes against 375, since it carries a zip of the same size plus headers): a shorter one is swallowed whole without the fix, so the test would fail only on the client's receive timeout instead of on a quick 400.
- **The stalled read** (validate only, since both actions share `read_archive/1`): a listener started with `thousand_island_options: [read_timeout: 1_000]`, headers declaring a 2,500,000-byte body, 1,500,000 bytes of it, a wait for the 422 "the archive exceeds 10 MiB", then the remaining bytes and a whole valid validate, asserting 200. Without the stalled-read clause the connection closes with no second response: checked locally. It costs about a second.
- **What each test catches.** Without the fix, the second response is `400` with an empty body, and the log shows `Request line HTTP error`: checked locally for both routes. The 100 ms gap is what makes it fail: written in one piece, the pair passes without the fix, so don't "simplify" the two writes into one.
- **No test for R2:** a refusal before the read with a delayed body was checked locally and passes before and after the fix, so a test for it would not fail on anything this change can break. The existing validate and create tests already pin those refusals' statuses and bodies.

### Release and the staging check

Not a commit. This merges before REPORT-168's staging deploy (tracker 6.3) so it rides the same pre-release (`1.13.0-pre.2` unless another goes out first), deployed by REPORT-168's rollout; it needs no deploy of its own. Production comes with REPORT-164's 1.13.0. After that deploy:

1. **REPORT-146's sequence.** With the released `v0.3.0-pre.1` cc-data, as in #126: `package build` on the 7,201-second manifest (exit 5, `UNPROCESSABLE`), then `package run` on the same package (exit 5, same 422, nothing staged), then a valid package's validate. Each answers as expected, with no `HTTP_400`.
2. **A refusal large enough to always split.** The 7,201-second manifest plus a padding file of about 1 MiB (well over one TCP segment, well under 10 MiB), refused 20 times by `package build`, each followed by a build of the valid package. Every refusal exits 5 with the 422, and every valid build succeeds.
3. **The log.** In report-server's staging log group (`/ecs/report-server`, from `cloud-formation/fargate/report-server.yml`'s `/ecs/<ServiceName>`), from the first step to two minutes after the last (past Bandit's 60-second read timeout): no `Request line HTTP error` and no "Unable to read remaining data in request body".
4. Post the result on the stream channel.

Step 2 is what makes a clean log meaningful: without the fix, a 1 MiB body can't arrive with its headers, so each refusal would have produced one of those two log lines.

## Self-Review

Roles: Senior Engineer (Bandit and Plug internals), QA Engineer, Security Engineer, DevOps Engineer. Each item was checked against the code and, where it says so, a throwaway test (deleted) against a real Bandit listener.

- **RESOLVED (Senior Engineer): the `{:more, …}` branch is reachable.** A body stalled past the read timeout after one 1,000,000-byte chunk lost the next request, with and without the split. R1, the plan and the tests now cover it.
- **RESOLVED (Senior Engineer): a shorter next request is swallowed, not answered 400.** Reproduced; the Overview and Background say so.
- **RESOLVED (QA Engineer): the API test count was 313; it is 309** at `7729447` with the change applied.
- **RESOLVED (QA Engineer): the second request's length.** Its reason was wrong (the bearer header alone is not enough); the measured sizes and the failure mode now stand in for it.
- **Dropped (Security Engineer): a raise after the read.** Bandit closes the connection after a 5xx exception, so no stale drain follows (`pipeline.ex`, `http1/handler.ex`).
- **Dropped (DevOps Engineer): the staging log group.** `/ecs/report-server` matches the template's default `ServiceName` and the release skill's `RS_LOG_GROUP`; staging and production are separate accounts.
