import * as fs from "fs"
import * as path from "path"
import {
  allowedContentUrl, contentUrlOf, deriveProfile, FetchResponse, interactiveUrls, MAX_INTERACTIVE_URLS, ProfileDeps
} from "./derive-profile"

const fixture = (name: string) => JSON.parse(fs.readFileSync(path.join(__dirname, "fixtures", `${name}.json`), "utf8"))
const expected: Record<string, string[]> = fixture("expected-urls")

const AUTHORING = "https://authoring.concord.org"
const ap = (content: string, param = "activity") =>
  `https://activity-player.concord.org/branch/master/index.html?${param}=${encodeURIComponent(content)}`

const bytes = (text: string) => new Uint8Array(Buffer.from(text, "utf8"))

// statuses of the responses whose body was cancelled
const cancelled: number[] = []

// A response whose body arrives in chunks, as a stream reader delivers it.
function response(status: number, body = "", chunkSize = 64 * 1024): FetchResponse {
  const data = bytes(body)
  let offset = 0
  return {
    status,
    body: {
      getReader: () => ({
        read: async () => {
          if (offset >= data.byteLength) return { done: true }
          const value = data.slice(offset, offset + chunkSize)
          offset += chunkSize
          return { done: false, value }
        },
        cancel: async () => { cancelled.push(status) }
      })
    }
  }
}

type Route = FetchResponse | (() => Promise<FetchResponse>)

function fakeFetch(routes: Record<string, Route | Route[]>) {
  const requested: string[] = []
  let inFlight = 0
  let maxInFlight = 0
  const fetchImpl: ProfileDeps["fetchImpl"] = async (url, init) => {
    expect(init.redirect).toBe("manual")
    requested.push(url)
    inFlight++
    maxInFlight = Math.max(maxInFlight, inFlight)
    try {
      await new Promise(resolve => setTimeout(resolve, 1))
      const route = routes[url]
      if (!route) return response(404, "{}")
      const next = Array.isArray(route) ? route.shift()! : route
      return typeof next === "function" ? await next() : next
    } finally {
      inFlight--
    }
  }
  return { fetchImpl, requested, maxInFlight: () => maxInFlight }
}

const deps = (fetchImpl: ProfileDeps["fetchImpl"], extra: Partial<ProfileDeps> = {}): ProfileDeps =>
  ({ fetchImpl, allowedHosts: new Set(["authoring.concord.org"]), ...extra })

describe("interactiveUrls", () => {
  it("reads the live fixtures' interactives exactly, and nothing from other embeddables", () => {
    expect(Array.from(new Set(interactiveUrls(fixture("activity-100")))).sort()).toEqual(expected["activity-100"])
    const lab = Array.from(new Set(interactiveUrls(fixture("activity-1000")))).sort()
    expect(lab).toEqual(expected["activity-1000"])
    expect(lab.filter(u => u.startsWith("//")).length).toBeGreaterThan(0)
    expect(lab).toContain("https://lab.concord.org/embeddable.html#interactives/itsi/energy-levels/atom-builder.json")
  })

  it("appends a url_fragment, skips an empty MwInteractive url, and reads pages without sections", () => {
    const activity = {
      pages: [
        { embeddables: [
          { type: "ManagedInteractive", url_fragment: "#a", library_interactive: { data: { base_url: "https://x.org/i/" } } },
          { type: "ManagedInteractive", url_fragment: null, library_interactive: { data: { base_url: "https://x.org/j/" } } },
          { type: "MwInteractive", url: "" },
          { type: "MwInteractive", url: "//lab.concord.org/embeddable.html#b" },
          { type: "Embeddable::Xhtml", url: "https://not-an-interactive.org/" }
        ] }
      ]
    }
    expect(interactiveUrls(activity)).toEqual(["https://x.org/i/#a", "https://x.org/j/", "//lab.concord.org/embeddable.html#b"])
  })

  it("tolerates malformed JSON shapes", () => {
    expect(interactiveUrls(null)).toEqual([])
    expect(interactiveUrls({ pages: "x" })).toEqual([])
    expect(interactiveUrls({ pages: [null, { sections: [null, { embeddables: [null, 5] }] }] })).toEqual([])
  })
})

