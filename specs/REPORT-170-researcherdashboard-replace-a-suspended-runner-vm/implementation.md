# Implementation Plan: researcherDashboard: replace a suspended runner VM on an old image instead of resuming it

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-170
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

Two commits in report-service, then one researcher-dashboard PR after the deploy. All code is in `functions/src/researcher-dashboard/`. Both code steps were built and run as throwaway code on `master` `bfbda61` before this plan was written (requirements, Technical Notes), and the code below is that build.

Run the tests with `npx jest src/researcher-dashboard` from `functions/` under Node 22, and `npx tsc --noEmit -p .`; the emulator suite (`npm run test:emulator`) covers `watchdog-queries.emulator.test.ts`, which step 2 touches.

### The decision in `wakeSuspended`, and `ensureVm` replacing a stale VM

**Summary**: `wakeSuspended` takes the active image version and answers `resumed`, `replace` or `held` (R1 to R6). `ensureVm` asks `GetMicrovmImage` once, before its decision or its launch, and on `replace` claims, launches, records and then terminates the old VM (R7, R8). The watchdog passes `undefined` as the active version, so it decides nothing new and resumes exactly as today until the next step. The `run-package` README paragraph changes with it (R13).

**Files affected**:
- `ensure-vm.ts`: `wakeSuspended`, `ensureVm`, a new `claimAndLaunch` split out of `ensureVm`, `activeImageVersion`, `launch` taking the version, a `log` dependency, comments.
- `index.ts`: `log: functions.logger` in `researcherDashboardDeps`'s `vmDeps`.
- `watchdog.ts`: the one `wakeSuspended` call passes `undefined` and tests `=== "resumed"`.
- `ensure-vm.test.ts`: `log` in `deps`; `image_version: "7"` on the two resume fixtures; the four `wakeSuspended` tests pass `undefined` and expect `"resumed"` or `"held"`; the new cases.
- `functions/README.md`: the `run-package` paragraph.

**Estimated diff size**: ~230 lines (~70 source, ~150 tests, 2 README).

`ensure-vm.ts`, imports and dependencies:

```ts
import { readQueue, runningOn } from "./queue"

export interface EnsureVmDeps {
  // ...as today, plus
  log: { warn(message: string, data: object): void }
}
```

`UPSTREAM_TIMEOUT_MS`'s comment becomes:

```ts
// Per upstream call, each made once; the four a launch makes before it is recorded, and fetching
// the AWS credentials they use, fit the function's 60-second timeout. A replace's TerminateMicrovm
// comes after the record, so a timeout can cut only that.
```

`ensureVm` keeps its read and `GetMicrovm` unchanged; from the state check on:

```ts
/**
 * Makes sure the researcher has one VM that will take the queued work: launches one if there is
 * none, resumes a suspended one, replaces a suspended one on an older image version, and otherwise
 * leaves it. Never waits for a VM to change state.
 */
export async function ensureVm(deps: EnsureVmDeps, who: Researcher, body: RunPackageBody): Promise<VmOutcome> {
  // ...the read and GetMicrovm as today...

  if (state === "SUSPENDED") {
    const imageVersion = await activeImageVersion(deps)
    const wake = await wakeSuspended(deps, who, { microvm_id: seen!.microvm_id!, image_version: seen!.image_version }, imageVersion)
    if (wake !== "replace") {
      // a VM recorded since the read above, or a launch under way, is the one to take the work
      return wake === "resumed" ? "resumed" : "launching"
    }
    return await claimAndLaunch(deps, who, body, seen, imageVersion, seen!.microvm_id)
  }
  if (state === "SUSPENDING") return "suspending"
  if (!LAUNCH_STATES.includes(state)) return "running"
  return await claimAndLaunch(deps, who, body, seen, await activeImageVersion(deps))
}
```

`claimAndLaunch` is the rest of today's `ensureVm` body unchanged (its `vmRef`, the claim transaction, `launch`, the claim handling on failure, `recordLaunch`), with two differences: `launch(deps, who, body, imageVersion)`, and before `return "launched"`:

