import { functionCredentials, webIdentityCredentials } from "./aws-credentials"

// The real provider needs `node:` builtins this Jest cannot resolve, so it is replaced by a stand-in
// that answers with the token it was given.
const fromWebToken = jest.fn()
jest.mock("@aws-sdk/credential-provider-web-identity", () => ({
  fromWebToken: (init: { webIdentityToken: string }) => {
    fromWebToken(init)
    return async (props?: object) => ({ accessKeyId: `ASIA-${init.webIdentityToken}`, props })
  }
}))

const role = { roleArn: "arn:aws:iam::1:role/launcher", audience: "researcher-dashboard-runner-staging" }

describe("webIdentityCredentials", () => {
  beforeEach(() => fromWebToken.mockReset())

  it("mints a new ID token for every call, so a refresh never presents an expired one", async () => {
    const tokens = ["token-1", "token-2"]
    const idToken = jest.fn(async () => tokens.shift()!)
    const credentials = webIdentityCredentials(() => role, "session", idToken)

    expect((await credentials()).accessKeyId).toBe("ASIA-token-1")
    expect((await credentials()).accessKeyId).toBe("ASIA-token-2")
    expect(idToken).toHaveBeenCalledTimes(2)
    expect(idToken).toHaveBeenCalledWith(role.audience)
  })

  it("assumes the role named at call time with the session name", async () => {
    let roleArn = "arn:aws:iam::1:role/old"
    const credentials = webIdentityCredentials(() => ({ ...role, roleArn }), "session", async () => "t")

    roleArn = "arn:aws:iam::1:role/new"
    await credentials()

    expect(fromWebToken).toHaveBeenCalledWith({ roleArn: "arn:aws:iam::1:role/new", roleSessionName: "session", webIdentityToken: "t" })
  })

  it("passes the calling client's identity properties through, so STS uses the client's region", async () => {
    const props = { callerClientConfig: { region: "us-east-1" } }

    const result = await webIdentityCredentials(() => role, "session", async () => "t")(props as never)

    expect(result).toMatchObject({ props })
  })

  it("recovers on the next call after a token fetch fails", async () => {
    const idToken = jest.fn()
      .mockRejectedValueOnce(new Error("metadata server unavailable"))
      .mockResolvedValueOnce("token-2")
    const credentials = webIdentityCredentials(() => role, "session", idToken)

    await expect(credentials()).rejects.toThrow("metadata server unavailable")
    expect((await credentials()).accessKeyId).toBe("ASIA-token-2")
  })
})

describe("functionCredentials", () => {
  beforeEach(() => fromWebToken.mockReset())

  it("assumes the role with the service account's ID token when deployed", async () => {
    const credentials = functionCredentials(() => role, "session", {}, async () => "deployed-token")

    expect((await credentials!()).accessKeyId).toBe("ASIA-deployed-token")
  })

  it("makes no AWS call from the emulator by default", async () => {
    const idToken = jest.fn()
    const credentials = functionCredentials(() => role, "session", { FUNCTIONS_EMULATOR: "true" }, idToken)

    await expect(credentials!()).rejects.toThrow("RD_EMULATOR_AWS=default-chain")
    expect(idToken).not.toHaveBeenCalled()
    expect(fromWebToken).not.toHaveBeenCalled()
  })

  it("leaves the SDK its default credential chain in the emulator only when asked", () => {
    expect(functionCredentials(() => role, "session", { FUNCTIONS_EMULATOR: "true", RD_EMULATOR_AWS: "default-chain" }))
      .toBeUndefined()
  })
})