describe("contentUrlOf", () => {
  it("follows an encoded or unencoded activity, and a sequence", () => {
    const content = `${AUTHORING}/api/v1/activities/100.json`
    expect(contentUrlOf(ap(content))).toBe(content)
    expect(contentUrlOf(`https://activity-player.concord.org/index.html?activity=${content}`)).toBe(content)
    expect(contentUrlOf(ap(`${AUTHORING}/api/v1/sequences/100.json`, "sequence"))).toBe(`${AUTHORING}/api/v1/sequences/100.json`)
  })

  it("takes a CLUE URL, a relative value and a non-URL as they stand", () => {
    expect(contentUrlOf("https://models-resources.concord.org/collaborative-learning/version/5.6.0/index.html?unit=moth&problem=1.2")).toBeUndefined()
    expect(contentUrlOf("https://activity-player.concord.org/index.html?activity=100")).toBeUndefined()
    expect(contentUrlOf("not a url")).toBeUndefined()
    expect(contentUrlOf("")).toBeUndefined()
  })
})

describe("allowedContentUrl", () => {
  const allowed = new Set(["authoring.concord.org"])

  it("allows an exact host over https, and fetches http as https", () => {
    expect(allowedContentUrl(`${AUTHORING}/api/v1/activities/1.json`, allowed)).toBe(`${AUTHORING}/api/v1/activities/1.json`)
    expect(allowedContentUrl("http://authoring.concord.org/api/v1/activities/1.json", allowed)).toBe(`${AUTHORING}/api/v1/activities/1.json`)
  })

  it("refuses a suffix, userinfo, a port, another scheme and another host", () => {
    for (const url of [
      "https://authoring.concord.org.evil.example/a.json",
      "https://authoring.concord.org@evil.example/a.json",
      "https://user:pw@authoring.concord.org/a.json",
      "https://authoring.concord.org:8443/a.json",
      "ftp://authoring.concord.org/a.json",
      "https://evil.example/a.json"
    ]) {
      expect(allowedContentUrl(url, allowed)).toBeUndefined()
    }
  })
})

