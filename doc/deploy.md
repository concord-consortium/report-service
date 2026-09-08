# Deployment

S3 deployment is handled by GitHub Actions. The `s3-deploy` job in [`researcher-reports.yml`](../.github/workflows/researcher-reports.yml) deploys to `models-resources/researcher-reports/`. It runs only via `workflow_dispatch` — see below for why.

## Why this deploy is retired

The Researcher-Reports app was replaced by the Elixir/Phoenix report server, and this deploy publishes nothing that any service reads. It is kept runnable by hand, and was migrated to OIDC, so that the deploy path still exists if the app is ever revived and so that no workflow is left holding AWS access keys.

The details, since they are easy to misread:

- The last commit touching `researcher-reports/` was in October 2023. The app was replaced by the report server in May 2024.
- The `s3-deploy` job nonetheless kept running, several times a year. Every one of those runs was triggered by a **tag** push, not a branch push. GitHub Actions does not apply `paths` filters to tag pushes, so the workflow's old `paths: ['researcher-reports/**']` filter was bypassed and every release tag fired it, including tags that only released the server. Switching the workflow to `workflow_dispatch` is what stopped that.
- Each such run rebuilt the unchanged October 2023 source into a new `models-resources/researcher-reports/version/<tag>/` folder. Nothing links to those folders.
- The live `index.html` still points at `version/v1.4.2/` and has not changed since October 2023.

Switching to `workflow_dispatch` also stopped the app's tests from running automatically. The `build_test` job (build, Jest, Codecov) now runs only as a prerequisite of a hand-started deploy, so a change to `researcher-reports/` gets no CI unless someone dispatches this workflow. That is deliberate for a retired app, but worth knowing before editing it.

Two workflows, `release-production.yml` and `release-staging.yml`, used to promote a version to the top-level `index.html` and to `index-staging.html`. Neither had ever been run, and the release procedure that referenced them pointed at a repository that no longer exists, so both were deleted. They held the only record of the promotion commands, so those are preserved here. To promote a version by hand, with AWS credentials for account 612297603577:

```sh
# production
aws s3 cp \
  s3://models-resources/researcher-reports/version/<tag>/index-top.html \
  s3://models-resources/researcher-reports/index.html

# staging
aws s3 cp \
  s3://models-resources/researcher-reports/version/<tag>/index-top.html \
  s3://models-resources/researcher-reports/index-staging.html
```

None of this took the deployed app down: `index.html` and `version/v1.4.2/` are untouched in S3.

## AWS Access

The GitHub actions in this project are allowed to update files in S3 using OIDC. An IAM role has been created in AWS with a trust policy that allows GitHub actions in this specific repository to assume this IAM role. The IAM role has a `RepoName` tag and a managed policy that uses this tag to give the role's users permission to update files in `models-resources/[RepoName]`.

The trust policy accepts only OIDC tokens issued to this repository, in either of the two subject formats GitHub uses, with the audience `sts.amazonaws.com`:

```
repo:concord-consortium/report-service:*
repo:concord-consortium@319219/report-service@186850779:*
```

The second is the *immutable* form, which embeds the numeric owner and repository ids. GitHub sends the first today and would switch to the second if this repo were opted in, so both are allowed. A policy matching only one fails with `Not authorized to perform sts:AssumeRoleWithWebIdentity`, which reads like a permissions problem but is really a string mismatch.

See [deploy-setup.md in starter-projects](https://github.com/concord-consortium/starter-projects/blob/main/doc/deploy-setup.md) for how the AWS side is set up.

### Extra policy for the `researcher-reports` prefix

This repo is named `report-service` but deploys to `models-resources/researcher-reports/`, so the shared managed policy alone is not enough: its `RepoName` tag resolves to `models-resources/report-service/*`. The `report-service` role therefore carries an additional inline policy, `researcher-reports-prefix`, granting object access to the prefix the workflows actually write to:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DeployToResearcherReportsPrefix",
      "Effect": "Allow",
      "Action": [
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::models-resources/researcher-reports/*"
    }
  ]
}
```

The `s3:ListBucket` permission the deploy also needs comes from the shared managed policy, which grants it on the whole `models-resources` bucket.

Re-running `create-deploy-role.sh report-service` — the script lives in [`starter-projects/scripts/`](https://github.com/concord-consortium/starter-projects/blob/main/scripts/create-deploy-role.sh), not in this repo — is safe: it updates the trust policy and re-attaches the managed policy, and leaves this inline policy alone.
