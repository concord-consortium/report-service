# Implementation Plan: Partitioner Task Size Parameter

**Jira**: https://concord-consortium.atlassian.net/browse/REPORT-184
**Requirements Spec**: [requirements.md](requirements.md)
**Status**: **In Development**

## Implementation Plan

### Add the TaskSize parameter to the partitioner template

**Summary**: Replace the job definition's literal vCPU and memory with values looked up from one `TaskSize` parameter, and document the parameter in the deploy runbook. One commit: the README note describes the template change and is wrong without it.

**Files affected**:
- `partitioner/template.yml`: new `TaskSize` parameter, new `Mappings` section, two `ResourceRequirements` values.
- `partitioner/README.md`: a `TaskSize` note in the stack update instructions.

**Estimated diff size**: ~125 lines (about 110 of them the generated value list and mapping)

Template diff. This exact change was generated as a throwaway copy, passes `cfn-lint` 0.86.4 with no findings and the pair check below, and `aws cloudformation validate-template` reports `TaskSize` with default `0.25vCPU-2GB`:

```diff
@@ -27,6 +27,123 @@
     Description: "Time of day (UTC, cron format: mm HH * * ? *) to trigger the batch job (e.g., '0 2 * * ? *' for 2:00 AM UTC)"
     Default: '0 2 * * ? *'
 
+  TaskSize:
+    Type: String
+    Description: Fargate vCPU and memory for the partitioner job
+    AllowedValues:
+      - 0.25vCPU-512MB
+      - 0.25vCPU-1GB
+      - 0.25vCPU-2GB
+      - 0.5vCPU-1GB
+      - 0.5vCPU-2GB
+      - 0.5vCPU-3GB
+      - 0.5vCPU-4GB
+      - 1vCPU-2GB
+      - 1vCPU-3GB
+      - 1vCPU-4GB
+      - 1vCPU-5GB
+      - 1vCPU-6GB
+      - 1vCPU-7GB
+      - 1vCPU-8GB
+      - 2vCPU-4GB
+      - 2vCPU-5GB
+      - 2vCPU-6GB
+      - 2vCPU-7GB
+      - 2vCPU-8GB
+      - 2vCPU-9GB
+      - 2vCPU-10GB
+      - 2vCPU-11GB
+      - 2vCPU-12GB
+      - 2vCPU-13GB
+      - 2vCPU-14GB
+      - 2vCPU-15GB
+      - 2vCPU-16GB
+    Default: 0.25vCPU-2GB
+
+Mappings:
+  TaskSizes:
+    0.25vCPU-512MB:
+      Vcpu: "0.25"
+      Memory: "512"
+    0.25vCPU-1GB:
+      Vcpu: "0.25"
+      Memory: "1024"
+    0.25vCPU-2GB:
+      Vcpu: "0.25"
+      Memory: "2048"
+    0.5vCPU-1GB:
+      Vcpu: "0.5"
+      Memory: "1024"
+    0.5vCPU-2GB:
+      Vcpu: "0.5"
+      Memory: "2048"
+    0.5vCPU-3GB:
+      Vcpu: "0.5"
+      Memory: "3072"
+    0.5vCPU-4GB:
+      Vcpu: "0.5"
+      Memory: "4096"
+    1vCPU-2GB:
+      Vcpu: "1"
+      Memory: "2048"
+    1vCPU-3GB:
+      Vcpu: "1"
+      Memory: "3072"
+    1vCPU-4GB:
+      Vcpu: "1"
+      Memory: "4096"
+    1vCPU-5GB:
+      Vcpu: "1"
+      Memory: "5120"
+    1vCPU-6GB:
+      Vcpu: "1"
+      Memory: "6144"
+    1vCPU-7GB:
+      Vcpu: "1"
+      Memory: "7168"
+    1vCPU-8GB:
+      Vcpu: "1"
+      Memory: "8192"
+    2vCPU-4GB:
+      Vcpu: "2"
+      Memory: "4096"
+    2vCPU-5GB:
+      Vcpu: "2"
+      Memory: "5120"
+    2vCPU-6GB:
+      Vcpu: "2"
+      Memory: "6144"
+    2vCPU-7GB:
+      Vcpu: "2"
+      Memory: "7168"
+    2vCPU-8GB:
+      Vcpu: "2"
+      Memory: "8192"
+    2vCPU-9GB:
+      Vcpu: "2"
+      Memory: "9216"
+    2vCPU-10GB:
+      Vcpu: "2"
+      Memory: "10240"
+    2vCPU-11GB:
+      Vcpu: "2"
+      Memory: "11264"
+    2vCPU-12GB:
+      Vcpu: "2"
+      Memory: "12288"
+    2vCPU-13GB:
+      Vcpu: "2"
+      Memory: "13312"
+    2vCPU-14GB:
+      Vcpu: "2"
+      Memory: "14336"
+    2vCPU-15GB:
+      Vcpu: "2"
+      Memory: "15360"
+    2vCPU-16GB:
+      Vcpu: "2"
+      Memory: "16384"
+
 Resources:
 
   BatchExecutionRole:
@@ -127,9 +244,9 @@
         JobRoleArn: !GetAtt BatchJobRole.Arn
         ResourceRequirements:
           - Type: VCPU
-            Value: "0.25"
+            Value: !FindInMap [TaskSizes, !Ref TaskSize, Vcpu]
           - Type: MEMORY
-            Value: "512"
+            Value: !FindInMap [TaskSizes, !Ref TaskSize, Memory]
         EphemeralStorage:
           SizeInGiB: 30
         LogConfiguration:
```

