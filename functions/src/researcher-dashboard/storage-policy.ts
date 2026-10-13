// Interpolated into an S3 ARN and a StringLike pattern, so nothing but a positive decimal
// integer: `*`, `?` or an empty id would widen a session to every researcher.
export const PLATFORM_USER_ID = /^[1-9][0-9]*$/

// An S3 bucket name: no `*` or `?`, which would be wildcards in the policy's ARNs.
const BUCKET = /^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/

export class BrokerRefusal extends Error {}

/**
 * The session policy every broker session carries: one researcher's prefix read-write, published
 * packages read-only, nothing listed under packages/. The role's own policies are only a ceiling, so a
 * session without this reaches every researcher.
 */
export function sessionPolicy(bucket: string, platformUserId: string): string {
  if (!PLATFORM_USER_ID.test(platformUserId)) {
    throw new BrokerRefusal(`platform_user_id ${JSON.stringify(platformUserId)} is not a positive integer`)
  }
  if (!BUCKET.test(bucket)) {
    throw new BrokerRefusal(`bucket ${JSON.stringify(bucket)} is not an S3 bucket name`)
  }
  return JSON.stringify({
    Version: "2012-10-17",
    Statement: [
      { Effect: "Allow", Action: "s3:ListBucket", Resource: `arn:aws:s3:::${bucket}`, Condition: { StringLike: { "s3:prefix": `researchers/${platformUserId}/*` } } },
      { Effect: "Allow", Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource: `arn:aws:s3:::${bucket}/researchers/${platformUserId}/*` },
      { Effect: "Allow", Action: "s3:GetObject", Resource: `arn:aws:s3:::${bucket}/packages/*` }
    ]
  })
}
