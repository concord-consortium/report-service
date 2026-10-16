# Partitioner Task Size Parameter

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-184
**Repo**: https://github.com/concord-consortium/report-service
**Implementation Spec**: [implementation.md](implementation.md)
**Status**: **In Development**

## Overview

The nightly log partitioner job runs with 512 MB of memory, which one large run key can exhaust, and when it does the whole UTC day is dropped from the store the student-actions reports read. This spec replaces the job's hardcoded vCPU and memory with one stack parameter that offers every valid Fargate size the job's queue can run and defaults to 0.25 vCPU with 2 GB, so updating the production stack raises the job's memory, while QA, whose log volume fits in 512 MB, is set to stay at 512 MB.

## Project Owner Overview

Six whole days of student action logs went missing from researcher downloads between April and October 2026 because the nightly partitioner ran out of memory. Those days have been backfilled by hand, but the job still runs with the same 512 MB and can fail again on any night with an unusually large run. This change gives the job four times the memory by default, at a cost of roughly a dollar a year, and lets an operator pick any other valid size up to 2 vCPU and 16 GB when updating a stack, without editing the template. QA keeps its current 512 MB, which its much smaller log volume has never exceeded.

This is the first of several REPORT-184 specs. It is deliberately the smallest change that stops the known failure; the streaming merge that removes the memory ceiling altogether, failure alerting, image pinning and the other fixes listed under "Deferred to later REPORT-184 specs" follow separately.

## Background

The full investigation, evidence and backfill record are in the repo oob doc `REPORT-184-partitioner-oom/README.md`. In short:

- The partitioner (`partitioner/`, added in REPORT-42) runs at 02:00 UTC as AWS Batch job definition `report-service-partitioner-job` on Fargate. It takes the previous UTC day from `processed_logs_with_id/`, splits it by app and run key, and uploads `logs_by_app_and_secure_key/<app>/<yyyy>/<mm>/<key>/<DD>_<n>.parquet`. Upload is one step at the end, so a run that dies earlier writes nothing for any app.
- `partitioner/template.yml` hardcodes the job's `ResourceRequirements` as `VCPU "0.25"` and `MEMORY "512"`.
- Six nights failed with `OutOfMemoryError: container killed due to memory usage` (exit 137) while writing one large run key. All six days were rerun with a container override of 0.25 vCPU and 2048 MB, and all six completed and matched source row counts exactly. 2048 MB is therefore proven sufficient for every known failure.
- Day size does not predict failure, so memory headroom is a mitigation, not a cure. The streaming merge (deferred) is the cure.

Verified against the live production stack `report-service-partitioner` on 2026-10-16:

- Its parameters are `S3BucketName`, `ContainerImageUri` (`...report-service-partitioner:latest`), `SubnetIds`, `SecurityGroupIds` and `BatchJobTriggerTime`; it has no size parameter, and the template on master matches what is deployed.
- The active job definition is revision 2 with `VCPU 0.25` / `MEMORY 512`. The stack's one previous update (2025-09-21) changed the job definition in place: CloudFormation registered revision 2, retired revision 1, and the EventBridge target (`!Ref BatchJobDefinition`, a revision ARN) followed it to `:2`. So a size change rolls out by an ordinary stack update and the schedule picks it up with no extra step.
- The QA stack `report-service-partitioner-qa` (AdminConcordQA account, reachable with the `concord-qa` profile) was checked the same way: its deployed template matches master, it has the same five parameters (`S3BucketName` is `log-ingester-qa`, `ContainerImageUri` is `:latest`), its active job definition is revision 5 with `VCPU 0.25` / `MEMORY 512`, the schedule targets `:5`, and its two earlier updates each moved the job definition to a new revision in place. Its nightly runs all succeeded over the last week, as QA's log volume is far smaller.

## Requirements

