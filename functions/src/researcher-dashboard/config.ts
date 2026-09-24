import { defineInt, defineSecret, defineString } from "firebase-functions/params"

// The runner stack's launcher user. Secrets of the researcherDashboard function alone, so no
// shared-bearer route on `api` receives them.
export const rdAwsKey = defineSecret("RD_AWS_KEY")
export const rdAwsSecretKey = defineSecret("RD_AWS_SECRET_KEY")

// A JSON array of {kid, iss, pem}, one entry per rigse signing key this project trusts.
export const portalPublicKeys = defineString("PORTAL_PUBLIC_KEYS")

export const rdMicrovmImageArn = defineString("RD_MICROVM_IMAGE_ARN")
export const rdExecutionRoleArn = defineString("RD_EXECUTION_ROLE_ARN")
export const rdDataBucket = defineString("RD_DATA_BUCKET")
export const rdReportServerUrl = defineString("RD_REPORT_SERVER_URL")
// Empty means the function's own first-generation URL, derived from the project at runtime.
export const rdFunctionUrl = defineString("RD_FUNCTION_URL", { default: "" })
export const rdQueueCap = defineInt("RD_QUEUE_CAP", { default: 20 })

export const functionUrl = () =>
  rdFunctionUrl.value() || `https://us-central1-${process.env.GCLOUD_PROJECT}.cloudfunctions.net/researcherDashboard`
