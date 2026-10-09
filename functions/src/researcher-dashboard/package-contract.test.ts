import * as fs from "fs"
import * as path from "path"
import { IDENTITY } from "./run-package"
import { packageKey } from "./firestore-paths"
import { MAX_URL_LENGTH } from "./derive-profile"

const fixture = JSON.parse(fs.readFileSync(path.resolve(__dirname, "../../../fixtures/package-contract.json"), "utf8"))

describe("the package contract fixture", () => {
  it("every identity case", () => {
    expect(fixture.identity.length).toBeGreaterThan(0)
    for (const c of fixture.identity) expect([c.value, IDENTITY.test(c.value)]).toEqual([c.value, c.valid])
  })

  it("every package key case", () => {
    expect(fixture.package_key.length).toBeGreaterThan(0)
    for (const c of fixture.package_key) expect(packageKey(c.identity)).toBe(c.key)
  })

  it("the deriver's URL length is the contract's", () => {
    expect(MAX_URL_LENGTH).toBe(fixture.limits.max_url_length)
  })
})
