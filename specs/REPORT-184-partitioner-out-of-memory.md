# Partitioner Task Size Parameter

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-184

**Status**: **Closed**

## Overview

The nightly log partitioner job ran with 512 MB of memory, which one large run key can exhaust, and when it does the whole UTC day is dropped from the store the student-actions reports read. This spec replaces the job's hardcoded vCPU and memory with one stack parameter that offers every valid Fargate size the job's queue can run and defaults to 0.25 vCPU with 2 GB, so updating the production stack raises the job's memory, while QA, whose log volume fits in 512 MB, is set to stay at 512 MB.

This is the first of several REPORT-184 specs: the smallest change that stops the known failure. Six days lost between April and October 2026 were backfilled by hand at 0.25 vCPU / 2048 MB, and every one completed with matching row counts.

## Requirements

- `partitioner/template.yml` has a `TaskSize` parameter of type `String` whose `AllowedValues` are every valid Fargate vCPU and memory pair up to 2 vCPU, the compute environment's `MaxvCpus`: 27 values, ordered by vCPU and then memory.

  | vCPU | Memory options | Count |
  |---|---|---|
  | 0.25 | 512 MB, 1 GB, 2 GB | 3 |
  | 0.5 | 1 GB to 4 GB in 1 GB steps | 4 |
  | 1 | 2 GB to 8 GB in 1 GB steps | 7 |
  | 2 | 4 GB to 16 GB in 1 GB steps | 13 |

  Each value is named `<vCPU>vCPU-<memory>`, with memory written `512MB` for 512 MiB and `<n>GB` for n × 1024 MiB.
- Its `Default` is `0.25vCPU-2GB`, so a stack that does not set it gets 2 GB; any other size, 512 MB included, is an explicit choice.
- Its `Description` names the value for each stack: `0.25vCPU-512MB` for QA and `0.25vCPU-2GB` (the default) for production.
- A `TaskSizes` mapping maps each value to its vCPU string and its memory in MiB as a string, exactly as its name says. No pair outside the table appears.
- The job definition's `ResourceRequirements` take both values from that mapping with `!FindInMap` keyed by `!Ref TaskSize`. No literal vCPU or memory value remains in the job definition.
- The mapping keys and the `AllowedValues` list are the same set.
- Nothing else in the template changes. Sizes above 2 vCPU are left out because a job asking for more than `MaxvCpus` is accepted by the stack and then never starts.
- The template passes `cfn-lint` with no errors.
- Updating the production stack with the new template, keeping every existing parameter value and leaving `TaskSize` at its default, results in an active job definition revision with `VCPU 0.25` and `MEMORY 2048`, and the EventBridge schedule targets that revision. *(Verified at rollout, after the PR merges.)*
- The QA stack ends on the new template with `TaskSize` set to `0.25vCPU-512MB`, its active job definition at `VCPU 0.25` and `MEMORY 512`, the schedule targeting that revision, and QA's first scheduled 02:00 UTC run on that revision ends `SUCCEEDED` before the PR is opened. *(Verified at rollout.)*
- After the production update, the next scheduled 02:00 UTC run uses the new revision, ends `SUCCEEDED`, and its day has output files (the oob `find-gaps.sh` reports no missing day for it). *(Verified at rollout.)*
- `partitioner/README.md` documents the `TaskSize` parameter in its stack update instructions: what it sets, how values are named, its default, the value each stack uses, and that a stack created before this change gets the default on update unless `TaskSize` is set.

## Technical Notes

- The template change is one parameter with 27 allowed values, one 27-entry `Mappings` section, and two `Value:` lines in `BatchJobDefinition.ContainerProperties.ResourceRequirements`. Values are quoted strings, as `ResourceRequirements.Value` is a string.
- `cfn-lint` catches a `Default` outside `AllowedValues` (E2015) but not an invalid Fargate pair in the mapping or an allowed value with no mapping key, because `!Ref TaskSize` is not resolved statically. A missing key still fails safe: CloudFormation rejects the update before any resource changes.
- Both stacks (production `report-service-partitioner`, QA `report-service-partitioner-qa` in the AdminConcordQA account, reachable with `--profile concord-qa`) were deployed from the same template, with the same five parameters, before this change. Each earlier update moved the job definition to a new revision in place, and the EventBridge target (`!Ref BatchJobDefinition`, a revision ARN) followed it. A size change therefore rolls out by an ordinary stack update.
- No test harness exists for `partitioner/`, and no CI workflow lints `partitioner/template.yml`.
- Cost: 1.5 GB more memory on Fargate us-east-1 is about $0.0067 per hour of run time, roughly a dollar a year at the job's observed run times (5 to 31 minutes).

### Checking the size table

Run before changing the table, with the `cfnlint` package that ships with `cfn-lint` (not `python3 -I`, which hides a `--user` install). It prints `ok 27`, and fails on a wrong memory value or an allowed value with no mapping entry:

