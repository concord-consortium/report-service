import { readFileSync } from "fs"
import { join } from "path"
import { SERVICE_ACCOUNT_ID, unsetLaunchSettings } from "./config"

describe("config", () => {
  it("names the same service account the setup script creates", () => {
    const script = readFileSync(join(__dirname, "../../scripts/setup-researcher-dashboard-iam.sh"), "utf8")

    expect(script).toMatch(new RegExp(`^SERVICE_ACCOUNT_ID=${SERVICE_ACCOUNT_ID}$`, "m"))
  })

  it("counts the launcher role and its audience as launch settings", () => {
    expect(unsetLaunchSettings()).toEqual(expect.arrayContaining(["RD_LAUNCHER_ROLE_ARN", "RD_AWS_AUDIENCE"]))
  })
})
