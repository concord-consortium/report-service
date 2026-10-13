import { readFileSync } from "fs"
import { join } from "path"
import { MAXIMUM_DURATION_SECONDS } from "./ensure-vm"
import { HEARTBEAT_MAX_SECONDS, HEARTBEAT_MIN_SECONDS } from "./watchdog"

const rules = readFileSync(join(__dirname, "../../../firestore.rules"), "utf8")
const bounds = (pattern: RegExp) => [...rules.matchAll(pattern)].map(m => Number(m[1]))

describe("firestore.rules", () => {
  it("bounds a claimed run's declared duration at the VM's maximum life", () => {
    expect(bounds(/expected_duration_seconds <= (\d+)/g)).toEqual([MAXIMUM_DURATION_SECONDS])
  })

  it("bounds a claimed run's heartbeat_seconds where the watchdog does", () => {
    expect(bounds(/heartbeat_seconds >= (\d+)/g)).toEqual([HEARTBEAT_MIN_SECONDS])
    expect(bounds(/heartbeat_seconds <= (\d+)/g)).toEqual([HEARTBEAT_MAX_SECONDS])
  })
})