Notes on the shape:

- `Mappings` sits between `Parameters` and `Resources`, the conventional order. Mapping keys containing `.` and `-` are allowed (AWS's own samples key mappings by instance type, such as `t2.micro`), and `cfn-lint` passes them.
- Values stay quoted strings, as `ResourceRequirements.Value` is a string and the current literals are quoted.
- The mapping keys repeat the `AllowedValues` list. CloudFormation offers no way to derive one from the other, and `cfn-lint` does not check that they agree (verified, see requirements Technical Notes), so the pair check below does. An unmapped selection would also fail the stack update before any resource changes.

README: in `partitioner/README.md`, add a `### Stack parameters` section after the `docker push` step, before `### QA`:

```markdown
### Stack parameters

`TaskSize` sets the job's Fargate vCPU and memory as one choice, so only valid pairs can be picked. It offers every valid pair up to 2 vCPU, the compute environment's `MaxvCpus`, named like `0.25vCPU-512MB` or `1vCPU-8GB`. The default, `0.25vCPU-2GB`, is what production uses; QA uses `0.25vCPU-512MB`, which its log volume fits. Raise production only if jobs fail with `OutOfMemoryError`. A stack created before this parameter existed gets the default on its next update unless `TaskSize` is set.
```

Verification before committing:

```bash
cfn-lint partitioner/template.yml
aws cloudformation validate-template --template-body file://partitioner/template.yml
python3 check_task_sizes.py partitioner/template.yml
```

All three must succeed with no errors. `check_task_sizes.py` is this throwaway script, written to the scratchpad, not the repo, and deleted after it prints `ok 27`. It uses the `cfnlint` package that ships with `cfn-lint`, so it needs the same Python environment (not `python3 -I`, which hides a `--user` install):

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

---

### Deploy to QA and production

**Summary**: Roll the template out by stack update: QA twice (first at the default, rehearsing production's update, then down to 512 MB), then production at the default. No commit; this step runs after the PR merges.

**Files affected**: none.

**Estimated diff size**: 0 lines

Run outside the 02:00 UTC window and not while a backfill job is running on the queue (`aws batch list-jobs --job-queue report-service-partitioner-queue --job-status RUNNING`), so no job is mid-run while its definition revision is retired. A running job keeps its resources either way; this only keeps the timeline readable.

Every update goes through a change set. The template names its IAM roles, so `CAPABILITY_NAMED_IAM` is required. `ContainerImageUri` keeps its current value (`:latest` in both stacks; pinning is a later REPORT-184 spec). QA runs under the AdminConcordQA account (`--profile concord-qa`); production under the normal account. `<task size>` is a `ParameterKey=TaskSize,...` entry, given per update below:

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

Each change set must list exactly one change: `Modify BatchJobDefinition`, `Replacement` `False`, as a preview against the QA stack showed. `PartitionerEventRule` is not listed, yet its target follows the new revision ARN, which the checks below confirm. Anything else, in particular a named IAM role, means the template differs from what is deployed: delete the change set and find out why before going further. Then apply it:

```bash
aws cloudformation execute-change-set --stack-name <stack> --change-set-name <name>
aws cloudformation wait stack-update-complete --stack-name <stack>
```

After each update, check the active revision and the schedule's target:

```bash
aws batch describe-job-definitions --job-definition-name report-service-partitioner-job --status ACTIVE \
  --query 'jobDefinitions[].[revision,containerProperties.resourceRequirements]'
aws events list-targets-by-rule --rule report-service-partitioner-schedule \
  --query 'Targets[].BatchParameters.JobDefinition'
```

There must be one active revision, and the rule's target ARN must end in it.

The three updates, in order:

| Stack | Change set name | `<task size>` | Expected revision | Expected VCPU / MEMORY |
|---|---|---|---|---|
| `report-service-partitioner-qa` | `task-size-default` | omitted (takes the default) | 6 | `0.25` / `2048` |
| `report-service-partitioner-qa` | `task-size-512` | `ParameterKey=TaskSize,ParameterValue=0.25vCPU-512MB` | 7 | `0.25` / `512` |
| `report-service-partitioner` | `task-size-default` | omitted (takes the default) | 3 | `0.25` / `2048` |

The second QA update must also show `Modify BatchJobDefinition`: the stack now holds the new template, so a different `TaskSize` is a real change. Applied to the old template, a 512 MB `TaskSize` produces no change at all, and the change set fails with "The submitted information didn't contain changes"; that is why QA goes through 2 GB first.

The morning after the production update, confirm the 02:00 run:

```bash
aws batch list-jobs --job-queue report-service-partitioner-queue \
  --filters name=AFTER_CREATED_AT,values=<update time, epoch ms> \
  --query 'jobSummaryList[].[jobName,status,jobId,createdAt]'
```

(`list-jobs` rejects `--job-status` alongside `--filters`, and with a filter it returns every status, hence `status` in the query.) The `report-service-partitioner-job` row must be `SUCCEEDED`. Then run the oob `find-gaps.sh` for the current month: it must report no missing day other than the current one.

Rollback: there is no need to restore the old template, since any size is now one parameter change away. If 2 GB itself causes a problem in production, update the stack with `TaskSize` set to the size wanted; `0.25vCPU-512MB` reproduces the old job definition exactly, and is also the known-failing size.

## Open Questions

### RESOLVED: Judgment call: one commit or two
**Context**: The template change and the README note could be separate commits.
**Options considered**:
- A) One commit for both files.
- B) Template commit, then README commit.

**Decision**: A. The README note documents behavior that only exists with the template change, and together they are about 125 lines, most of it the generated list.

### RESOLVED: Judgment call: CLI or console for the deploy
**Context**: `partitioner/README.md` describes the update as a console action ("update the stack ... as the ContainerImageUri parameter").
**Options considered**:
- A) Give only the console steps, matching the README.
- B) Give the CLI command, naming the console as equivalent.

**Decision**: B. The CLI command spells out exactly which parameters keep their values and what `TaskSize` each update sets, which is the part that matters; it is also what the post-deploy checks already use. The console's "Update stack, replace current template" is equivalent: its review page shows the same change set before it is applied.

## Self-Review

### Operator

#### RESOLVED: Production update applied without a preview
The deploy step ran `update-stack` directly. The template names its IAM roles, so any change CloudFormation decides needs a replacement on a named resource fails mid-update, and the plan's claim that only the job definition and rule change was reasoned to, not seen. Switched the step to create a change set, check that it lists only those two resources, then execute it.

#### RESOLVED: Rollback pointed at master
The rollback said to redeploy "the previous template from master", but after the merge master holds the new template. With a 512 MB option in the parameter, rollback no longer needs the old template at all: it is a `TaskSize` change.