```python
import sys
from cfnlint.decode import decode
t, errs = decode(sys.argv[1])
assert not errs, errs
p = t['Parameters']['TaskSize']
m = t['Mappings']['TaskSizes']
gb = lambda lo, hi: {g * 1024 for g in range(lo, hi + 1)}
valid = {"0.25": {512, 1024, 2048}, "0.5": gb(1, 4), "1": gb(2, 8), "2": gb(4, 16)}
assert len(p['AllowedValues']) == len(set(p['AllowedValues'])), "duplicate AllowedValues"
assert set(p['AllowedValues']) == set(m), set(p['AllowedValues']) ^ set(m)
assert p['Default'] in m
pairs = {(v['Vcpu'], int(v['Memory'])) for v in m.values()}
assert pairs == {(c, mem) for c, mems in valid.items() for mem in mems}, pairs ^ {(c, mem) for c, mems in valid.items() for mem in mems}
for k, v in m.items():
    mem = int(v['Memory'])
    want = f"{v['Vcpu']}vCPU-" + ("512MB" if mem == 512 else f"{mem // 1024}GB")
    assert k == want, (k, want)
print("ok", len(m))
```

### Rollout

QA (the staging stack) is updated from the branch before the PR opens; production from master after the PR is approved and merged. Run outside the 02:00 UTC window and not while a backfill job is running on the queue. Every update goes through a change set (`--profile concord-qa` for QA):

```bash
aws cloudformation create-change-set \
  --stack-name <stack> \
  --change-set-name <name> \
  --template-body file://partitioner/template.yml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=S3BucketName,UsePreviousValue=true \
    ParameterKey=ContainerImageUri,UsePreviousValue=true \
    ParameterKey=SubnetIds,UsePreviousValue=true \
    ParameterKey=SecurityGroupIds,UsePreviousValue=true \
    ParameterKey=BatchJobTriggerTime,UsePreviousValue=true \
    <task size>
aws cloudformation wait change-set-create-complete --stack-name <stack> --change-set-name <name>
aws cloudformation describe-change-set --stack-name <stack> --change-set-name <name> \
  --query 'Changes[].ResourceChange.[Action,LogicalResourceId,Replacement]' --output text
```

Each change set must list exactly one change, `Modify BatchJobDefinition` with `Replacement` `False`; `PartitionerEventRule` is not listed even though its target follows the new revision. Anything else means the template differs from what is deployed. Then:

```bash
aws cloudformation execute-change-set --stack-name <stack> --change-set-name <name>
aws cloudformation wait stack-update-complete --stack-name <stack>
aws batch describe-job-definitions --job-definition-name report-service-partitioner-job --status ACTIVE \
  --query 'jobDefinitions[].[revision,containerProperties.resourceRequirements]'
aws events list-targets-by-rule --rule report-service-partitioner-schedule \
  --query 'Targets[].BatchParameters.JobDefinition'
```

There must be one active revision, and the rule's target ARN must end in it.

| Stack | Change set name | `<task size>` | Expected revision | Expected VCPU / MEMORY |
|---|---|---|---|---|
| `report-service-partitioner-qa` | `task-size-default` | omitted (takes the default) | 6 | `0.25` / `2048` |
| `report-service-partitioner-qa` | `task-size-512` | `ParameterKey=TaskSize,ParameterValue=0.25vCPU-512MB` | 7 | `0.25` / `512` |
| `report-service-partitioner` | `task-size-default` | omitted (takes the default) | 3 | `0.25` / `2048` |

QA checks out when both QA updates match their rows and QA's next 02:00 run at 512 MB ends `SUCCEEDED`; the PR opens only after that. If review changes `partitioner/template.yml`, update QA again from the merged template before production, passing its current `TaskSize` with `UsePreviousValue=true`.

The morning after the production update, confirm the 02:00 run (`list-jobs` rejects `--job-status` alongside `--filters`, and with a filter returns every status):

```bash
aws batch list-jobs --job-queue report-service-partitioner-queue \
  --filters name=AFTER_CREATED_AT,values=<update time, epoch ms> \
  --query 'jobSummaryList[].[jobName,status,jobId,createdAt]'
```

The `report-service-partitioner-job` row must be `SUCCEEDED`, and the oob `find-gaps.sh` for the current month must report no missing day other than the current one.

Rollback is a `TaskSize` change, not a template revert: `0.25vCPU-512MB` reproduces the old job definition exactly, and is also the known-failing size.

## Out of Scope

### Deferred to later REPORT-184 specs

These are REPORT-184 work, not excluded from the story; each will be specified separately.

