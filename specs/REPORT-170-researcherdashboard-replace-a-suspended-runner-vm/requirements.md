# researcherDashboard: replace a suspended runner VM on an old image instead of resuming it

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-170
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

When the function would wake a researcher's suspended MicroVM that runs an older runner image, it retires that VM instead: a run request replaces it with a VM on the current image, and the watchdog terminates it and leaves the queued work for the researcher's next run request. A VM suspended partway through a run is still resumed, so the run can finish.

## Project Owner Overview

Each researcher gets a private machine that runs their packages, and it sleeps when idle. When we release a new version of the runner, a sleeping machine wakes up as the old version, so a researcher can keep running on old code indefinitely. Today an operator has to run a cleanup command by hand after every release, and rerun it until every old machine has gone to sleep and been removed.

After this change the function notices an old machine at the moment it would wake it, and starts a fresh one on the current version instead. Nothing a researcher is in the middle of is lost: a machine that is running, or that was put to sleep partway through a run, is left to finish. The manual cleanup becomes optional.

## Background

A runner release builds a new `MicrovmImage` version on the runner stack (researcher-dashboard `cloudformation/README.md`, "Releasing the runner"). A VM keeps the image version it was launched on for its whole life, up to `MAXIMUM_DURATION_SECONDS` (8 hours, `ensure-vm.ts`), suspended or not. Two paths wake a suspended VM, and neither looks at its version:

- **`ensureVm`** (`ensure-vm.ts`), on every run request after `/run-package` queues the work: it asks `GetMicrovm` for the recorded VM's state and, on `SUSPENDED`, calls `wakeSuspended`. A `RUNNING` or `PENDING` VM is left alone (`"running"`), and so is a `SUSPENDING` one (`"suspending"`); a VM that is gone, `TERMINATING` or `TERMINATED` is replaced by a launch under the launch claim (`launching_until`).
- **The watchdog** (`watchdog.ts`, REPORT-143 R19): for each VM in `vms/` launched within its life that `GetMicrovm` reports `SUSPENDED` while the researcher has queued work, it calls the same `wakeSuspended`. It never launches: a launch mints the researcher's report-server token from the portal assertion that only a run request carries.

REPORT-143 made `wakeSuspended` the one place to decide which suspended VMs to wake, and passes it the VM's recorded `image_version` for this story (REPORT-143 R19). `launch` already reads the image's `latestActiveImageVersion` with `GetMicrovmImage`, pins `RunMicrovm` to it, and `recordLaunch` stores the version `RunMicrovm` returns on `vms/{platform_user_id}` as `image_version`. The launcher role already holds `lambda:GetMicrovmImage` and `lambda:TerminateMicrovm` (researcher-dashboard `cloudformation/researcher-dashboard-runner.yml`), so no stack change is needed.

Until this lands, a release retires old VMs with the README's version-filtered loop, run with an operator's own credentials (the launcher cannot list VMs). It terminates only `SUSPENDED` VMs on another version, rereading each one's state just before terminating, and has to be rerun until it terminates nothing; its README says the remaining race, a resume landing between the read and the terminate, goes away only once the function replaces old VMs itself. RD-4 pass 2's QA release (0.2.0, `landing-tracker.md` 3.4) uses that loop, since this story comes after it.

The story came from Ethan McElroy's review of researcher-dashboard PR #2 (RD-4 pass 1). Jira is the authoritative scope; where this spec differs, it says why (R3, a VM suspended mid-run).

## Requirements

### The decision, in `wakeSuspended`

