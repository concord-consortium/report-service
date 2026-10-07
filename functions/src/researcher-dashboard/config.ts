import { defineInt, defineString } from "firebase-functions/params"

// The service account researcherDashboard runs as, in each project, and the only identity the
// runner stack's roles trust. scripts/setup-researcher-dashboard-iam.sh creates it.
export const SERVICE_ACCOUNT_ID = "researcher-dashboard"

// Empty launch settings make run-package answer 503; each .env file must still list every param,
// even empty, or a deploy prompts for it.

// A JSON array of {kid, iss, pem}, one entry per rigse signing key this project trusts.
export const portalPublicKeys = defineString("PORTAL_PUBLIC_KEYS", { default: "" })

export const rdMicrovmImageArn = defineString("RD_MICROVM_IMAGE_ARN", { default: "" })
export const rdExecutionRoleArn = defineString("RD_EXECUTION_ROLE_ARN", { default: "" })
export const rdDataBucket = defineString("RD_DATA_BUCKET", { default: "" })
export const rdReportServerUrl = defineString("RD_REPORT_SERVER_URL", { default: "" })
// The runner stack's launcher role, and the audience its trust policy requires of our ID token.
export const rdLauncherRoleArn = defineString("RD_LAUNCHER_ROLE_ARN", { default: "" })
export const rdAwsAudience = defineString("RD_AWS_AUDIENCE", { default: "" })
// Empty means the function's own first-generation URL, derived from the project at runtime.
export const rdFunctionUrl = defineString("RD_FUNCTION_URL", { default: "" })
export const rdQueueCap = defineInt("RD_QUEUE_CAP", { default: 20 })
// Comma-separated hostnames the profile deriver may fetch activity JSON from; empty makes
// derive-profile answer 503.
export const rdAuthoringHosts = defineString("RD_AUTHORING_HOSTS", { default: "" })

export const functionUrl = () =>
  rdFunctionUrl.value() || `https://us-central1-${process.env.GCLOUD_PROJECT}.cloudfunctions.net/researcherDashboard`

/** The names of the params a launch needs that are empty. */
export const unsetLaunchSettings = () =>
  [rdMicrovmImageArn, rdExecutionRoleArn, rdDataBucket, rdReportServerUrl, rdLauncherRoleArn, rdAwsAudience]
    .filter(p => !p.value()).map(p => p.name)
