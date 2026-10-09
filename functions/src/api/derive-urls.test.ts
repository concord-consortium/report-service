import { makeDeriveUrls } from "./derive-urls"

function mockRes() {
  const res: any = {}
  res.error = jest.fn((status: number, message: any) => {
    res._status = status
    res._message = message
    return res
  })
  res.success = jest.fn((payload: any) => {
    res._payload = payload
    return res
  })
  return res
}

// jest's environment has no TextEncoder, so the body is a reader over a Buffer
function body(text: string) {
  const chunks = [Buffer.from(text)]
  return {
    getReader: () => ({
      read: async () => (chunks.length ? { done: false, value: chunks.shift() } : { done: true }),
      cancel: async () => undefined
    })
  }
}

const activity = { pages: [{ embeddables: [{ type: "MwInteractive", url: "https://lab/x" }] }] }

async function answer(allowedHosts: string[], requestBody: any) {
  const res = mockRes()
  await makeDeriveUrls(() => ({ fetchImpl: jest.fn(), allowedHosts: new Set(allowedHosts) }))({ body: requestBody } as any, res)
  return [res._status, res._message]
}

describe("derive_urls", () => {
  it("derives through the allowlist only", async () => {
    const fetchImpl = jest.fn(async () => ({ status: 200, body: body(JSON.stringify(activity)) }))
    const res = mockRes()
    const assignment_urls = [
      "https://ap/?activity=https://authoring.concord.org/a.json",
      "https://ap/?activity=https://evil.org/a.json"
    ]
    await makeDeriveUrls(() => ({ fetchImpl, allowedHosts: new Set(["authoring.concord.org"]) }))({ body: { assignment_urls } } as any, res)

    expect(res._payload).toEqual({
      interactive_urls: ["https://lab/x"],
      unread: [{ url: "https://evil.org/a.json", reason: "host not allowed" }],
      truncated: false
    })
    expect(fetchImpl).toHaveBeenCalledTimes(1)
  })

  it("is 503 without an allowlist", async () => {
    expect((await answer([], { assignment_urls: [] }))[0]).toBe(503)
  })

  it("is 400 outside /derive-profile's bounds, naming the bound", async () => {
    expect(await answer(["h"], [])).toEqual([400, "the body must be a JSON object"])
    expect(await answer(["h"], { assignment_urls: Array(501).fill("x") })).toEqual([400, "assignment_urls must be an array of at most 500 strings"])
    expect(await answer(["h"], { assignment_urls: ["x".repeat(2049)] })).toEqual([400, "each assignment URL must be a string of at most 2048 characters"])
    expect(await answer(["h"], { assignment_urls: Array(200).fill("x".repeat(2000)) })).toEqual([400, "the body exceeds 256 KiB"])
  })

  it("is 502 when the derivation itself fails", async () => {
    const res = mockRes()
    const now = () => {
      throw new Error("clock failed")
    }
    await makeDeriveUrls(() => ({ fetchImpl: jest.fn(), allowedHosts: new Set(["h"]), now }))({ body: { assignment_urls: [] } } as any, res)
    expect([res._status, res._message]).toEqual([502, "the derivation failed: clock failed"])
  })
})