```ts
async function claimAndLaunch(deps: EnsureVmDeps, who: Researcher, body: RunPackageBody, seen: VmDoc | undefined,
  imageVersion: string | undefined, replacing?: string): Promise<VmOutcome> {
  // ...today's claim, launch and record...
  if (replacing) {
    // Last, so a timeout can cut only this: the old VM is suspended and no longer recorded, so
    // nothing wakes it, and it ends with its maximum life
    try {
      await deps.microvms.terminate(replacing)
    } catch (e) {
      deps.log.warn("run-package could not terminate the VM it replaced",
        { platformUserId: who.platformUserId, portal: who.portal, replaced: replacing, microvmId: launched.microvmId, error: reason(e) })
    }
  }
  return "launched"
}

/** The image's active version: the one a launch pins, and the one a suspended VM is compared against. */
async function activeImageVersion(deps: EnsureVmDeps): Promise<string | undefined> {
  try {
    return await deps.microvms.currentImageVersion(deps.config.imageIdentifier)
  } catch (e) {
    throw new VmStepError(502, `GetMicrovmImage failed: ${reason(e)}`)
  }
}
```

`launch` loses its `GetMicrovmImage` block and takes the version: `async function launch(deps, who, body, imageVersion: string | undefined)`. A launch over a gone VM therefore asks before the claim (R7), and its failure needs no claim cleared.

`wakeSuspended`:

```ts
export type Wake = "resumed" | "replace" | "held"

export type WakeDeps = Pick<EnsureVmDeps, "db" | "now" | "timestamp"> & {
  microvms: Pick<MicrovmApi, "resume">
  /** Asked just before ResumeMicrovm; the watchdog passes its budget. */
  mayCall?(): boolean
}

/**
 * Wakes a suspended VM, or says it is to be replaced. Both ensureVm and the watchdog decide here,
 * given the VM as `vms/` records it and the image's active version, so a rule about which suspended
 * VMs to wake has one place to live. A VM on another version, or none, is replaced unless a
 * `running` result names it, since it was paused partway through a run that a resume finishes; with
 * no active version there is nothing to compare. `resumed_at` is written before the resume, so no
 * watchdog pass sees the VM running with only the run's pre-suspend heartbeat, and never for a VM to
 * be replaced. Holds, writing and resuming nothing, once `vms/` records another VM, which is the one to
 * take the work, or while a launch claim is live; and holds after the write when `mayCall` says no.
 */
export async function wakeSuspended(deps: WakeDeps, who: Researcher, vm: { microvm_id: string; image_version?: string | null },
  activeVersion: string | undefined): Promise<Wake> {
  const vmRef = deps.db.doc(vmPath(who.portal, who.platformUserId))
  const stale = !!activeVersion && vm.image_version !== activeVersion
  const decided = await deps.db.runTransaction(async (tx): Promise<Wake> => {
    const current = (await tx.get(vmRef)).data() as VmDoc | undefined
    if (current?.microvm_id !== vm.microvm_id || (current.launching_until ?? 0) > deps.now()) {
      return "held"
    }
    if (stale && !runningOn(await readQueue(deps.db, tx, who), vm.microvm_id)) {
      return "replace"
    }
    tx.set(vmRef, { resumed_at: deps.timestamp() }, { merge: true })
    return "resumed"
  })
  if (decided !== "resumed") {
    return decided
  }
  if (deps.mayCall && !deps.mayCall()) {
    return "held"
  }
  try {
    await deps.microvms.resume(vm.microvm_id)
  } catch (e) {
    throw new VmStepError(502, `ResumeMicrovm failed: ${reason(e)}`)
  }
  return "resumed"
}
```

`watchdog.ts`, this step only:

```ts
if (await wakeSuspended({ ...deps, mayCall: inBudget }, who, { microvm_id: vm.microvmId, image_version: vm.imageVersion }, undefined) === "resumed") {
```

`functions/README.md`, the `run-package` bullet's middle sentence becomes: "...then launches, resumes or leaves that researcher's MicroVM, and answers 202 without waiting for it. A suspended VM on an older image version than the image's active one is replaced instead of resumed, by a launch and then a terminate, unless a `running` result names it, since it was paused partway through a run that a resume finishes."