- **R1.** A suspended VM is **stale** when the image has an active version (`GetMicrovmImage`'s `latestActiveImageVersion` is a non-empty string) and the VM's recorded `image_version` is missing, null, or not equal to it. Versions are compared as strings, exactly as the README's loop compares `imageVersion` with `latestActiveImageVersion`. With no active version there is nothing to compare against, and the VM is not stale.
- **R2.** `wakeSuspended` makes the decision for both paths. Each caller asks `GetMicrovmImage` for the active version and passes it in, beside the VM's id and recorded `image_version`, so each handles that call's failure in its own way (R5) and the call is never inside a transaction, which can retry and must not span a network call. Inside the transaction, which already reads `vms/{platform_user_id}`, it answers one of three ways:
  - **resumed**: as today, it writes `resumed_at` and then calls `ResumeMicrovm`;
  - **replace**: the VM is stale and R3 does not keep it. Nothing is written and nothing is resumed; the caller acts (R7, R9);
  - **held**: `vms/` records another VM, a launch claim is live (R4), or (the watchdog only) the budget is spent. Nothing is resumed; as today, the budget is checked after the `resumed_at` write.
- **R3.** **A VM suspended mid-run is resumed even when stale.** When a `running` result in the researcher's queue names the VM in `microvm_id` (the test `/idle` and the idle sweep already use, `runningOn`), `wakeSuspended` resumes it as today. The transaction reads the queue only for a stale VM, so a wake on the active version reads nothing more than it does today. RD-3 pass 2's Resume control wakes a VM paused partway through a run through `ensureVm` so that the VM finishes it (RD-4 pass 2 R20), and replacing that VM would turn Resume into a kill: R17 would fail the run with "The machine running it stopped before the run finished". This is the Jira description's "a VM mid-run on the old image is never terminated by this path" applied to a suspended VM, where its first bullet reads literally as replacing every suspended stale VM. The resumed VM finishes its run and then takes the queue on the old image; once it idles and suspends, the next wake replaces it.
- **R4.** `wakeSuspended` resumes nothing while `vms/`'s `launching_until` is in the future. Today nothing reaches it with a live claim, since `ensureVm` claims only when the VM is gone; with R7's replace holding a claim over a `SUSPENDED` VM, the claim says a launch is about to take the work, and a concurrent wake must not resume the VM that launch is retiring.
- **R5.** A failed or timed-out `GetMicrovmImage` decides nothing: `ensureVm` answers 502 `GetMicrovmImage failed: <reason>`, as its launch does today, and the watchdog logs `watchdog.upstream_failed` with `call: "GetMicrovmImage"` and leaves the VM for its next pass. The work stays queued either way. Falling back to a resume would make the two paths disagree about the same VM during an outage, so a watchdog resume could race a replace.
- **R6.** The replace branch writes nothing, so it never writes `resumed_at`. Only the resume branch writes it, after the decision, in the same transaction.

### `ensureVm`: replace means terminate, then launch

- **R7.** `ensureVm` asks `GetMicrovmImage` once per request, only when the recorded VM is `SUSPENDED` (for the decision) or gone (for the launch, as today), and a launch pins the version it got. So the launch path asks before taking the claim rather than after, and a failure there answers the same 502 with no claim to clear. On replace, `ensureVm` launches through the launch path it already has, with that version:
  1. It takes the launch claim in the existing transaction, which claims only while no claim is live and `vms/` still records the VM it read, so two requests replacing the same VM launch one VM and terminate it once. A request that does not get the claim answers `"launching"` and terminates nothing.
  2. It launches: the report-server token mint and `RunMicrovm`, pinned to that version, with no second `GetMicrovmImage`, then `recordLaunch`, exactly as a launch over a gone VM does today, with today's claim and failure handling. If the launch fails, the old VM is still suspended and still recorded, and the next request decides again.
  3. Only once the new VM is recorded does it call `TerminateMicrovm` on the old one. A failure there is logged as a warning naming both VMs, through a logger `ensureVm` gains (`functions.logger`, as `/run-package` already has), and does not fail the request: the old VM is suspended, no longer recorded, so nothing wakes it, and its sessions are already refused by REPORT-143 R3a (signed in before the new `launched_at`). It ends at its 8-hour maximum life, or with the README's loop.
  4. It answers `"launched"`, the outcome a launch already reports. `VmOutcome` gains no value, so rigse, which passes `vm` through as a string, and RD-3 see nothing new.
- **R8.** **The time bound.** Terminating last keeps a replace's calls before `recordLaunch` the same as a launch's today (`GetMicrovm`, `GetMicrovmImage`, the mint and `RunMicrovm`, at 10 seconds each, plus a credential refresh), inside the function's 60 seconds; `TerminateMicrovm` is the fifth call, so a request cut off by the timeout loses only the terminate, which R7.3 already tolerates. The function's `timeoutSeconds` is unchanged.

### The watchdog: replace means terminate

- **R9.** When the watchdog's R19 pass would wake a suspended VM with queued work and `wakeSuspended` answers replace, the watchdog calls `TerminateMicrovm` on it (the budget checked first, REPORT-143 R16), writes nothing, launches nothing, and logs `watchdog.vm_terminated` with `reason: "old_image"`, a third value beside REPORT-143 R21's `lease` and `suspended_mid_run`. A failed terminate is logged as `watchdog.upstream_failed` with `call: "TerminateMicrovm"` and writes nothing.
- **R10.** After that terminate, nothing new is needed: once `GetMicrovm` reports the VM `TERMINATED` or unknown, R19a writes the runner document `state: terminated`, clears `current_package` and keeps the queue; RD-3 pass 2 renders `terminated` as "run it to start one" with Run enabled on a queued row (its R8); and the researcher's next run request finds the VM gone and launches one on the active version, which takes the kept queue. Work no request ever takes is failed by R17a after eight hours and ten minutes, as any unclaimed work is.
- **R11.** The watchdog asks `GetMicrovmImage` at most once per pass, and only when a suspended VM with queued work reaches the wake, budget-checked like every upstream call; a failure is R5's and leaves every wake in that pass undone. It needs the image identifier, `RD_MICROVM_IMAGE_ARN`, which `researcherDashboard` already reads.

### What is left alone

- **R12.** `RUNNING` and `PENDING` VMs (`"running"`) and `SUSPENDING` VMs (`"suspending"`) are left as they are, whatever their image: a running VM on an old image finishes its work and suspends once idle, and is replaced at the next wake. A VM `GetMicrovm` reports with no state is left alone, as REPORT-143 made it. No path terminates a VM with a `running` result: the only terminates this story adds are of a VM that is `SUSPENDED` and named by no `running` result (R3), so REPORT-143's lease (R17) and the `/terminate` hook's write never meet a VM this story ended. R17, R17a, R18 and R19a are unchanged.

### Documentation

- **R13.** `functions/README.md`'s `run-package` paragraph says a suspended VM on an older image version is replaced rather than resumed unless it was suspended mid-run, and its watchdog paragraph says such a VM with work queued behind its suspend is terminated, and the work waits for the next run request.
- **R14.** Once this is deployed to report-service-dev, researcher-dashboard's `cloudformation/README.md` "Releasing the runner" says the termination loop after a release is optional cleanup for a stack whose function is at Functions 1.9.0 or later (this story's fix version), so the same text holds for production, whose function is not yet deployed with it, and stays required below that version: the function replaces a suspended old-version VM at the researcher's next run request, the watchdog terminates one with queued work, and the loop only retires VMs whose researchers do not return before their 8-hour life ends. It drops the sentence saying only the function replacing old VMs removes the race, and says the loop, unlike the function, also terminates a VM suspended mid-run, whose run then fails. The grant-changing loop that follows it is unchanged and still required. This is a separate researcher-dashboard PR.

