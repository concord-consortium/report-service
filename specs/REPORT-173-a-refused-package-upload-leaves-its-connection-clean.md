# A refused package upload leaves its connection clean

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-173

**Status**: **Closed**

## Overview

When report-server refused a package upload after reading its body (a 422 from validate, a 403, and so on), the next request on the same keep-alive connection could fail with a bare, non-JSON `400`, or get no answer at all. Behind the load balancer that next request may be anyone's. This story makes both upload routes leave the connection exactly where a clean request would.

**The cause.** `create` and `validate` in `server/lib/report_server_web/api/v1/package_controller.ex` read the archive inside a `with`, which rebinds `conn` only inside the `with`, and rendered refusals with the original `conn`, whose Bandit adapter still described the body as unread. After the response, Bandit's `ensure_completed/1` (`deps/bandit/lib/bandit/http1/socket.ex`) drained that many bytes off the socket, where they belonged to the next request, and then parsed what remained of it as a request line (`Request line HTTP error`). A next request shorter than the drain was swallowed whole: Bandit waited out the read timeout, logged "Unable to read remaining data in request body" and closed the connection. Found on staging on 2026-10-09 during REPORT-146's refusal checks (stream channel #126) and reproduced locally against a real Bandit listener.

**Why it was transient.** Only the body bytes not read together with the headers are drained: Content-Length minus whatever arrived in the same read. A refused body that arrives with its headers costs nothing, so the bug depends on how the body was segmented on the way in.

## Requirements

- **R1.** Once `read_body` has been called, `create` and `validate` render every response, refusal or success, with the conn it returned. That covers both a whole body and a read that stalled past the read timeout (`{:more, …}`).
- **R2.** A refusal before the body is read (wrong Content-Type, no Content-Length, a declared size over 10 MiB) behaves as before, with the original conn, so Bandit drains the unread body itself.
- **R3.** No route's contract changes: same statuses, same `{"error","message"}` bodies, same order of checks.

## Technical Notes

- **The change.** Each action splits at `read_archive/1`: the steps after it run in `publish/3` or `validate_archive/3`, which only ever see the read conn. `read_declared/1`'s stalled branch returns `{:error, :unprocessable, "the archive exceeds 10 MiB", conn}`, and each action's outer `else` renders that four-element error with its conn.
- **The tests** (`server/test/report_server_web/api/v1/package_controller_connection_test.exs`) run against a real Bandit listener on `ReportServerWeb.Endpoint` with raw `:gen_tcp`, because `Phoenix.ConnTest` never reaches the socket. A refused validate and a refused create each write their body 100 ms after their headers; written in one piece, the pair passes without the fix. The stalled-read test uses a 1-second read timeout and 1,500,000 bytes of a 2,500,000-byte body. In each test, the next request on the same connection must get 200.
- No other controller reads a body: `Plug.Parsers` reads JSON, urlencoded and multipart bodies in the endpoint and passes the updated conn on, and `read_body` appears only in `PackageController`.
- Bandit 1.5.7's `ensure_completed/1` and its `bytes_remaining` arithmetic are the same as 1.5.0's, so upgrading would not help.
- An over-10 MiB declared size is refused before the read, and Bandit's drain reads at most 8,000,000 bytes, so it raises "Unable to read remaining data" and closes the connection after the 422. That costs only the caller's connection, and R2 keeps it.
- `{:more, …}` is reached only by a stall: the declared size is at most 10 MiB and the read asks for 10 MiB. A stall shorter than one 1,000,000-byte chunk leaves Bandit's state unchanged (`gen_tcp` keeps the partial chunk), so only the larger case lost the next request.
- A refusal that raises after the read is not affected: Bandit closes the connection after any 5xx exception, so no drain runs.

## Out of Scope

- Bandit itself: no upgrade or patch, since 1.5.7 behaves the same and the fault was the controller's conn.
- A clearer message for a stalled upload (see Decisions).
- The other package routes (`applies`, `list`, `index`, `resolve`, `update_state`), which read nothing themselves.

## Not Yet Implemented

- **The staging check** waits on the deploy: REPORT-173 rides the report-server pre-release that carries REPORT-168 (`1.13.0-pre.2` unless another goes out first), deployed by REPORT-168's rollout, and production comes with REPORT-164's 1.13.0. After that deploy:
  1. With the released `v0.3.0-pre.1` cc-data, REPORT-146's sequence: `package build` on a 7,201-second manifest (exit 5, `UNPROCESSABLE`), `package run` on the same package (exit 5, same 422, nothing staged), then a valid package's validate. No `HTTP_400`.
  2. The same manifest plus a padding file of about 1 MiB, refused 20 times by `package build`, each followed by a build of the valid package. A 1 MiB body can't arrive with its headers, so without the fix each refusal would leave a log line; this is what makes a clean log meaningful.
  3. In `/ecs/report-server` on staging, from the first step to two minutes after the last (past Bandit's 60-second read timeout): no `Request line HTTP error` and no "Unable to read remaining data in request body".
  4. Post the result on the stream channel.

## Decisions

### Is the `{:more, …}` branch in scope?
**Context**: It was first thought unreachable. Self-review showed a body stalled past the read timeout reaches it, and after a full 1,000,000-byte chunk it loses the next request even with the split.
**Options considered**:
- A) Leave it, as unreachable
- B) Return its conn and cover it with a test

**Decision**: B. R1 covers it, with its own regression test.

---

### Should a stalled upload get a clearer message than "the archive exceeds 10 MiB"?
**Context**: The message misdescribes a stall, but changing it changes the API's answers.
**Options considered**:
- A) Keep the message
- B) Change it in this story

**Decision**: A (Doug, 2026-10-11). The API's answers don't change (R3); a clearer message would be a separate change.

---

### Should R2 have its own regression test?
**Context**: A refusal before the read with a delayed body was checked locally and is followed by a 200 both before and after the fix.
**Options considered**:
- A) Add a test
- B) Rely on the existing validate and create tests, which pin those refusals' statuses and bodies

**Decision**: B. A test that passes either way can't catch anything this change could break.

---

### How should the staging check show the fix works?
**Context**: The bug depends on segmentation, so a clean log after a small refusal proves little.
**Options considered**:
- A) Rerun REPORT-146's sequence alone
- B) Add a refused upload padded to about 1 MiB, repeated 20 times, and search the log for both Bandit errors

**Decision**: B, alongside REPORT-146's sequence.
