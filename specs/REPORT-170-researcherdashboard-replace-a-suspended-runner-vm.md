# researcherDashboard: replace a suspended runner VM on an old image instead of resuming it

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-170

**Status**: **Closed**

## Overview

When the function would wake a researcher's suspended MicroVM that runs an older runner image, it retires that VM instead: a run request replaces it with a VM on the current image, and the watchdog terminates it and leaves the queued work for the researcher's next run request. A VM suspended partway through a run is still resumed, so the run can finish.

Each researcher gets a private machine that runs their packages, and it sleeps when idle. Before this change, a sleeping machine woke up on the runner version it was launched with, so after a release an operator had to run a cleanup command by hand, and rerun it until every old machine had gone to sleep and been removed. Now the function notices an old machine at the moment it would wake it and starts a fresh one on the current version. A machine that is running, or that was put to sleep partway through a run, is left to finish. The manual cleanup becomes optional.

## Requirements

### The decision, in `wakeSuspended`

- **R1.** A suspended VM is **stale** when the image has an active version (`GetMicrovmImage`'s `latestActiveImageVersion` is a non-empty string) and the VM's recorded `image_version` is missing, null, or not equal to it. Versions are compared as strings, as the README's release loop compares `imageVersion` with `latestActiveImageVersion`. With no active version, no VM is stale.
- **R2.** `wakeSuspended` makes the decision for both paths. Each caller asks `GetMicrovmImage` for the active version outside any transaction and passes it in, beside the VM's id and recorded `image_version`. Inside the transaction that reads `vms/{platform_user_id}`, it answers:
  - **resumed**: it writes `resumed_at`, then calls `ResumeMicrovm`;
  - **replace**: the VM is stale and R3 does not keep it; nothing is written or resumed, and the caller acts (R7, R9);
  - **recently_resumed**: a stale VM that would be replaced was resumed in the last two minutes (R4a); nothing is written or resumed;
  - **held**: `vms/` records another VM, a launch claim is live (R4), or (the watchdog only) the budget is spent after the `resumed_at` write.
- **R3.** **A VM suspended mid-run is resumed even when stale**: when a `running` result in the researcher's queue names the VM (`runningOn`), it is resumed. The queue is read only for a stale VM. RD-3 pass 2's Resume wakes a VM paused partway through a run so it finishes it (RD-4 pass 2 R20); replacing it would make REPORT-143's R17 fail the run. This applies the Jira Done-when's "a VM mid-run on the old image is never terminated by this path" to a suspended VM.
- **R4.** `wakeSuspended` resumes nothing while `vms/`'s `launching_until` is in the future, so a concurrent wake never resumes the VM a replace is retiring.
- **R4a.** A stale VM whose `resumed_at` is under two minutes old is not replaced: `wakeSuspended` answers `recently_resumed`, `ensureVm` answers `"resumed"` since the VM is awake or about to be, and the watchdog does nothing. The caller's `SUSPENDED` may predate that resume (the watchdog's can be up to a pass old), and the resumed VM may since have finished the run that kept it from being replaced and claimed more work, which a terminate would kill. Two minutes exceeds the function's 60-second timeout, which bounds how old a caller's state can be. The work waits for the next wake: the watchdog's next pass or the researcher's next request.
- **R5.** A failed or timed-out `GetMicrovmImage` decides nothing: `ensureVm` answers 502 `GetMicrovmImage failed: <reason>`, and the watchdog logs `watchdog.upstream_failed` with `call: "GetMicrovmImage"` and leaves the VM for its next pass. The work stays queued.
- **R6.** Only the resume branch writes `resumed_at`; replace writes nothing.

### `ensureVm`: replace means terminate, then launch