### Tests

- **R15.** Unit tests cover, with the existing fakes in `ensure-vm.test.ts` and `watchdog.test.ts`:
  - `ensureVm`, suspended VM on the active version: resumed, `resumed_at` written, nothing terminated or launched.
  - On an old version: claim, launch pinned to the active version with one `GetMicrovmImage`, `recordLaunch`, then `TerminateMicrovm` on the old VM, in that order; answers `"launched"`; `resumed_at` not written.
  - With no recorded version: replaced the same way.
  - With no active version: resumed.
  - Stale but named by a `running` result in the queue: resumed, nothing terminated.
  - Stale with a live launch claim: nothing resumed, terminated or launched; answers `"launching"`.
  - `GetMicrovmImage` fails: 502, nothing resumed, terminated or launched.
  - `TerminateMicrovm` fails after the new VM is recorded: answers `"launched"`, logs both VMs.
  - The launch fails on a replace: the old VM is not terminated.
  - A running VM on an old version: left alone, no `GetMicrovmImage` call.
  - The watchdog, suspended old-version VM with queued work: terminated, logged `old_image`, no write to `vms/`, the runner or any result, no launch call; a later pass that sees it `TERMINATED` marks the runner document terminated (R19a).
  - The watchdog, stale but mid-run: resumed.
  - The watchdog: one `GetMicrovmImage` for two suspended VMs in one pass; its failure logs `upstream_failed` and resumes nothing; out of budget before it, no call.

### The live check

