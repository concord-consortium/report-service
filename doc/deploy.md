# Deployment

S3 deployment is handled by GitHub Actions. The `s3-deploy` job in [`researcher-reports.yml`](../.github/workflows/researcher-reports.yml) deploys to `models-resources/researcher-reports/`. It runs only via `workflow_dispatch` — see below for why.

## Why this deploy is retired

The Researcher-Reports app was replaced by the Elixir/Phoenix report server, and this deploy publishes nothing that any service reads. It is kept runnable by hand, and was migrated to OIDC, so that the deploy path still exists if the app is ever revived and so that no workflow is left holding AWS access keys.

The details, since they are easy to misread:

- The last commit touching `researcher-reports/` was in October 2023. The app was replaced by the report server in May 2024.
- The `s3-deploy` job nonetheless kept running, several times a year. Every one of those runs was triggered by a **tag** push, not a branch push. GitHub Actions does not apply `paths` filters to tag pushes, so the workflow's old `paths: ['researcher-reports/**']` filter was bypassed and every release tag fired it, including tags that only released the server. Switching the workflow to `workflow_dispatch` is what stopped that.
- Each such run rebuilt the unchanged October 2023 source into a new `models-resources/researcher-reports/version/<tag>/` folder. Nothing links to those folders.
- The live `index.html` still points at `version/v1.4.2/` and has not changed since October 2023.

Two workflows, `release-production.yml` and `release-staging.yml`, used to promote a version to the top-level `index.html` and to `index-staging.html`. Neither had ever been run, and the release procedure that referenced them pointed at a repository that no longer exists, so both were deleted. Promoting a version by hand is a single `aws s3 cp` from `version/<tag>/index-top.html` to the destination file.

None of this took the deployed app down: `index.html` and `version/v1.4.2/` are untouched in S3.

## AWS Access

The GitHub actions in this project are allowed to update files in S3 using OIDC. An IAM role has been created in AWS with a trust policy that allows GitHub actions in this specific repository to assume this IAM role. The IAM role has a `RepoName` tag and a managed policy that uses this tag to give the role's users permission to update files in `models-resources/[RepoName]`.

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

Re-running `create-deploy-role.sh report-service` is safe: it updates the trust policy and re-attaches the managed policy, and leaves this inline policy alone.
