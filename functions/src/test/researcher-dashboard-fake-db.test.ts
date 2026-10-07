import * as admin from "firebase-admin"
import { FakeDb } from "./researcher-dashboard-fake-db"

describe("FakeDb", () => {
  it("keeps a Timestamp a Timestamp through a write and a read", async () => {
    const db = new FakeDb()
    const ref = db.doc("things/1")

    await db.runTransaction(async tx => { tx.set(ref, { at: admin.firestore.Timestamp.fromMillis(1000), list: [{ n: 1 }] }) })
    const read = (await ref.get()).data() as { at: admin.firestore.Timestamp, list: { n: number }[] }

    expect(read.at.toMillis()).toBe(1000)
    expect(read.list).toEqual([{ n: 1 }])
  })

  it("hands out copies, so changing what was read changes nothing stored", async () => {
    const db = new FakeDb()
    const ref = db.doc("things/1")
    await db.runTransaction(async tx => { tx.set(ref, { nested: { n: 1 } }) })

    const read = (await ref.get()).data() as { nested: { n: number } }
    read.nested.n = 2

    expect(((await ref.get()).data() as { nested: { n: number } }).nested.n).toBe(1)
  })
})