- `partitioner/template.yml` has a `TaskSize` parameter of type `String` whose `AllowedValues` are every valid Fargate vCPU and memory pair up to 2 vCPU, the compute environment's `MaxvCpus`: 27 values, ordered by vCPU and then memory.

  | vCPU | Memory options | Count |
  |---|---|---|
  | 0.25 | 512 MB, 1 GB, 2 GB | 3 |
  | 0.5 | 1 GB to 4 GB in 1 GB steps | 4 |
  | 1 | 2 GB to 8 GB in 1 GB steps | 7 |
  | 2 | 4 GB to 16 GB in 1 GB steps | 13 |

  Each value is named `<vCPU>vCPU-<memory>`, with memory written `512MB` for 512 MiB and `<n>GB` for n × 1024 MiB: `0.25vCPU-512MB`, `0.25vCPU-1GB`, `0.25vCPU-2GB`, `0.5vCPU-1GB` … `0.5vCPU-4GB`, `1vCPU-2GB` … `1vCPU-8GB`, `2vCPU-4GB` … `2vCPU-16GB`.
- Its `Default` is `0.25vCPU-2GB`, so a stack that does not set it gets 2 GB; any other size, 512 MB included, is an explicit choice.
- Its `Description` names the value for each stack: `0.25vCPU-512MB` for QA and `0.25vCPU-2GB` (the default) for production, so the choice is visible in the console's parameter form.
- A `Mappings` entry maps each `TaskSize` value to its vCPU string (`"0.25"`, `"0.5"`, `"1"` or `"2"`) and its memory in MiB as a string (`"512"`, `"1024"` … `"16384"`), exactly as its name says. No pair outside the table above appears.
- The job definition's `ResourceRequirements` take both values from that mapping with `!FindInMap` keyed by `!Ref TaskSize`. No literal vCPU or memory value remains in the job definition.
- The mapping keys and the `AllowedValues` list are the same set, so every selectable value resolves and no mapping entry is unreachable.
- Nothing else in the template changes: the compute environment (`MaxvCpus: 2`, which every option fits), roles, log group, schedule and other parameters are untouched. Sizes above 2 vCPU are left out because a job asking for more than `MaxvCpus` is accepted by the stack and then never starts.
- The template passes `cfn-lint` with no errors.
- Updating the existing production stack with the new template, keeping every existing parameter value and leaving `TaskSize` at its default, results in an active job definition revision with `VCPU 0.25` and `MEMORY 2048`, and the EventBridge schedule targets that revision.
- The QA stack ends on the new template with `TaskSize` set to `0.25vCPU-512MB`, its active job definition at `VCPU 0.25` and `MEMORY 512`, and the schedule targeting that revision.
- After the production update, the next scheduled 02:00 UTC run uses the new revision, ends `SUCCEEDED`, and its day has output files (the oob `find-gaps.sh` reports no missing day for it).
- `partitioner/README.md` documents the `TaskSize` parameter in its stack update instructions: what it sets, how values are named, its default, the value each stack uses, and that a stack created before this change gets the default on update unless `TaskSize` is set.

## Technical Notes

- File touched: `partitioner/template.yml` (one parameter with 27 allowed values, one 27-entry `Mappings` section, two `Value:` lines in `BatchJobDefinition.ContainerProperties.ResourceRequirements`), plus `partitioner/README.md`.
- `ResourceRequirements` values are strings, so mapping values are quoted strings (`"0.25"`, `"2048"`), matching the current literals.
- `cfn-lint` (0.86.4 locally) was run against a throwaway version of the changed template. It passes the correct template and catches a `Default` outside `AllowedValues` (E2015). It does **not** catch an invalid Fargate pair in the mapping (a 1 vCPU / 16384 MiB entry passed) or an `AllowedValues` entry with no mapping key (removing a mapping entry passed), because `!Ref TaskSize` is not resolved statically. A throwaway Python check, given in implementation.md, covers both: it parses the template with cfn-lint's own loader and asserts that the `AllowedValues` and mapping keys are the same set with no duplicates, that the default is among them, that the pairs are exactly the table above, and that every key's name matches its values. It passes the 27-value template and fails on a wrong memory value and on an allowed value with no mapping entry.
- `aws cloudformation validate-template` accepts the 27-value throwaway template and reports `TaskSize` with default `0.25vCPU-2GB`.
- No test harness exists for `partitioner/` (`package.json` has only the placeholder `test` script) and no CI workflow lints `partitioner/template.yml`.
- Cost: 1.5 GB more memory on Fargate us-east-1 is about $0.0067 per hour of run time, roughly a dollar a year at the job's observed run times (5 to 31 minutes).

## Out of Scope

### Deferred to later REPORT-184 specs

These are REPORT-184 work, not excluded from the story; each will be specified separately.

