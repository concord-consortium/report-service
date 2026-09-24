// The authored URL profile of a class: the URLs its assignments name, and the interactive URLs
// inside the Activity Player content they point at. It reads only structural fields whose meaning
// is the same for every interactive, so a new interactive needs no change here.

export const MAX_INTERACTIVE_URLS = 500
const MAX_BODY_BYTES = 5 * 1024 * 1024
const FETCH_TIMEOUT_MS = 15_000
const MAX_IN_FLIGHT = 5

export interface FetchInit { redirect: "manual"; signal: AbortSignal }
export interface FetchResponse {
  status: number
  body?: { getReader(): { read(): Promise<{ done: boolean; value?: Uint8Array }>; cancel(): Promise<void> } } | null
}

export interface ProfileDeps {
  fetchImpl: (url: string, init: FetchInit) => Promise<FetchResponse>
  allowedHosts: Set<string>
  fetchTimeoutMs?: number
}

export interface Unread { url: string; reason: string }
export interface Derived {
  interactive_urls: string[]
  content_urls: string[]
  unread: Unread[]
  truncated: boolean
}

/** The content URL an assignment URL names in its `activity` or `sequence` parameter, if any. */
export function contentUrlOf(assignmentUrl: string): string | undefined {
  let url: URL
  try {
    url = new URL(assignmentUrl)
  } catch {
    return undefined
  }
  const content = url.searchParams.get("activity") ?? url.searchParams.get("sequence")
  return content && /^https?:\/\//i.test(content) ? content : undefined
}

/**
 * The HTTPS URL to fetch for a content URL, or undefined when its host is not exactly one of the
 * allowed hosts on the default port with no userinfo.
 */
export function allowedContentUrl(contentUrl: string, allowedHosts: Set<string>): string | undefined {
  let url: URL
  try {
    url = new URL(contentUrl)
  } catch {
    return undefined
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return undefined
  if (url.username || url.password || url.port) return undefined
  if (!allowedHosts.has(url.hostname)) return undefined
  url.protocol = "https:"
  return url.toString()
}

const isObject = (v: unknown): v is Record<string, any> => typeof v === "object" && v !== null && !Array.isArray(v)
const asArray = (v: unknown): unknown[] => (Array.isArray(v) ? v : [])

/**
 * The URL of each interactive in an activity, as the Activity Player loads it: a
 * ManagedInteractive's library base URL plus its fragment, or a legacy MwInteractive's url.
 */
export function interactiveUrls(activity: unknown): string[] {
  const out: string[] = []
  if (!isObject(activity)) return out
  for (const page of asArray(activity.pages)) {
    if (!isObject(page)) continue
    const sections = asArray(page.sections).filter(isObject)
    const embeddables = [...asArray(page.embeddables), ...sections.flatMap(s => asArray(s.embeddables))]
    for (const e of embeddables) {
      if (!isObject(e)) continue
      if (e.type === "ManagedInteractive") {
        const base = isObject(e.library_interactive) && isObject(e.library_interactive.data) ? e.library_interactive.data.base_url : undefined
        if (typeof base === "string" && base) out.push(base + (typeof e.url_fragment === "string" ? e.url_fragment : ""))
      } else if (e.type === "MwInteractive" && typeof e.url === "string" && e.url) {
        out.push(e.url)
      }
    }
  }
  return out
}

/** A sequence embeds its activities in full, so either shape yields its interactives in one fetch. */
function contentInteractiveUrls(json: unknown): string[] {
  if (isObject(json) && Array.isArray(json.activities)) return json.activities.flatMap(interactiveUrls)
  return interactiveUrls(json)
}

class FetchFailure extends Error {
  constructor(message: string, public retryable: boolean) {
    super(message)
  }
}

async function readBounded(response: FetchResponse): Promise<string> {
  const reader = response.body?.getReader()
  if (!reader) return ""
  const chunks: Uint8Array[] = []
  let total = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    if (!value) continue
    total += value.byteLength
    if (total > MAX_BODY_BYTES) {
      await reader.cancel().catch(() => undefined)
      throw new FetchFailure("response exceeds 5 MiB", false)
    }
    chunks.push(value)
  }
  return Buffer.concat(chunks).toString("utf8")
}

async function fetchOnce(deps: ProfileDeps, url: string): Promise<unknown> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), deps.fetchTimeoutMs ?? FETCH_TIMEOUT_MS)
  try {
    let response: FetchResponse
    try {
      response = await deps.fetchImpl(url, { redirect: "manual", signal: controller.signal })
    } catch (e) {
      if (controller.signal.aborted) throw new FetchFailure("timed out", false)
      throw new FetchFailure(`network error: ${e instanceof Error ? e.message : String(e)}`, true)
    }
    if (response.status !== 200) {
      // an unread body holds its connection open until garbage collection
      await response.body?.getReader().cancel().catch(() => undefined)
      if (response.status >= 300 && response.status < 400) throw new FetchFailure("redirect not followed", false)
      throw new FetchFailure(`HTTP ${response.status}`, response.status >= 500)
    }
    let text: string
    try {
      text = await readBounded(response)
    } catch (e) {
      if (e instanceof FetchFailure) throw e
      if (controller.signal.aborted) throw new FetchFailure("timed out", false)
      throw new FetchFailure(`network error: ${e instanceof Error ? e.message : String(e)}`, true)
    }
    try {
      return JSON.parse(text)
    } catch {
      throw new FetchFailure("not JSON", false)
    }
  } finally {
    clearTimeout(timer)
  }
}

async function fetchJson(deps: ProfileDeps, url: string): Promise<unknown> {
  try {
    return await fetchOnce(deps, url)
  } catch (e) {
    if (e instanceof FetchFailure && e.retryable) return fetchOnce(deps, url)
    throw e
  }
}

async function eachLimited<T>(items: T[], limit: number, fn: (item: T) => Promise<void>) {
  let next = 0
  const worker = async () => {
    while (next < items.length) await fn(items[next++])
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))
}

/**
 * Follows each assignment URL that names its content, within the allowed hosts, and collects the
 * interactive URLs. A URL that cannot be read is recorded in `unread` and the rest still derive.
 */
export async function deriveProfile(deps: ProfileDeps, assignmentUrls: string[]): Promise<Derived> {
  const contentUrls = Array.from(new Set(assignmentUrls.map(contentUrlOf).filter((u): u is string => !!u)))
  const read: string[] = []
  const unread: Unread[] = []
  const found = new Set<string>()

  await eachLimited(contentUrls, MAX_IN_FLIGHT, async contentUrl => {
    const target = allowedContentUrl(contentUrl, deps.allowedHosts)
    if (!target) {
      unread.push({ url: contentUrl, reason: "host not allowed" })
      return
    }
    try {
      contentInteractiveUrls(await fetchJson(deps, target)).forEach(u => found.add(u))
      read.push(contentUrl)
    } catch (e) {
      unread.push({ url: contentUrl, reason: e instanceof FetchFailure ? e.message : "failed" })
    }
  })

  const sorted = Array.from(found).sort()
  return {
    interactive_urls: sorted.slice(0, MAX_INTERACTIVE_URLS),
    content_urls: read.sort(),
    unread: unread.sort((a, b) => (a.url < b.url ? -1 : a.url > b.url ? 1 : 0)),
    truncated: sorted.length > MAX_INTERACTIVE_URLS
  }
}