- **R16.** *(runs after the deploy; it does not gate the merge)* At the first runner release to the QA stack after this story is deployed to report-service-dev, the README's loop is not run, and the Done-when's first bullet is checked on the real stack: a researcher whose VM was suspended on the old version runs a package, `vms/{platform_user_id}` then names a new VM with the new `image_version`, `get-microvm` on the old id reports `TERMINATING` or `TERMINATED`, and the run finishes on the new VM. The result, with both VM ids and the versions, is recorded in this spec before the story closes, as REPORT-143 does for its R1. RD-4 pass 2's 0.2.0 cannot serve: no VM on the current image (1.0, `main`'s runner) can finish `/run` on the QA stack to be suspended, so the check waits for the next release after it, which RD-4 pass 2's own fixes are expected to make (Doug, 2026-10-14). The watchdog's path rests on its unit tests: staging it needs work queued while a VM is `SUSPENDING` across a release.

  **Result (2026-10-15): pass**, at researcher-dashboard runner 0.2.1's release to the QA stack (`researcher-dashboard-runner-staging`, image active version 2.0 to 3.0, `UPDATE_COMPLETE` 10:02:36 UTC), with this story deployed to report-service-dev at `6e324e8` and the README's loop not run. The old VM was `microvm-65b5a8b7-fe95-3b5c-8238-47a321e38d52`, image version 2.0, launched for `dougresearcher` (portal user 200) on class 590 at 09:52:31 UTC and `SUSPENDED` at 09:57:57, with `runners/200` reading `suspended`. At 10:02:50 the smoke gate (`smoke.mjs stack --identity projects/20/runner-smoke --version 1.1.0`) queued a run and `/run-package` answered `"vm":"launched"`; the launcher role read the old VM (`GetMicrovm`) and the image (`GetMicrovmImage`) at 10:02:51; `vms/200` then named **`microvm-ac5d80ac-9217-3608-8bd1-3f75ba52e41b`, `image_version` 3.0**, `launched_at` 10:02:52.457, `resumed_at` null; `get-microvm` on the old id read `SUSPENDED` at 10:02:50.2 and **`TERMINATED`** ("Success.") at 10:02:55.7, after the new VM was recorded; and the run finished `done` on the new VM with "RUNNER-SMOKE-OK: 9 answers for class 590" at 10:03:22. A successful replace logs nothing (R7 logs only a failed terminate), and CloudTrail's lookup lists neither `RunMicrovm` nor `TerminateMicrovm`, so the sequence is read from `vms/200` and the two VMs' states.

## Technical Notes

- **Files**: `functions/src/researcher-dashboard/ensure-vm.ts` (`wakeSuspended`, `ensureVm`, `launch`), `watchdog.ts` (the R19 pass, `WatchdogDeps`), `index.ts` (the watchdog's image identifier and `GetMicrovmImage`), their tests, and `functions/README.md`. researcher-dashboard's `cloudformation/README.md` separately (R14).
- **Checked by building it (stage 4, throwaway, on `bfbda61`).** The change was built far enough to run: `wakeSuspended` taking the active version and answering `resumed`, `replace` or `held`; `ensureVm` claiming, launching, recording and then terminating; the watchdog terminating and logging `old_image`. With the R15 cases added, the dashboard's 363 unit tests passed and `tsc` was clean. Removing the mid-run exemption, the claim check in the wake, or counting a missing version as current each failed a test; two concurrent replaces of one VM launched once and terminated once. What it showed: the existing resume tests record no `image_version`, which R1 now reads as stale, so their fixtures gain one; `watchdog-queries.emulator.test.ts` builds its own `microvms`, which gains `currentImageVersion`.
- **Version format.** `RunMicrovm`'s and `GetMicrovm`'s `imageVersion` and `GetMicrovmImage`'s `latestActiveImageVersion` are all `string` in `@aws-sdk/client-lambda-microvms` 3.1138.0. The spike's function compared a VM's `imageVersion` with `latestActiveImageVersion` on real VMs across the 20.0 and 21.0 rebuilds, relaunching after each and reusing within a version (`spike-plan.md` todo 16), and the README's loop does the same comparison; versions look like `"1.0"`, `"22.0"`.
- **Why `vms/`'s version and not `GetMicrovm`'s.** `GetMicrovm` reports the VM's `imageVersion` too, but `MicrovmApi.get` returns only `state`, and the watchdog caches that per pass. `vms/` records the version `RunMicrovm` returned, in the same write as the id, and `wakeSuspended`'s transaction confirms `vms/` still records that id, so the two cannot differ for a VM the function launched. A VM recorded with no version (`image_version: null`, when `RunMicrovm` returned none and the image had no active version) is stale by R1, as the Jira description asks.
- **Terminating a suspended VM.** A VM terminated while `SUSPENDED` runs no `/terminate` hook (`final-design.md` 7.3; REPORT-143 Technical Notes, "What a terminated VM writes"), so nothing the old VM holds is written after the terminate. R3 guarantees it holds no `running` result.
- **The launch claim.** `LAUNCH_CLAIM_MS` (60 s) covers the mint and `RunMicrovm` after the claim, as today; `TerminateMicrovm` comes after `recordLaunch` has cleared the claim (R7.3), so it adds nothing under the claim.
- **An accepted race: the active version changing mid-wake.** The two paths decide alike only while they read the same active version. If one path resumes a VM as current, a release then activates a new version, and the other path, holding a `SUSPENDED` state it read before that resume, decides replace within the same few seconds, it terminates an awake VM, whose `/terminate` hook fails any run it had claimed with R17's reason. That takes a release activating inside one wake's seconds-long window, and loses at most one run, which the researcher can run again.
- **What RD-3 pass 2 sees on the watchdog's path.** Between the terminate and R19a's write a minute or two later, the runner document still says `suspended` with a queue, which RD-3 pass 2 (its R14) renders as "Queued packages will start within a couple of minutes." It then reads `terminated`, with Run enabled on the queued rows. No RD-3 change.

## Out of Scope

- A grant-changing runner release still has a window in which a run request launches a VM on the old image while the new one builds. Pausing new runs for the length of a stack update is a separate problem.
- A suspended old-version VM whose researcher never runs again and has no queued work stays suspended until its 8-hour life ends, or the README's loop removes it.
- Replacing a `SUSPENDING` VM: terminating one in the middle of its `/suspend` hook's flush is not something the platform's behavior is recorded for.
- Logging a replace that succeeds in `ensureVm`: it is visible as a launch, with `vms/`'s `image_version` changed.

## Open Questions

### RESOLVED: Judgment call: does a VM suspended mid-run count as one to replace?
**Context**: The Jira description's first bullet replaces any `SUSPENDED` stale VM; its Done-when says a VM mid-run on the old image is never terminated by this path. RD-3 pass 2's Resume relies on `ensureVm` resuming the VM a run was paused on.
**Options considered**:
- A) Resume a stale VM that a `running` result names; replace only the others.
- B) Replace every stale suspended VM; the interrupted run is failed by REPORT-143's R17.

