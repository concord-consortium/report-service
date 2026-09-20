import { ingressConnectors } from "./connectors"

const SHELL = expect.stringContaining("SHELL_INGRESS")

describe("ingressConnectors", () => {
  // A shell connector is an interactive root PTY on the VM. Every researcher's analyses
  // run on these, so the default has to be the one that grants nothing extra.
  it("attaches no shell connector by default", () => {
    expect(ingressConnectors({})).not.toContainEqual(SHELL)
  })

  it("attaches one when the environment asks for it", () => {
    expect(ingressConnectors({ RD_SHELL_INGRESS: "1" })).toContainEqual(SHELL)
  })

  // Anything other than the exact opt-in is off, so a stray "false" or "0" left in a
  // deployment's environment cannot read as permission.
  it.each(["0", "false", "no", "", "true"])("treats %p as no shell", (value) => {
    expect(ingressConnectors({ RD_SHELL_INGRESS: value })).not.toContainEqual(SHELL)
  })

  it("always attaches http ingress, which is how the runner is reached at all", () => {
    for (const env of [{}, { RD_SHELL_INGRESS: "1" }]) {
      expect(ingressConnectors(env)).toContainEqual(expect.stringContaining("HTTP_INGRESS"))
    }
  })
})