- **R7.** `ensureVm` asks `GetMicrovmImage` once per request, only when the recorded VM is `SUSPENDED` or gone, before taking any claim, and a launch pins that version. On replace:
  1. It takes the launch claim in the existing transaction, which claims only while no claim is live and `vms/` still records the VM it read, so two requests replacing one VM launch once and terminate once. A request without the claim answers `"launching"`.
  2. It launches (the token mint and `RunMicrovm`, with no second `GetMicrovmImage`) and calls `recordLaunch`, with today's claim and failure handling. If the launch fails, the old VM stays suspended and recorded.
  3. Only once the new VM is recorded does it call `TerminateMicrovm` on the old one. It waits at most 3 seconds for the call. A failure or that timeout is logged as a warning naming both VMs, through `ensureVm`'s new `log` dependency, and does not fail the request: the old VM is no longer recorded, nothing wakes it, and its sessions are refused by REPORT-143 R3a, and the launch's mint has already revoked its report-server token. It ends at its 8-hour life, or with the README's loop.
  4. It answers `"launched"`. `VmOutcome` gains no value; a held wake answers `"launching"`.
- **R8.** Terminating last keeps a replace's calls before `recordLaunch` the same as a launch's (`GetMicrovm`, `GetMicrovmImage`, the mint and `RunMicrovm`), inside the function's 60 seconds, so a timeout can cut only the terminate, and the 3-second wait keeps the terminate from pushing the 202 past the timeout. `timeoutSeconds` is unchanged.

### The watchdog: replace means terminate

- **R9.** When the watchdog's R19 pass would wake a suspended VM with queued work and `wakeSuspended` answers replace, it calls `TerminateMicrovm` (budget checked first), writes nothing, launches nothing, and logs `watchdog.vm_terminated` with `reason: "old_image"`. A failed terminate logs `watchdog.upstream_failed` with `call: "TerminateMicrovm"`.
- **R10.** Nothing else is new: once the VM is gone, REPORT-143's R19a marks the runner document `terminated` and keeps the queue; RD-3 pass 2 shows Run enabled on queued rows, and the next run request launches on the active version. Work no request takes is failed by R17a after eight hours and ten minutes.
- **R11.** The watchdog asks `GetMicrovmImage` at most once per pass, only when a suspended VM with queued work reaches the wake; a failure leaves every wake in that pass undone. It reads the image identifier from `RD_MICROVM_IMAGE_ARN`.

### What is left alone

- **R12.** `RUNNING`, `PENDING` and `SUSPENDING` VMs, and a VM reported with no state, are left alone whatever their image; a running VM on an old image is replaced at its next wake. No path terminates a VM with a `running` result, so REPORT-143's lease (R17) and the `/terminate` hook never meet a VM this story ended. R17, R17a, R18 and R19a are unchanged.

### Documentation

- **R13.** `functions/README.md`'s `run-package` paragraph says a suspended VM on an older image version is replaced rather than resumed unless it was suspended mid-run, and its watchdog paragraph says such a VM with queued work is terminated and the work waits for the next run request.
- **R14.** After the deploy to report-service-dev, researcher-dashboard's `cloudformation/README.md` "Releasing the runner" says the termination loop is optional cleanup for a stack whose function is at Functions 1.9.0 or later, and required below it; drops the sentence saying only the function replacing old VMs removes the race; and says the loop, unlike the function, also terminates a VM suspended mid-run. The section's opening image-change sentence says the same. The grant-changing loop is unchanged. A separate researcher-dashboard PR *(see Not Yet Implemented)*.

### Tests

- **R15.** Unit tests in `ensure-vm.test.ts` and `watchdog.test.ts` cover: resume on the active version; replace on an old version, with no recorded version, and with `image_version: null`, in the order `GetMicrovmImage`, `RunMicrovm`, `TerminateMicrovm`; resume with no active version; resume when stale but mid-run, and replace when the `running` result names another VM; `"launching"` with a live claim; `"resumed"` with no terminate for a resume under two minutes old (and a replace once it is older), and the watchdog leaving such a VM; 502 on a failed `GetMicrovmImage`; `"launched"` and a warning on a failed terminate, or one unanswered after 3 seconds; no terminate when the launch fails or the new VM cannot be recorded; a running old VM left alone with no `GetMicrovmImage`; two concurrent replaces launching and terminating once; the watchdog terminating a stale VM with no writes and logging `old_image`, then marking the runner terminated on a later pass; the watchdog resuming a stale mid-run VM, and leaving a suspended VM with nothing queued without asking `GetMicrovmImage`; one `GetMicrovmImage` per pass, its failure resuming nothing, and no call out of budget.

### The live check