**Decision**: A (R3). B makes RD-3 pass 2's Resume fail the run it promises to continue, and contradicts the Done-when.

### RESOLVED: Judgment call: terminate before the launch, or after it is recorded?
**Context**: A replace adds `TerminateMicrovm` to a request that already makes four bounded upstream calls inside a 60-second function.
**Options considered**:
- A) Claim, terminate, launch: a terminate failure fails the request and leaves the old VM to the next request.
- B) Claim, launch, record, then terminate: a terminate failure leaves an unrecorded suspended VM to its 8-hour cap.
- C) A with the function's `timeoutSeconds` raised to make room.

**Decision**: B (R7, R8). The calls before `recordLaunch` stay what a launch makes today, so the only thing a timeout can cut is the terminate, and a VM nothing records and nothing wakes costs a suspended VM's storage for at most eight hours. A risks the function being killed between `RunMicrovm` and `recordLaunch`, which leaves an unrecorded running VM.

### RESOLVED: Judgment call: what does a failed `GetMicrovmImage` decide?
**Options considered**:
- A) Nothing: 502 from `ensureVm`, a logged skip in the watchdog.
- B) Resume, as today.

**Decision**: A (R5). It matches `GetMicrovm`'s failure today, and B lets a watchdog resume race a replace during an outage.

## Self-Review

Roles: senior engineer (concurrency across the two paths), REPORT-143 contract owner (the lease and VM states), RD-3/RD-4 consumer, operator (the release loop), QA. Each finding was checked against `master` `bfbda61`.

#### RESOLVED: Every wake would read the whole queue
R3's `runningOn` check needs the queue (up to 21 reads), which a wake on the active version does not. Fixed in R3: the transaction reads it only for a stale VM.

#### RESOLVED: R14's "optional" would be wrong for production
The README covers both stacks, and report-service-pro's function is not deployed with this story. Fixed in R14: the text names the Functions version the function must be at.

#### RESOLVED: The Done-when's live outcome had no requirement (stage 8)
The plan's rollout checked it, but no requirement asked for it. Doug chose a live check that gates the close, not the merge, at the first runner release after the deploy (R16), over a release made only for the check or no live check.

#### RESOLVED: A release activating mid-wake can make the paths disagree
Found by walking the watchdog's cached `SUSPENDED` state against a concurrent `ensureVm` resume. Recorded as an accepted race in Technical Notes; a guard would need a resume timestamp both paths compare, for a seconds-long window per release.