**Tests** (`ensure-vm.test.ts`, a new `describe("replacing a suspended VM on an old image")` whose `beforeEach` sets `get` to `SUSPENDED`, and records call order through the `currentImageVersion`, `run` and `terminate` mocks; `terminate` also records which VM `vms/` names at the time). Each was run in the throwaway build:

- old version: order is `GetMicrovmImage`, `RunMicrovm`, `TerminateMicrovm` with `vms/` already naming the new VM; `RunMicrovm` pinned to `"7"`; no `resume`; `vms/` is `{microvm_id: "vm-new", image_version: "7", launching_until: null, resumed_at: null}`.
- no recorded version, and `image_version: null`: each replaced.
- no active version (`currentImageVersion` resolves undefined): resumed, no terminate.
- stale and named by a `running` result in `work/` (`microvm_id: "vm-old"`): resumed, no terminate, no `run`.
- stale with a `running` result naming another VM: replaced (so the test reads the queue's VM, not any running result).
- stale with `launching_until` in the future: `"launching"`, no terminate, `run` or `resume`; the same on the active version: no `resume` (the test that fails without the claim check in the wake).
- `GetMicrovmImage` rejects: 502 `GetMicrovmImage failed: throttled`, `vms/` unchanged.
- `TerminateMicrovm` rejects: `"launched"`, `log.warn` called with `replaced: "vm-old"` and `microvmId: "vm-new"`.
- the mint refused on a replace: 502, no terminate, `vms/` still names `vm-old` with the claim cleared.
- `RUNNING` on an old version: `"running"`, `currentImageVersion` not called.
- two concurrent `ensureVm` calls on one stale VM: one `"launched"`, one `"launching"`, one `run`, one `terminate`.

Mutations checked in the throwaway build: dropping the `runningOn` exemption fails two tests (one here, one in step 2), dropping the claim check in the wake fails one, and treating a missing version as current fails one.

---

### The watchdog terminates a stale VM it would wake

**Summary**: the watchdog's R19 pass asks `GetMicrovmImage` at most once per run, passes the version to `wakeSuspended`, and on `replace` terminates the VM and logs `watchdog.vm_terminated` with `reason: "old_image"`, writing nothing and launching nothing (R9 to R11). R19a then marks the runner document terminated on a later pass, unchanged. The watchdog README paragraph changes with it (R13).

**Files affected**:
- `watchdog.ts`: `WatchdogDeps` gains `currentImageVersion` and `imageIdentifier`; the `activeVersion` helper; the wake.
- `index.ts`: `imageIdentifier: rdMicrovmImageArn.value()` in the watchdog's deps, and its comment.
- `vm-routes.ts`: `/idle`'s comment on work queued behind a suspend gains "or terminates when it is on an older image version".
- `watchdog.test.ts`: `currentImageVersion` (resolving `"7"`) and `imageIdentifier` in `deps`; the new cases.
- `watchdog-queries.emulator.test.ts`: its own `microvms` gains `currentImageVersion: jest.fn()` and its `runWatchdog` call `imageIdentifier`.
- `functions/README.md`: the watchdog paragraph.

**Estimated diff size**: ~110 lines (~35 source, ~70 tests, 2 README).

```ts
export interface WatchdogDeps {
  db: Db
  queries: WatchdogQueries
  microvms: Pick<MicrovmApi, "get" | "suspend" | "terminate" | "resume" | "currentImageVersion">
  imageIdentifier: string
  // ...as today
}
```

Inside `runWatchdog`, beside `stateOf`:

```ts
  // The image's active version, asked once per run and only for a VM about to be woken; null once
  // asking has failed, which leaves every wake to the next run
  let active: { version?: string } | null | undefined
  const activeVersion = async (data: object) => {
    if (active === undefined) {
      try {
        active = { version: await deps.microvms.currentImageVersion(deps.imageIdentifier) }
      } catch (e) {
        act("watchdog.upstream_failed", { ...data, call: "GetMicrovmImage", error: reason(e) })
        active = null
      }
    }
    return active
  }
```

The wake, after the existing `queued === 0` check (the loop already checked the budget just before):

```ts
        try {
          const image = await activeVersion(data)
          if (!image || !inBudget()) {
            continue
          }
          const wake = await wakeSuspended({ ...deps, mayCall: inBudget }, who, { microvm_id: vm.microvmId, image_version: vm.imageVersion }, image.version)
          if (wake === "resumed") {
            act("watchdog.vm_resumed", { ...data, queued })
          } else if (wake === "replace" && inBudget()) {
            // The watchdog cannot launch, so the queued work waits for the next run request; the
            // runner document is marked terminated once the VM is gone
            try {
              await deps.microvms.terminate(vm.microvmId)
              act("watchdog.vm_terminated", { ...data, reason: "old_image" })
            } catch (e) {
              act("watchdog.upstream_failed", { ...data, call: "TerminateMicrovm", error: reason(e) })
            }
          }
        } catch (e) {
          // unchanged: a VmStepError here is ResumeMicrovm's, anything else Firestore's
```

The loop's header comment gains the case: "...suspended ones with work queued behind the suspend, which are resumed, or terminated when on an older image version, and gone ones...". `index.ts`'s comment above `researcherDashboardWatchdog` likewise: "resumes a suspended VM with work queued behind its suspend, or terminates it when it is on an older image version".

`functions/README.md`, the watchdog paragraph: "...resumes a suspended VM with work queued behind its suspend, or terminates it, launching nothing, when it is on an older image version and no `running` result names it, so the work waits for the researcher's next run request, ..."

**Tests** (`watchdog.test.ts`, in `describe("idle and suspended VMs")`, each run in the throwaway build):

- stale suspended VM (`imageVersion: "6"`, `vms/` `image_version: "6"`) with queued work: `["watchdog.vm_terminated"]`, logged with `reason: "old_image"`; every document byte-identical before and after; no `resume`. A second pass with the VM `TERMINATED`: `["watchdog.runner_terminated"]`, the runner document `terminated` with its `queue` kept.
- stale, with a `running` result naming the VM and queued work: `["watchdog.vm_resumed"]`.
- two suspended VMs on the active version with queued work: two resumes and one `currentImageVersion` call; then with it rejecting: `["watchdog.upstream_failed"]` logged with `call: "GetMicrovmImage"`, one call, no `resume`.
- out of budget before the wake (a `runTransaction` spy moves the clock 31 s after the pass's queue-read transaction, so the loop's existing budget check stops it): `[]`, no `currentImageVersion` and no `terminate`.

---

### researcher-dashboard: the release loop becomes optional

**Summary**: R14, in researcher-dashboard, after the two steps above are merged and deployed to report-service-dev (Rollout). One commit on its own branch and PR.

**Files affected**:
- `cloudformation/README.md`, "Releasing the runner" and the image-change sentence above it.

**Estimated diff size**: ~10 lines.

The paragraph before the first loop becomes:

> Review, diff and execute the change set as in "Updating a stack"; the update builds the new image. With report-service's function at Functions 1.9.0 or later (REPORT-170), nothing else is needed: the function replaces a suspended VM on an older version at its researcher's next run request, and the watchdog terminates one that has work queued behind its suspend, so the researcher's next request launches on the new version. A VM already on the new version is left alone, and so is a running one on an older version, which may be in the middle of a researcher's run: it suspends once it is idle and is replaced at the next wake. A VM suspended partway through a run is resumed so the run can finish. The loop below is optional cleanup for suspended old VMs whose researchers do not come back before the VMs' 8-hour life ends, and is required only below Functions 1.9.0. Run it with your own credentials, since the launcher cannot list VMs. Each VM's state is read again just before it is terminated, since the function may have resumed it after the listing. Unlike the function, it also terminates a VM suspended partway through a run, whose run then fails.

The section's opening paragraph on image changes says the same: "the function leaves a running VM alone whatever its image, and resumes a suspended one, except that at Functions 1.9.0 or later it replaces a suspended VM on an older version unless it was suspended partway through a run (`ensure-vm.ts`), so a VM picks up a new image only once it is terminated and the next run request launches another."

The loop itself, its state re-read (and the sentence explaining it) and the grant-changing section are unchanged. The race sentence ("That narrows the race rather than closing it: ... only the function replacing old VMs itself, instead of resuming them, removes it.") is deleted: below 1.9.0 it is still true, but the paragraph now tells such an operator to upgrade instead.

## Rollout

1. Merge the report-service PR (steps 1 and 2).
2. Deploy to report-service-dev, on Doug's go: `firebase deploy --only functions:researcherDashboard,functions:researcherDashboardWatchdog,functions:deriveProfileWorker`, since the README requires `deriveProfileWorker` beside `researcherDashboard`. No rules, index, param or IAM change; `RD_MICROVM_IMAGE_ARN` is already set in `.env.report-service-dev`. The launcher already holds `GetMicrovmImage` and `TerminateMicrovm` (RD-1). The CLI's `getIamPolicy` on `deriveProfileWorker`'s queue has 403'd on every deploy so far (`landing-tracker.md` O2, 2.6), while the hand-made `cloudtasks.enqueuer` grant stays in place; check it is still there after the deploy, as 2.6 did.
3. R16's staging check, at the first runner release to the QA stack after the deploy (after RD-4 pass 2's 0.2.0, which uses the README's loop); it gates the story's close, not the merge: before the release, run any package on a staging class so the researcher has a VM, and let it suspend after its idle period. Release the new artifact without running the loop. Run a package again: `vms/{platform_user_id}` names a new VM with the new `image_version`, `get-microvm` on the old id reports `TERMINATING` or `TERMINATED`, and the run finishes on the new VM. Record both VM ids and versions in R16 before closing.
4. The researcher-dashboard README PR (step 3).
5. Production: report-service-pro gets this with Functions 1.9.0, before RD-1 production's first runner release.

## Open Questions

### RESOLVED: Judgment call: one step or two for the code?
**Options considered**:
- A) One commit: the decision, `ensureVm` and the watchdog together.
- B) Two commits, the first passing `undefined` from the watchdog so it compiles and keeps today's behavior.

