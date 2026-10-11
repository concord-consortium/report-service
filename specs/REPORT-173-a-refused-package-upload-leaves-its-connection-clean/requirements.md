# A refused package upload leaves its connection clean

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-173
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

When report-server refuses a package upload after reading its body (a 422 from validate, a 403, and so on), the next request on the same keep-alive connection can fail with a bare, non-JSON `400`, or get no answer at all. Behind the load balancer that next request may be anyone's. This story makes both upload routes leave the connection exactly where a clean request would.

## Background

**What was seen.** On 2026-10-09 around 19:20 UTC, during REPORT-146's refusal checks against staging (report-server `1.13.0-pre.1`, stream channel #126), two cc-data calls got `HTTP 400` with an empty, non-JSON body, and a rerun got 200. report-server logged two `(Bandit.HTTPError) Request line HTTP error` entries at 19:20:35, each about 300 ms after a validate answered 422, and the bytes on each "request line" were the session's next upload from offset 88. A 403 validate at 19:36:39 had no request behind it, and Bandit logged "Unable to read remaining data in request body" a minute later. #126 named the failing route as `applies`; the log shows the victims were the next validate uploads.

**The cause** (`server/lib/report_server_web/api/v1/package_controller.ex` at `f5adf65`). `create` and `validate` read the archive with `read_archive/1` inside a `with`, which rebinds `conn` only inside the `with`. The `else` branch renders the refusal with the original `conn`, whose Bandit adapter still describes the body as unread. Bandit's pipeline takes the transport from the conn the plug returns and, after the response, calls `ensure_completed/1` (`deps/bandit/lib/bandit/http1/socket.ex`) to drain what it thinks is left of the body. It reads those bytes off the socket, where they now belong to the next request, and then parses what remains of that request as a request line. If no request follows, it waits out the read timeout and logs "Unable to read remaining data".

**Corrections to the Jira story, checked against the code and a local reproduction:**

- **It eats less than Content-Length, and only sometimes.** The stale state says how many body bytes were still on the wire after Bandit's header read, so `ensure_completed/1` reads that many: Content-Length minus whatever arrived in the same read as the headers. A refused upload whose body arrived with its headers costs nothing, which is why the 400 was transient: it depends on how the body was segmented on the way in. A larger archive makes it near certain.
- **A shorter next request gets no answer at all.** When the next request is no longer than the bytes the drain still wants, it is swallowed whole: the drain waits out the read timeout, logs "Unable to read remaining data" and closes the connection without a response (checked: a 28-byte GET after a delayed 375-byte refusal, closed with no response after the listener's 2-second read timeout).
- **A stalled body takes the same path.** `read_declared/1`'s `{:more, …}` branch does occur: when the body stalls past Bandit's read timeout, `read_body` returns `{:more, partial, conn}` and the action refuses with 422 "the archive exceeds 10 MiB". Once Bandit has read at least one 1,000,000-byte chunk, that refusal rendered with the earlier conn swallows the next request too (checked: 1.5 MB of a 2.5 MB body, a 1-second stall, then the rest and a valid validate: 422, then the connection closed with no response).
- **The regression test has to send the body after the headers.** A test that writes the request in one piece passes without the fix (checked: 422 then 200). The Done when below says so.
- **Confirmed:** Bandit 1.5.7's `ensure_completed/1` and its `bytes_remaining` arithmetic are the same as 1.5.0's, so upgrading would not help. No other controller reads a body: `Plug.Parsers` reads JSON, urlencoded and multipart bodies in the endpoint and passes the updated conn on, and `read_body` appears only in `PackageController`.

**Reproduced locally** with a throwaway test (deleted) against a real Bandit listener on `ReportServerWeb.Endpoint`. For each of validate and create: a 7,201-second manifest with its body sent 100 ms after its headers answered 422, and a following valid validate on the same socket got `400` with an empty body, while the log showed `Request line HTTP error` on that validate's zip bytes. Sent in one write, the same pair answered 422 then 200. A wrong Content-Type refusal (before the body is read) with a delayed body was followed by a 200 too. With the fix, every case answered 200, and the 309 tests under `test/report_server_web/api/v1/` passed.

## Requirements

- **R1.** Once `read_body` has been called, `create` and `validate` render every response, refusal or success, with the conn it returned. That covers both a whole body and a read that stalled past the read timeout (`{:more, …}`).
- **R2.** A refusal before the body is read (wrong Content-Type, no Content-Length, a declared size over 10 MiB) behaves as it does now, with the original conn, so Bandit drains the unread body itself.
- **R3.** No route's contract changes: same statuses, same `{"error","message"}` bodies, same order of checks.

## Done when

- A regression test against a real Bandit listener sends a validate that is refused after its body is read, writing the body separately after the headers, then a second request on the same keep-alive connection, and the second is answered normally. The same for `create`, and for a validate whose body stalls past the listener's read timeout after more than 1,000,000 bytes. Each fails without the fix.
- On staging, after the pre-release that carries REPORT-168 and this story: REPORT-146's refusal sequence (a 7,201-second manifest refused with 422, then another upload from the same session) and a repeated large refused upload each answer as expected, and report-server's log over the check window has no `Request line HTTP error` and no "Unable to read remaining data in request body". See the implementation's staging check.

## Technical Notes

- An over-10 MiB declared size is refused before the read, and Bandit's drain reads at most 8,000,000 bytes, so it raises "Unable to read remaining data" and closes the connection after the 422. That is today's behavior, it costs only the caller's connection, and R2 keeps it.
- `read_declared/1`'s `{:more, …}` branch is reached only by a stall: the declared size is at most 10 MiB and the read asks for 10 MiB, so a body that keeps arriving is returned whole. A stall shorter than one 1,000,000-byte chunk leaves Bandit's state unchanged (`gen_tcp` keeps the partial chunk), which is why only the larger case loses the next request.
- A refusal that raises after the read is not affected: Bandit closes the connection after any 5xx exception (`Bandit.Pipeline.handle_error/5` returns `{:error, _}`), so no drain runs.

## Out of Scope

- Bandit itself: no upgrade or patch, since 1.5.7 behaves the same and the fault is the controller's conn.
- A clearer message for a stalled upload. Doug decided on 2026-10-11 to keep refusing it as "the archive exceeds 10 MiB", though that misdescribes a stall, so the API's answers don't change (R3). A clearer message would be a separate change.
- The other package routes (`applies`, `list`, `index`, `resolve`, `update_state`), which read nothing themselves.