- **R16.** At the first runner release to the QA stack after the deploy to report-service-dev, without the README's loop, a researcher whose VM was suspended on the old version runs a package: `vms/{platform_user_id}` names a new VM with the new `image_version`, the old VM reads `TERMINATING` or `TERMINATED`, and the run finishes on the new VM. It gated the close, not the merge.

  **Result (2026-10-15): pass**, at researcher-dashboard runner 0.2.1's release to the QA stack (`researcher-dashboard-runner-staging`, active image version 2.0 to 3.0, `UPDATE_COMPLETE` 10:02:36 UTC), with this story deployed to report-service-dev at `6e324e8` and the loop not run. The old VM, `microvm-65b5a8b7-fe95-3b5c-8238-47a321e38d52` on image version 2.0, was launched for `dougresearcher` (portal user 200) on class 590 at 09:52:31 UTC and `SUSPENDED` at 09:57:57. At 10:02:50 the smoke gate (`smoke.mjs stack --identity projects/20/runner-smoke --version 1.1.0`) queued a run and `/run-package` answered `"vm":"launched"`; `vms/200` then named **`microvm-ac5d80ac-9217-3608-8bd1-3f75ba52e41b`, `image_version` 3.0**, `launched_at` 10:02:52.457, `resumed_at` null; the old VM read `SUSPENDED` at 10:02:50.2 and **`TERMINATED`** at 10:02:55.7, after the new VM was recorded; the run finished `done` on the new VM at 10:03:22. A successful replace logs nothing and CloudTrail's lookup lists neither `RunMicrovm` nor `TerminateMicrovm`, so the sequence is read from `vms/200` and the two VMs' states. The watchdog's path rests on its unit tests.

## Technical Notes

- **Code**: `functions/src/researcher-dashboard/ensure-vm.ts` (`wakeSuspended` returning `Wake`, `ensureVm`, `claimAndLaunch` split out of it, `activeImageVersion`, `launch` taking the version), `watchdog.ts` (`WatchdogDeps` gains `currentImageVersion` and `imageIdentifier`; the per-pass `activeVersion`), `index.ts` (the logger and image identifier), and `vm-routes.ts`'s `/idle` comment.
- **Version format.** `imageVersion` and `latestActiveImageVersion` are strings in `@aws-sdk/client-lambda-microvms` 3.1138.0, for example `"1.0"` or `"22.0"`.
- **Why `vms/`'s version and not `GetMicrovm`'s.** `MicrovmApi.get` returns only `state`, and the watchdog caches that per pass. `vms/` records the version `RunMicrovm` returned in the same write as the id, and the wake's transaction confirms the id still matches, so the two cannot differ.
- **Terminating a suspended VM** runs no `/terminate` hook (REPORT-143 Technical Notes), so the old VM writes nothing afterward; R3 guarantees it holds no `running` result.
- **The launch claim.** `LAUNCH_CLAIM_MS` (60 s) covers the mint and `RunMicrovm`; the terminate comes after `recordLaunch` clears the claim.
- **An accepted race.** If a release activates a new version between one path resuming a VM and the other path deciding on a `SUSPENDED` state it read before that resume, the second terminates an awake VM and its `/terminate` hook fails any claimed run with R17's reason. It needs a release inside a seconds-long window and loses at most one run.
- **What RD-3 pass 2 sees on the watchdog's path.** Between the terminate and R19a's write a minute or two later, the runner document still reads `suspended` with a queue ("Queued packages will start within a couple of minutes"), then `terminated` with Run enabled. No RD-3 change.
- **No stack change.** The launcher role already holds `lambda:GetMicrovmImage` and `lambda:TerminateMicrovm`. The deploy is `researcherDashboard`, `researcherDashboardWatchdog` and `deriveProfileWorker`; after it, check that the hand-made `cloudtasks.enqueuer` grant on the `deriveProfileWorker` queue survived the CLI's usual `getIamPolicy` 403.

## Out of Scope

- The window in which a grant-changing runner release lets a run request launch on the old image while the new one builds.
- A suspended old-version VM whose researcher never runs again and has no queued work: it stays until its 8-hour life ends, or the README's loop removes it.
- Replacing a `SUSPENDING` VM, mid-way through its `/suspend` hook's flush.
- Logging a successful replace in `ensureVm`: it shows as a launch with `vms/`'s `image_version` changed.