- Streaming the merge step to parquet so a single large run key cannot exhaust any fixed memory limit.
- Pinning the container image: pushing a numbered tag and setting `ContainerImageUri` to it instead of `:latest`. This spec's stack updates keep `:latest`.
- Alerting on a failed job (an EventBridge rule on Batch job state `FAILED` for `report-service-partitioner-queue`).
- Fixing the date argument in `partitioner/src/index.js` so a command-line date is read from `args[0]` instead of being ignored.
- Raising the log group's 7-day retention.
- A scheduled gap check (the logic in the oob `find-gaps.sh`) so a missed day is found the next morning.

### Not part of REPORT-184 code work

- Backfilling missed days: the six known days were backfilled and verified on 2026-10-16 (repo oob doc `REPORT-184-partitioner-oom/README.md`). Any day missed before the production update is backfilled the same way.
- Researcher notification and cc-data dataset cleanup (operational to-dos in the oob doc).
- Retries on a failed job.

## Decisions

### Which sizes to offer
**Context**: The story first listed five sizes. Fargate allows 74 pairs in all, but the compute environment's `MaxvCpus: 2` means anything above 2 vCPU would be accepted by the stack and never start.
**Options considered**:
- A) The story's five, plus 512 MB for QA.
- B) Every valid pair up to 2 vCPU (27).
- C) All 74 Fargate pairs.

**Decision**: B (Doug). Any size the queue can run is selectable without a template edit, and none that cannot.

---

### How QA gets the new template at 512 MB
**Context**: QA stays at 512 MB, which its log volume fits. A preview change set against QA with `TaskSize=0.25vCPU-512MB` failed with "The submitted information didn't contain changes": the resolved job definition is identical to the deployed one, and a new parameter and mapping alone are not a change. The same preview at the default listed one change, `Modify BatchJobDefinition`, with no replacement.
**Options considered**:
- A) Update QA twice: first at the default, the exact update production gets, then to `0.25vCPU-512MB`.
- B) Leave QA on the old template until a later QA update carries a real change, and set `TaskSize` then.

**Decision**: A (Doug). QA ends on the new template at 512 MB, and production's update is rehearsed on QA first.

---

### When each stack is updated
**Context**: The rollout could follow the merge, or precede the PR.
**Options considered**:
- A) Both stacks after the PR merges.
- B) QA from the branch before the PR, production from master after approval and merge.

**Decision**: B (Doug). QA proves the change, including a nightly run at 512 MB, before review; production only ever gets merged code.

---

### What the README documents about TaskSize
**Context**: `partitioner/README.md` is the deploy runbook and lists the parameters an operator sets on stack update.
**Options considered**:
- A) Template only; the parameter's `Description` is enough.
- B) Add a short `TaskSize` note to the README's stack update instructions.

**Decision**: B. The README is where an operator updating the stack reads which parameters to set, and the new parameter changes what an update does even when left at its default. The parameter's `Description` also names the value for each stack.

---

### Protecting the mapping without a test harness
**Context**: `cfn-lint` cannot see an invalid Fargate pair or a missing mapping key behind `!Ref TaskSize` (verified). `partitioner/` has no test setup.
**Options considered**:
- A) Add a test harness and a test asserting the mapping keys equal `AllowedValues` and each pair is a valid Fargate pair.
- B) Rely on review of the table by eye, `cfn-lint` for what it can check, and CloudFormation rejecting an update that selects an unmapped value.
- C) A check script, run before changing the table and kept in the spec rather than in the repo.

**Decision**: C. At 27 entries a by-eye review no longer covers every pair, but the table is generated from a fixed rule and changes only if Fargate's sizes or `MaxvCpus` do. A harness and a committed script nothing runs both cost more than the risk; a missing key still fails safe at update time.

---

### Acceptance checks on the job itself
**Context**: Checking that the job definition shows the new size proves the stack update, not that the nightly job still runs.
**Options considered**:
- A) Stop at the job definition and schedule target.
- B) Also require the first scheduled run after each rollout to succeed and leave no gap.

**Decision**: B. A revision the schedule does not target, or a size the job cannot start with, would pass the definition check alone.

---

### Previewing every stack update
**Context**: The template names its IAM roles, so a change CloudFormation decides needs a replacement on a named resource fails mid-update.
**Options considered**:
- A) `update-stack` directly.
- B) Create a change set, check it lists only an in-place `Modify` of `BatchJobDefinition`, then execute it.

**Decision**: B. The expected change list was confirmed by previewing against QA rather than reasoned to.

---

### CLI or console for the deploy
**Context**: `partitioner/README.md` describes stack updates as console actions.
**Options considered**:
- A) Give only the console steps, matching the README.
- B) Give the CLI commands, naming the console as equivalent.

**Decision**: B. The CLI spells out which parameters keep their values and what `TaskSize` each update sets. The console's "Update stack, replace current template" is equivalent: its review page shows the same change set before it is applied.

---

### One commit or two for the code
**Context**: The template change and the README note could be separate commits.
**Options considered**:
- A) One commit for both files.
- B) Template commit, then README commit.

**Decision**: A. The README note documents behavior that only exists with the template change.