- Streaming the merge step to parquet so a single large run key cannot exhaust any fixed memory limit.
- Pinning the container image: pushing a numbered tag and setting `ContainerImageUri` to it instead of `:latest`. This spec's stack update keeps `:latest`.
- Alerting on a failed job (an EventBridge rule on Batch job state `FAILED` for `report-service-partitioner-queue`).
- Fixing the date argument in `partitioner/src/index.js` so a command-line date is read from `args[0]` instead of being ignored.
- Raising the log group's 7-day retention.
- A scheduled gap check (the logic in the oob `find-gaps.sh`) so a missed day is found the next morning.

### Not part of REPORT-184 code work

- Backfilling missed days: the six known days were backfilled and verified on 2026-10-16 (oob doc). Any day missed before this spec deploys is backfilled the same way.
- Researcher notification and cc-data dataset cleanup (operational to-dos in the oob doc).
- Retries on a failed job.

## Open Questions

### RESOLVED: Judgment call: what the README documents about TaskSize
**Context**: The story names only the template change. `partitioner/README.md` is the deploy runbook and lists the parameters an operator sets on stack update.
**Options considered**:
- A) Template only; the parameter's `Description` is enough.
- B) Add a short `TaskSize` note to the README's stack update instructions.

**Decision**: B. The README is where an operator updating the stack reads which parameters to set, and the new parameter changes what an update does even when left at its default.

### RESOLVED: Judgment call: protecting the mapping without a test harness
**Context**: `cfn-lint` cannot see an invalid Fargate pair or a missing mapping key behind `!Ref TaskSize` (verified). The repo's usual answer to two lists that must agree is a test, but `partitioner/` has no test setup.
**Options considered**:
- A) Add a test harness and a test asserting the mapping keys equal `AllowedValues` and each pair is a valid Fargate pair.
- B) Rely on review of the table by eye, `cfn-lint` for what it can check, and CloudFormation rejecting an update that selects an unmapped value.
- C) A check script, run before committing and kept in implementation.md rather than in the repo.

**Decision**: C. At 27 entries a by-eye review no longer covers every pair, but the table is generated from a fixed rule and changes only if Fargate's sizes or `MaxvCpus` do. A harness and a committed script nothing runs both cost more than the risk; a missing key still fails safe at update time.

### RESOLVED: How QA gets the new template at 512 MB
**Context**: QA stays at 512 MB, which its log volume fits. A preview change set against `report-service-partitioner-qa` with `TaskSize=0.25vCPU-512MB` failed with "The submitted information didn't contain changes": the resolved job definition is identical to the deployed one, and a new parameter and mapping alone are not a change. So QA cannot move to the new template at 512 MB in one update. The same preview at the default listed one change, `Modify BatchJobDefinition`, with no replacement.
**Options considered**:
- A) Update QA twice: first at the default, the exact update production gets, then to `0.25vCPU-512MB`.
- B) Leave QA on the old template until a later QA update carries a real change, and set `TaskSize` then.

**Decision**: A (Doug, 2026-10-16). QA ends on the new template at 512 MB, and production's update is rehearsed on QA first. QA runs at 2 GB only between the two updates.

### RESOLVED: Which sizes to offer
**Context**: The story listed five sizes. Fargate allows 74 pairs in all, but the compute environment's `MaxvCpus: 2` means anything above 2 vCPU would be accepted by the stack and never start.
**Options considered**:
- A) The story's five, plus 512 MB for QA.
- B) Every valid pair up to 2 vCPU (27).
- C) All 74 Fargate pairs.

**Decision**: B (Doug, 2026-10-16). Any size the queue can run is selectable without a template edit, and none that cannot.

## Self-Review

### QA Engineer

#### RESOLVED: No acceptance check on the job itself
The requirements stopped at the job definition showing 2048 MiB, which proves the stack update but not that the nightly job still runs. A revision the schedule does not target, or a size the job cannot start with, would pass that check. Added a requirement that the first scheduled run after the production update uses the new revision, succeeds and leaves no gap.

---

### DevOps Engineer

#### RESOLVED: QA stack described as verified
Background stated the QA stack "uses the same template" on the README's word alone. It has since been inspected through the `concord-qa` profile, and Background now records what was found: same template, same parameters, same in-place revision update history.