**Decision**: B. Each commit compiles and passes alone (the watchdog's existing tests pass on step 1 unchanged, since its fixture already records `imageVersion: "7"`), and the watchdog's terminate is the part a reviewer of the lease will want to read on its own.

### RESOLVED: Judgment call: who calls `GetMicrovmImage`?
**Options considered**:
- A) `wakeSuspended` calls it, through a dependency.
- B) Each caller calls it and passes the version.

**Decision**: B. Each caller already has its own failure idiom (a 502 `VmStepError`, a logged `upstream_failed` with the call's name), the watchdog memoizes per run and checks its budget around it, and `ensureVm` reuses the value for the launch it may make. The decision itself, the comparison and the mid-run test, stays in `wakeSuspended`.

### RESOLVED: Judgment call: split `claimAndLaunch` out of `ensureVm`?
**Options considered**:
- A) Keep one function, with a `replacing` variable threaded through.
- B) Split the claim, launch and record into `claimAndLaunch`, called from both branches.

**Decision**: B. Both the gone and the stale branch end in the same claim and launch, and the split moves today's code without changing it, so its diff reads as a move.

## Self-Review

Roles: commit reviewer, test writer, operator, REPORT-143 contract owner. Each finding was checked by applying the plan's code to `bfbda61` as throwaway: step 1 alone (the watchdog passing `undefined`) compiled and passed 360 dashboard tests; both steps passed 363, and 78 in `watchdog.test.ts` with the budget test added, `tslint` on the three changed sources was clean, and `npm run test:emulator` passed 34 with the emulator test's `microvms` updated.

#### RESOLVED: The plan changed `VmDoc.image_version`'s type, which the build never needed
`wakeSuspended`'s parameter takes `string | null`, and `vms/`'s typed read never reaches a comparison as null. Removed from step 1.

#### RESOLVED: The step 2 budget test did not say how it runs out of budget
Rewritten to the spy the build used: the clock moves after the pass's queue-read transaction, and the loop's existing check stops it before `GetMicrovmImage`.

#### RESOLVED: The deploy repeats a known `deriveProfileWorker` IAM 403
The rollout now says to expect it and to check the hand grant afterward, as the REPORT-143 deploy did.

Checked and dropped: REPORT-143 R16's budget rule holds (the loop checks it immediately before `GetMicrovmImage`, and `terminate` is guarded), and the concurrent-replace test depends on `FakeDb` serializing transactions, which is what the dashboard's other concurrency tests already rely on.
