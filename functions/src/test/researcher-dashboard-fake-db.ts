import { Db, DocRef, Transaction } from "../researcher-dashboard/run-package"

const isPlainObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v)
// Firestore's set-with-merge: nested maps merge key by key, anything else is replaced.
const deepMerge = (target: Record<string, unknown>, source: Record<string, unknown>): Record<string, unknown> => {
  const out = { ...target }
  for (const [k, v] of Object.entries(source)) {
    out[k] = isPlainObject(v) && isPlainObject(out[k]) ? deepMerge(out[k] as Record<string, unknown>, v) : v
  }
  return out
}

// Firestore's set with mergeFields: each named dotted path is replaced whole, nothing else changes.
const setFields = (target: Record<string, unknown>, source: Record<string, unknown>, fields: string[]) => {
  const out = JSON.parse(JSON.stringify(target))
  for (const field of fields) {
    const parts = field.split(".")
    let from: any = source
    let to: any = out
    parts.slice(0, -1).forEach(part => {
      from = from[part]
      to = to[part] = isPlainObject(to[part]) ? to[part] : {}
    })
    const last = parts[parts.length - 1]
    to[last] = from[last]
  }
  return out
}

/** An in-memory Firestore for the slice of the Admin SDK the dashboard function uses. */
export class FakeDb implements Db {
  docs = new Map<string, Record<string, unknown>>()
  commits = 0

  doc(path: string): DocRef {
    return { path, get: async () => ({ data: () => this.read(path) }) }
  }

  read(path: string) {
    return this.docs.has(path) ? JSON.parse(JSON.stringify(this.docs.get(path))) : undefined
  }

  // Transactions run one at a time, which is what Firestore's retry on contention amounts to.
  private queue: Promise<unknown> = Promise.resolve()

  runTransaction<T>(fn: (tx: Transaction) => Promise<T>): Promise<T> {
    const run = this.queue.then(() => this.transact(fn))
    this.queue = run.catch(() => undefined)
    return run
  }

  private async transact<T>(fn: (tx: Transaction) => Promise<T>): Promise<T> {
    const writes: [string, Record<string, unknown>, { merge?: boolean; mergeFields?: string[] } | undefined][] = []
    const tx: Transaction = {
      get: async ref => ({ data: () => this.read(ref.path) }),
      set: (ref, data, options) => { writes.push([ref.path, data as Record<string, unknown>, options]) }
    }
    const result = await fn(tx)
    for (const [path, data, options] of writes) {
      const current = this.docs.get(path) ?? {}
      if (options?.mergeFields) this.docs.set(path, setFields(current, data, options.mergeFields))
      else this.docs.set(path, options?.merge ? deepMerge(current, data) : data)
    }
    this.commits++
    return result
  }
}

