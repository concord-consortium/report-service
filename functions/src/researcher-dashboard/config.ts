import { defineInt, defineSecret, defineString } from "firebase-functions/params"

// The runner stack's launcher user. Secrets of the researcherDashboard function alone, so no
// shared-bearer route on `api` receives them.
export const rdAwsKey = defineSecret("RD_AWS_KEY")
export const rdAwsSecretKey = defineSecret("RD_AWS_SECRET_KEY")

// Empty launch settings make run-package answer 503; each .env file must still list every param,
// even empty, or a deploy prompts for it.

// A JSON array of {kid, iss, pem}, one entry per rigse signing key this project trusts.
export const portalPublicKeys = defineString("PORTAL_PUBLIC_KEYS", { default: "" })

export const rdMicrovmImageArn = defineString("RD_MICROVM_IMAGE_ARN", { default: "" })
export const rdExecutionRoleArn = defineString("RD_EXECUTION_ROLE_ARN", { default: "" })
export const rdDataBucket = defineString("RD_DATA_BUCKET", { default: "" })
export const rdReportServerUrl = defineString("RD_REPORT_SERVER_URL", { default: "" })
// Empty means the function's own first-generation URL, derived from the project at runtime.
export const rdFunctionUrl = defineString("RD_FUNCTION_URL", { default: "" })
export const rdQueueCap = defineInt("RD_QUEUE_CAP", { default: 20 })
// Comma-separated hostnames the profile deriver may fetch activity JSON from; empty makes
// derive-profile answer 503.
export const rdAuthoringHosts = defineString("RD_AUTHORING_HOSTS", { default: "" })

export const functionUrl = () =>
  rdFunctionUrl.value() || `https://us-central1-${process.env.GCLOUD_PROJECT}.cloudfunctions.net/researcherDashboard`

/** The names of the four params a launch needs (image, role, bucket, report-server URL) that are empty. */
export const unsetLaunchSettings = () =>
  [rdMicrovmImageArn, rdExecutionRoleArn, rdDataBucket, rdReportServerUrl].filter(p => !p.value()).map(p => p.name)