## Not Yet Implemented

- **R14, the researcher-dashboard README**: committed as `f7e3ba8` on researcher-dashboard branch `REPORT-170-release-loop-optional`, its own PR, opened after the report-service deploy.
- **Production**: report-service-pro gets this with Functions 1.9.0, before RD-1 production's first runner release. Until then the README's loop stays required there.

## Decisions

### Does a VM suspended mid-run count as one to replace?
**Options considered**: A) resume a stale VM a `running` result names, replace the others; B) replace every stale suspended VM and let REPORT-143's R17 fail the run.
**Decision**: A (R3). B turns RD-3 pass 2's Resume into a kill and contradicts the Done-when.

---

### Terminate before the launch, or after it is recorded?
**Options considered**: A) claim, terminate, launch; B) claim, launch, record, then terminate; C) A with a longer `timeoutSeconds`.
**Decision**: B (R7, R8). The calls before `recordLaunch` stay a launch's, so a timeout can cut only the terminate, which costs a suspended VM's storage for at most eight hours. A risks a kill between `RunMicrovm` and `recordLaunch`, leaving an unrecorded running VM.

---

### What does a failed `GetMicrovmImage` decide?
**Options considered**: A) nothing (502, or a logged skip); B) resume, as before.
**Decision**: A (R5). It matches a failed `GetMicrovm`, and B lets a watchdog resume race a replace during an outage.

---

### Should every wake read the queue?
**Decision**: No. Only a stale VM's wake reads it (R3), since a wake on the active version doesn't need the mid-run check.

---

### Is the release loop optional everywhere?
**Decision**: No. The README names Functions 1.9.0 as the version that makes it optional (R14), since production runs an older function until then.

---

### Does a `1.9.0-pre.N` function count as "Functions 1.9.0 or later"?
**Decision**: The README keeps "Functions 1.9.0 or later" (Doug, 2026-10-15). The ambiguity for a pre-release dev or QA function is accepted, and it goes away once 1.9.0 ships.

---

### Is the live outcome checked?
**Options considered**: a release made only for the check; a live check at the first runner release after the deploy; no live check.
**Decision**: The live check at the next release, gating the close but not the merge (R16, Doug). RD-4 pass 2's 0.2.0 could not serve, since no VM on image 1.0 could finish `/run` on the QA stack.

---

### Guard the race of a release activating mid-wake?
**Decision**: No; accepted (Technical Notes). A guard needs a resume timestamp both paths compare, for a seconds-long window per release.

---

### How is a replace kept from killing a VM resumed after the caller read `SUSPENDED`? (Copilot's review of #439)
**Options considered**: A) carry the `resumed_at` the caller read before its state read and hold when it changed; B) hold a stale VM resumed in the last two minutes.
**Decision**: B (R4a). A misses a resume whose `resumed_at` write lands before the caller's read but whose `ResumeMicrovm` lands after its state read, and needs the watchdog to track which read came first for a state it caches across the pass; B covers both with one comparison, at the cost of a stale VM's replace waiting up to two minutes after a resume.

---

### Who calls `GetMicrovmImage`?
**Options considered**: A) `wakeSuspended`, through a dependency; B) each caller, passing the version in.
**Decision**: B. Each caller has its own failure idiom, the watchdog memoizes per pass and checks its budget around it, and `ensureVm` reuses the value for its launch. The comparison and mid-run test stay in `wakeSuspended`.

---

### Split `claimAndLaunch` out of `ensureVm`?
**Decision**: Yes. The gone and the stale branch end in the same claim and launch, and the split moves the existing code unchanged.

---

### One commit or two for the code?
**Decision**: Two, the first passing `undefined` from the watchdog so it compiles and keeps the old behavior, so the watchdog's terminate reads on its own.

---

### Departures from the plan, made during implementation
**Decision**: The researcher-dashboard README keeps the sentence on rereading each VM's state before terminating, and its image-change sentence at line 84 is rewritten too; `vm-routes.ts`'s `/idle` comment names the old-image terminate; the watchdog README gives the terminate its own sentence.
