import { fromWebToken } from "@aws-sdk/credential-provider-web-identity"
import { GoogleAuth } from "google-auth-library"

/** A credential provider an AWS SDK client calls whenever its credentials are missing or near expiry. */
export type AwsCredentials = ReturnType<typeof fromWebToken>

/** A runner stack role this function assumes, and the audience its trust policy expects. */
export interface WebIdentityRole {
  roleArn: string
  audience: string
}

/** Mints a Google ID token for the function's own service account. */
export type IdTokenSource = (audience: string) => Promise<string>

const auth = new GoogleAuth()

export const metadataIdToken: IdTokenSource = async audience => {
  const client = await auth.getIdTokenClient(audience)
  return client.idTokenProvider.fetchIdToken(audience)
}

/**
 * Assumes `role` with a Google ID token minted for each call. The SDK calls again shortly before
 * the returned expiration, so a long-lived client never presents an expired token.
 */
export function webIdentityCredentials(
  role: () => WebIdentityRole, roleSessionName: string, idToken: IdTokenSource = metadataIdToken
): AwsCredentials {
  return async awsIdentityProperties => {
    const { roleArn, audience } = role()
    const webIdentityToken = await idToken(audience)
    return fromWebToken({ roleArn, roleSessionName, webIdentityToken })(awsIdentityProperties)
  }
}

/**
 * The credentials the function's AWS clients use. The emulator has no service account to mint a
 * token for, so there it makes no AWS call unless `RD_EMULATOR_AWS=default-chain` hands the SDK the
 * developer's own credentials, which is `undefined` here.
 */
export function functionCredentials(
  role: () => WebIdentityRole, roleSessionName: string,
  env: NodeJS.ProcessEnv = process.env, idToken: IdTokenSource = metadataIdToken
): AwsCredentials | undefined {
  if (env.FUNCTIONS_EMULATOR !== "true") {
    return webIdentityCredentials(role, roleSessionName, idToken)
  }
  if (env.RD_EMULATOR_AWS === "default-chain") {
    return undefined
  }
  return async () => {
    throw new Error("AWS calls are off in the emulator; set RD_EMULATOR_AWS=default-chain to use your own AWS credentials")
  }
}
