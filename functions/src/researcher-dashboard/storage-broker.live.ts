// The storage broker against a real stack. Not a Jest test: it calls AWS, so it runs under Node's
// own runner against the built code, and only when an operator sets it up. It is the function's
// own broker with one difference: its ID tokens are the function's account's, minted for the
// operator by the setup script's id-token, which needs OpenID Token Creator on the account
// (grant-operator, revoked afterward). No AWS credential is used.
//
//   npm run build
//   RD_LIVE_PROJECT=report-service-dev RD_LIVE_AUDIENCE=<the stack's name> RD_LIVE_ROLE_ARN=<BrokerRoleArn> \
//   RD_LIVE_BUCKET=<DataBucketName> RD_LIVE_PACKAGE_KEY=<a published packages/ key> \
//   node --test lib/researcher-dashboard/storage-broker.live.js
//
// It writes and deletes probe objects under two test researcher ids' prefixes, and nothing else.
// node:test has no unprefixed name, and its test() returns a promise the runner itself awaits.
// tslint:disable:no-implicit-dependencies no-floating-promises
import { after, before, test } from "node:test"
import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { join } from "node:path"
import { DeleteObjectCommand, GetObjectCommand, ListObjectsV2Command, PutObjectCommand, S3Client } from "@aws-sdk/client-s3"
import { makeStorageBroker } from "./storage-broker"
import { REGION } from "./region"

const project = process.env.RD_LIVE_PROJECT ?? ""
const audience = process.env.RD_LIVE_AUDIENCE ?? ""
const roleArn = process.env.RD_LIVE_ROLE_ARN ?? ""
const bucket = process.env.RD_LIVE_BUCKET ?? ""
const packageKey = process.env.RD_LIVE_PACKAGE_KEY ?? ""
const skip = [project, audience, roleArn, bucket, packageKey].some(v => !v)
  ? "set RD_LIVE_PROJECT, RD_LIVE_AUDIENCE, RD_LIVE_ROLE_ARN, RD_LIVE_BUCKET and RD_LIVE_PACKAGE_KEY to run" : false

const script = join(__dirname, "../../scripts/setup-researcher-dashboard-iam.sh")
const operatorIdToken = async (aud: string) =>
  execFileSync(script, ["id-token", project, aud], { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim()

// Two ids no portal user will have, so the probes touch no real researcher's data
const ME = "999999001"
const OTHER = "999999002"
const mine = `researchers/${ME}/storage-broker-live-check`
const theirs = `researchers/${OTHER}/storage-broker-live-check`

const session = async (platformUserId: string) => {
  const c = await makeStorageBroker(operatorIdToken).assume({ roleArn, audience, bucket, platformUserId })
  return new S3Client({ region: REGION, credentials: { accessKeyId: c.accessKeyId, secretAccessKey: c.secretAccessKey, sessionToken: c.sessionToken } })
}

const refused = async (call: Promise<unknown>) => {
  await assert.rejects(call, (e: any) => e?.name === "AccessDenied" || e?.$metadata?.httpStatusCode === 403)
}

let s3Me: S3Client
let s3Other: S3Client

before(async () => {
  if (skip) {
    return
  }
  console.log(`As researcher-dashboard@${project}, for audience ${audience}, assuming ${roleArn} on bucket ${bucket}`)
  s3Me = await session(ME)
  s3Other = await session(OTHER)
  // An object that exists under the other researcher's prefix, so each refusal below is of a real
  // object: without a list grant, S3 refuses a read of a missing key whatever the grant.
  await s3Other.send(new PutObjectCommand({ Bucket: bucket, Key: theirs, Body: "theirs" }))
})

after(async () => {
  if (skip) {
    return
  }
  await s3Other.send(new DeleteObjectCommand({ Bucket: bucket, Key: theirs }))
})

test("a session reads, writes, lists and deletes its own prefix", { skip }, async () => {
  await s3Me.send(new PutObjectCommand({ Bucket: bucket, Key: mine, Body: "mine" }))
  const listed = await s3Me.send(new ListObjectsV2Command({ Bucket: bucket, Prefix: `researchers/${ME}/` }))
  assert.ok(listed.Contents?.some(o => o.Key === mine))
  await s3Me.send(new GetObjectCommand({ Bucket: bucket, Key: mine }))
  await s3Me.send(new DeleteObjectCommand({ Bucket: bucket, Key: mine }))
})

test("a session cannot read, list, write or delete another researcher's existing object", { skip }, async () => {
  await refused(s3Me.send(new GetObjectCommand({ Bucket: bucket, Key: theirs })))
  await refused(s3Me.send(new ListObjectsV2Command({ Bucket: bucket, Prefix: `researchers/${OTHER}/` })))
  await refused(s3Me.send(new ListObjectsV2Command({ Bucket: bucket, Prefix: "researchers/" })))
  await refused(s3Me.send(new PutObjectCommand({ Bucket: bucket, Key: theirs, Body: "overwritten" })))
  await refused(s3Me.send(new DeleteObjectCommand({ Bucket: bucket, Key: theirs })))
})

test("a session reads a published archive and cannot write, delete or list under packages/", { skip }, async () => {
  await s3Me.send(new GetObjectCommand({ Bucket: bucket, Key: packageKey }))
  // A probe key rather than the archive, so a wrong grant cannot overwrite or delete a published
  // package; S3 refuses a write or delete with 403 whether or not the key exists.
  const probe = "packages/storage-broker-live-check"
  await refused(s3Me.send(new PutObjectCommand({ Bucket: bucket, Key: probe, Body: "probe" })))
  await refused(s3Me.send(new DeleteObjectCommand({ Bucket: bucket, Key: probe })))
  await refused(s3Me.send(new ListObjectsV2Command({ Bucket: bucket, Prefix: "packages/" })))
})
