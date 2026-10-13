import { readFileSync } from "fs"
import { join } from "path"
import { SERVICE_ACCOUNT_ID, unsetBrokerSettings, unsetLaunchSettings } from "./config"

describe("config", () => {
  it("names the same service account the setup script creates", () => {
    const script = readFileSync(join(__dirname, "../../scripts/setup-researcher-dashboard-iam.sh"), "utf8")

    expect(script).toMatch(new RegExp(`^SERVICE_ACCOUNT_ID=${SERVICE_ACCOUNT_ID}$`, "m"))
  })

  it("has the setup script grant what /work's custom tokens need", () => {
    const script = readFileSync(join(__dirname, "../../scripts/setup-researcher-dashboard-iam.sh"), "utf8")
    const list = (name: string) => script.match(new RegExp(`^${name}=\\(\\n([^)]*)\\)`, "m"))?.[1].split(/\s+/).filter(Boolean)

    expect(list("SELF_ROLES")).toContain("roles/iam.serviceAccountTokenCreator")
    expect(list("SERVICES")).toEqual(["iamcredentials.googleapis.com"])
  })

  it("has operators mint ID tokens with OpenID Token Creator alone", () => {
    const script = readFileSync(join(__dirname, "../../scripts/setup-researcher-dashboard-iam.sh"), "utf8")

    expect(script).toMatch(/^OPERATOR_ROLE=roles\/iam\.serviceAccountOpenIdTokenCreator$/m)
    expect(script).toMatch(/serviceAccounts\/\$email:generateIdToken/)
    // gcloud's impersonation mints an access token first, which that role does not allow.
    const code = script.split("\n").filter(line => !/^\s*#/.test(line)).join("\n")
    expect(code).not.toMatch(/--impersonate-service-account/)
  })

  it("lists every param in both projects' .env files", () => {
    const params = [...readFileSync(join(__dirname, "config.ts"), "utf8").matchAll(/define(?:String|Int)\("([A-Z_]+)"/g)].map(m => m[1])
    expect(params).toContain("RD_BROKER_ROLE_ARN")
    for (const project of ["report-service-dev", "report-service-pro"]) {
      const env = readFileSync(join(__dirname, `../../.env.${project}`), "utf8")
      for (const param of params) {
        expect(env).toMatch(new RegExp(`^${param}=`, "m"))
      }
    }
  })

  it("counts the launcher role, the broker role and their audience as launch settings", () => {
    expect(unsetLaunchSettings()).toEqual(expect.arrayContaining(["RD_LAUNCHER_ROLE_ARN", "RD_AWS_AUDIENCE", "RD_BROKER_ROLE_ARN"]))
  })

  it("counts the broker role, the bucket and the audience as the broker's settings", () => {
    expect(unsetBrokerSettings()).toEqual(["RD_BROKER_ROLE_ARN", "RD_DATA_BUCKET", "RD_AWS_AUDIENCE"])
  })
})