describe("deriveProfile", () => {
  const activity = (id: number) => `${AUTHORING}/api/v1/activities/${id}.json`

  it("derives the fixtures' URLs, sorted and de-duplicated, and records what it read", async () => {
    const f = fakeFetch({
      [activity(100)]: response(200, JSON.stringify(fixture("activity-100"))),
      [activity(1000)]: response(200, JSON.stringify(fixture("activity-1000")), 1000),
      [`${AUTHORING}/api/v1/sequences/100.json`]: response(200, JSON.stringify(fixture("sequence-100")))
    })
    const clue = "https://models-resources.concord.org/collaborative-learning/version/5.6.0/index.html?unit=moth&problem=1.2"
    const derived = await deriveProfile(deps(f.fetchImpl), [
      ap(activity(100)), ap(activity(100)), ap(activity(1000)), ap(`${AUTHORING}/api/v1/sequences/100.json`, "sequence"), clue
    ])

    const all = Array.from(new Set([...expected["activity-100"], ...expected["activity-1000"], ...expected["sequence-100"]])).sort()
    expect(derived.interactive_urls).toEqual(all)
    expect(derived.content_urls).toEqual([activity(100), activity(1000), `${AUTHORING}/api/v1/sequences/100.json`].sort())
    expect(derived.unread).toEqual([])
    expect(derived.truncated).toBe(false)
    expect(f.requested.sort()).toEqual([activity(100), activity(1000), `${AUTHORING}/api/v1/sequences/100.json`].sort())
  })

  it("records a refused host and never requests it", async () => {
    const f = fakeFetch({})
    const refused = ["https://authoring.concord.org.evil.example/a.json", "https://authoring.concord.org:8443/a.json"]
    const derived = await deriveProfile(deps(f.fetchImpl), refused.map(u => ap(u)))
    expect(f.requested).toEqual([])
    expect(derived.unread).toEqual(refused.sort().map(url => ({ url, reason: "host not allowed" })))
  })

  it("records a redirect, a 404, non-JSON and an oversize body, and still writes the rest", async () => {
    const f = fakeFetch({
      [activity(1)]: response(302),
      [activity(2)]: response(404, "{}"),
      [activity(3)]: response(200, "<html>"),
      [activity(4)]: response(200, "x".repeat(5 * 1024 * 1024 + 1)),
      [activity(5)]: response(200, JSON.stringify(fixture("activity-100")))
    })
    cancelled.length = 0
    const derived = await deriveProfile(deps(f.fetchImpl), [1, 2, 3, 4, 5].map(id => ap(activity(id))))
    expect(cancelled.sort()).toEqual([200, 302, 404])
    expect(derived.unread).toEqual([
      { url: activity(1), reason: "redirect not followed" },
      { url: activity(2), reason: "HTTP 404" },
      { url: activity(3), reason: "not JSON" },
      { url: activity(4), reason: "response exceeds 5 MiB" }
    ])
    expect(derived.content_urls).toEqual([activity(5)])
    expect(derived.interactive_urls).toEqual(expected["activity-100"])
  })

  it("retries a 503 or a network error once, and gives up after a second failure", async () => {
    const body = JSON.stringify(fixture("activity-100"))
    const f = fakeFetch({
      [activity(1)]: [response(503), response(200, body)],
      [activity(2)]: [() => Promise.reject(new Error("ECONNRESET")), response(200, body)],
      [activity(3)]: [response(503), response(502)]
    })
    const derived = await deriveProfile(deps(f.fetchImpl), [1, 2, 3].map(id => ap(activity(id))))
    expect(derived.content_urls).toEqual([activity(1), activity(2)])
    expect(derived.unread).toEqual([{ url: activity(3), reason: "HTTP 502" }])
    expect(f.requested.filter(u => u === activity(3))).toHaveLength(2)
  })

  it("retries a body that fails partway once", async () => {
    const dropped: FetchResponse = {
      status: 200,
      body: { getReader: () => ({ read: () => Promise.reject(new Error("terminated")), cancel: async () => undefined }) }
    }
    const f = fakeFetch({ [activity(1)]: [dropped, response(200, JSON.stringify(fixture("activity-100")))] })
    const derived = await deriveProfile(deps(f.fetchImpl), [ap(activity(1))])
    expect(derived.content_urls).toEqual([activity(1)])
    expect(f.requested).toEqual([activity(1), activity(1)])
  })

  it("abandons a fetch that does not answer in time, without retrying it", async () => {
    let calls = 0
    const hang: ProfileDeps["fetchImpl"] = (_url, init) => {
      calls++
      return new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(new Error("aborted"))))
    }
    const derived = await deriveProfile(deps(hang, { fetchTimeoutMs: 20 }), [ap(activity(1))])
    expect(derived.unread).toEqual([{ url: activity(1), reason: "timed out" }])
    expect(calls).toBe(1)
  })

  it("counts a body that stalls past the deadline as timed out", async () => {
    const stall: ProfileDeps["fetchImpl"] = async (_url, init) => ({
      status: 200,
      body: {
        getReader: () => ({
          read: () => new Promise((_resolve, reject) => init.signal.addEventListener("abort", () => reject(new Error("aborted")))),
          cancel: async () => undefined
        })
      }
    })
    const derived = await deriveProfile(deps(stall, { fetchTimeoutMs: 20 }), [ap(activity(1))])
    expect(derived.unread).toEqual([{ url: activity(1), reason: "timed out" }])
  })

  it("fetches 35 activities with at most five in flight", async () => {
    const routes: Record<string, FetchResponse> = {}
    for (let id = 1; id <= 35; id++) routes[activity(id)] = response(200, JSON.stringify(fixture("activity-100")))
    const f = fakeFetch(routes)
    const derived = await deriveProfile(deps(f.fetchImpl), Object.keys(routes).map(u => ap(u)))
    expect(f.requested).toHaveLength(35)
    expect(f.maxInFlight()).toBe(5)
    expect(derived.content_urls).toHaveLength(35)
  })

  it("keeps the first 500 of more distinct interactive URLs, in sorted order, and says so", async () => {
    const embeddables = Array.from({ length: 600 }, (_, i) => ({ type: "MwInteractive", url: `https://x.org/${String(i).padStart(3, "0")}` }))
    const f = fakeFetch({ [activity(1)]: response(200, JSON.stringify({ pages: [{ embeddables }] })) })
    const derived = await deriveProfile(deps(f.fetchImpl), [ap(activity(1))])
    expect(derived.truncated).toBe(true)
    expect(derived.interactive_urls).toHaveLength(MAX_INTERACTIVE_URLS)
    expect(derived.interactive_urls[499]).toBe("https://x.org/499")
  })

  it("gives the same result for the same inputs", async () => {
    const make = () => fakeFetch({
      [activity(100)]: response(200, JSON.stringify(fixture("activity-100"))),
      [activity(1000)]: response(200, JSON.stringify(fixture("activity-1000"))),
      [activity(2)]: response(404, "{}")
    })
    const urls = [ap(activity(1000)), ap(activity(2)), ap(activity(100))]
    expect(await deriveProfile(deps(make().fetchImpl), urls)).toEqual(await deriveProfile(deps(make().fetchImpl), [...urls].reverse()))
  })
})

describe("what the deriver reads", () => {
  const source = fs.readFileSync(path.join(__dirname, "derive-profile.ts"), "utf8")

  it("never touches authored state, an interactive's display name, or CLUE's curriculum", () => {
    expect(source).not.toMatch(/authored_state/)
    expect(source).not.toMatch(/\.name\b/)
    expect(source).not.toMatch(/curriculum/i)
  })
})
