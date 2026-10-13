import { fromWebToken } from "@aws-sdk/credential-provider-web-identity"
import type { IdTokenSource } from "./aws-credentials"
import { UPSTREAM_TIMEOUT_MS, within } from "./ensure-vm"
import { REGION } from "./region"
import { sessionPolicy } from "./storage-policy"

// The broker role's MaxSessionDuration
const SESSION_SECONDS = 3600

export interface StorageCredentials {
  accessKeyId: string
  secretAccessKey: string
  sessionToken: string
  expiration: Date
}

export interface StorageBroker {
  /** One researcher's session. The policy is built here, so no caller can leave it out. */
  assume(input: { roleArn: string; audience: string; bucket: string; platformUserId: string }): Promise<StorageCredentials>
}

/**
 * The broker, assuming the runner stack's BrokerRole directly with the function's own Google ID
 * token. This is the only call that assumes BrokerRole, and it always carries the session policy.
 */
export function makeStorageBroker(idToken: IdTokenSource): StorageBroker {
  return {
    async assume({ roleArn, audience, bucket, platformUserId }) {
      const policy = sessionPolicy(bucket, platformUserId)
      const assume = async () => fromWebToken({
        roleArn,
        roleSessionName: `researcher-${platformUserId}`,
        webIdentityToken: await idToken(audience),
        policy,
        durationSeconds: SESSION_SECONDS,
        clientConfig: { region: REGION, maxAttempts: 1 }
      })()
      const c = await within(assume(), UPSTREAM_TIMEOUT_MS)
      if (!c.accessKeyId || !c.secretAccessKey || !c.sessionToken || !c.expiration) {
        throw new Error("AssumeRoleWithWebIdentity returned no credentials")
      }
      return { accessKeyId: c.accessKeyId, secretAccessKey: c.secretAccessKey, sessionToken: c.sessionToken, expiration: c.expiration }
    }
  }
}
