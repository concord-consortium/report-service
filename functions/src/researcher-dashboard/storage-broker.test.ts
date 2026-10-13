import { readFileSync, readdirSync } from "fs"
import { join } from "path"
import { makeStorageBroker } from "./storage-broker"
import { sessionPolicy } from "./storage-policy"

// The real provider needs `node:` builtins this Jest cannot resolve, so it is replaced by a stand-in
// that records what it was given and answers with the credentials a test sets.
const fromWebToken = jest.fn()
let answer: object = {}
jest.mock("@aws-sdk/credential-provider-web-identity", () => ({
  fromWebToken: (init: object) => {
    fromWebToken(init)
    return async () => answer
  }
}))

const ROLE = "arn:aws:iam::816253370536:role/researcher-dashboard-runner-staging-broker"
const AUDIENCE = "researcher-dashboard-runner-staging"
const BUCKET = "researcher-dashboard-runner-staging"
const expiration = new Date("2026-10-07T13:00:00Z")
const request = (platformUserId: string) => ({ roleArn: ROLE, audience: AUDIENCE, bucket: BUCKET, platformUserId })

describe("makeStorageBroker", () => {
  beforeEach(() => {
    fromWebToken.mockReset()
    answer = { accessKeyId: "ASIA", secretAccessKey: "s", sessionToken: "t", expiration }
  })

  it("assumes the role for an hour under the researcher's session policy, with a token for the stack's audience", async () => {
    const idToken = jest.fn(async () => "google-id-token")

    const creds = await makeStorageBroker(idToken).assume(request("136"))

    expect(creds).toEqual({ accessKeyId: "ASIA", secretAccessKey: "s", sessionToken: "t", expiration })
    expect(idToken).toHaveBeenCalledWith(AUDIENCE)
    expect(fromWebToken).toHaveBeenCalledWith({
      roleArn: ROLE, roleSessionName: "researcher-136", webIdentityToken: "google-id-token",
      policy: sessionPolicy(BUCKET, "136"), durationSeconds: 3600,
      clientConfig: { region: "us-east-1", maxAttempts: 1 }
    })
  })

  it("mints a new ID token for every session", async () => {
    const tokens = ["token-1", "token-2"]
    const broker = makeStorageBroker(async () => tokens.shift()!)

    await broker.assume(request("136"))
    await broker.assume(request("136"))

    expect(fromWebToken.mock.calls.map(([init]) => init.webIdentityToken)).toEqual(["token-1", "token-2"])
  })

  it("refuses a widening id before a token is minted", async () => {
    const idToken = jest.fn(async () => "t")
    await expect(makeStorageBroker(idToken).assume(request("*"))).rejects.toThrow(/positive integer/)
    expect(idToken).not.toHaveBeenCalled()
    expect(fromWebToken).not.toHaveBeenCalled()
  })

  it.each<[string, object]>([
    ["a session token", { accessKeyId: "ASIA", secretAccessKey: "s", expiration: new Date() }],
    ["an expiry", { accessKeyId: "ASIA", secretAccessKey: "s", sessionToken: "st" }]
  ])("refuses an answer without %s", async (_missing, partial) => {
    answer = partial
    await expect(makeStorageBroker(async () => "t").assume(request("136"))).rejects.toThrow(/no credentials/)
  })

  describe("when the ID token never arrives", () => {
    beforeEach(() => jest.useFakeTimers())
    afterEach(() => jest.useRealTimers())

    it("gives up after one upstream call's time without calling STS", async () => {
      const failure = makeStorageBroker(() => new Promise<string>(() => undefined)).assume(request("136"))

      jest.advanceTimersByTime(10 * 1000)

      await expect(failure).rejects.toThrow("no answer within 10 seconds")
      expect(fromWebToken).not.toHaveBeenCalled()
    })
  })

  // A session without its policy reaches every researcher's prefix, and nothing at run time can
  // tell, so the guard is that the broker's one call is the only one that can name BrokerRole.
  describe("as the only way to assume the broker role", () => {
    const sources = readdirSync(__dirname).filter(f => f.endsWith(".ts") && !f.endsWith(".test.ts"))
    const read = (file: string) => readFileSync(join(__dirname, file), "utf8")

    it("is the only module besides the launcher's credentials that exchanges a web token", () => {
      expect(sources.filter(f => /fromWebToken\(/.test(read(f))).sort()).toEqual(["aws-credentials.ts", "storage-broker.ts"])
    })

    it("always passes the session policy", () => {
      const call = read("storage-broker.ts").match(/fromWebToken\(\{[^]*?\}\)\(\)/)
      expect(call?.[0]).toMatch(/\bpolicy,/)
    })

    it("is handed the broker role, which nothing else is", () => {
      const users = sources.filter(f => /rdBrokerRoleArn/.test(read(f))).sort()
      expect(users).toEqual(["config.ts", "index.ts"])
      const wiring = read("index.ts")
      expect(wiring.match(/rdBrokerRoleArn/g)).toHaveLength(2)
      expect(wiring).toMatch(/brokerRoleArn: rdBrokerRoleArn\.value\(\)/)
      expect(wiring).not.toMatch(/(webIdentityCredentials|functionCredentials)\([^)]*rdBrokerRoleArn/)
    })

    it("leaves no STS client anywhere in the function", () => {
      const all = [...sources.map(read), readFileSync(join(__dirname, "..", "index.ts"), "utf8")]
      for (const source of all) {
        expect(source).not.toMatch(/client-sts|AssumeRoleCommand|AssumeRoleWithWebIdentityCommand/)
      }
    })
  })
})
