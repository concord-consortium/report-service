import { readFileSync } from "fs"
import { join } from "path"
import { makeMicrovmApi } from "./microvm"

// The SDK needs `node:` builtins this Jest cannot resolve, so its client and commands are
// replaced by stand-ins that record what they are sent.
const send = jest.fn()
const clientConfigs: object[] = []
jest.mock("@aws-sdk/client-lambda-microvms", () => {
  const command = (name: string) => class { name = name; constructor(public input: object) {} }
  return {
    LambdaMicrovmsClient: class { send = send; constructor(public config: object) { clientConfigs.push(config) } },
    GetMicrovmCommand: command("GetMicrovm"),
    GetMicrovmImageCommand: command("GetMicrovmImage"),
    ResumeMicrovmCommand: command("ResumeMicrovm"),
    RunMicrovmCommand: command("RunMicrovm")
  }
})

describe("makeMicrovmApi", () => {
  beforeEach(() => send.mockReset())

  const api = () => makeMicrovmApi({ accessKeyId: "AKIA", secretAccessKey: "secret" })

  it("runs a VM with internet egress, an eight-hour cap, and no idle policy or ingress connectors", async () => {
    send.mockResolvedValue({ microvmId: "vm-1", imageVersion: "7" })

    const vm = await api().run({ imageIdentifier: "arn:image", imageVersion: "7", executionRoleArn: "arn:role", runHookPayload: "{}" })

    expect(vm).toEqual({ microvmId: "vm-1", imageVersion: "7" })
    expect(send.mock.calls[0][0].name).toBe("RunMicrovm")
    expect(send.mock.calls[0][0].input).toEqual({
      imageIdentifier: "arn:image",
      imageVersion: "7",
      executionRoleArn: "arn:role",
      runHookPayload: "{}",
      egressNetworkConnectors: ["INTERNET_EGRESS"],
      maximumDurationInSeconds: 8 * 60 * 60
    })
  })

  it("makes each call once and cuts it off at the timeout", () => {
    api()

    expect(clientConfigs[clientConfigs.length - 1]).toMatchObject({
      maxAttempts: 1,
      requestHandler: { requestTimeout: 10000, throwOnRequestTimeout: true }
    })
  })

  it("reads a VM the API does not know as null", async () => {
    send.mockRejectedValue(Object.assign(new Error("not found"), { name: "ResourceNotFoundException" }))

    expect(await api().get("vm-gone")).toBeNull()
  })

  it("passes any other GetMicrovm failure through", async () => {
    send.mockRejectedValue(Object.assign(new Error("denied"), { name: "AccessDeniedException" }))

    await expect(api().get("vm-1")).rejects.toThrow("denied")
  })

  it("resumes by microvm id", async () => {
    send.mockResolvedValue({})

    await api().resume("vm-1")

    expect(send.mock.calls[0][0]).toMatchObject({ name: "ResumeMicrovm", input: { microvmIdentifier: "vm-1" } })
  })

  it("reads the image's latest active version", async () => {
    send.mockResolvedValue({ latestActiveImageVersion: "7" })

    expect(await api().currentImageVersion("arn:image")).toBe("7")
    expect(send.mock.calls[0][0]).toMatchObject({ name: "GetMicrovmImage", input: { imageIdentifier: "arn:image" } })
  })

  it("never mints a MicroVM auth token", () => {
    const dashboardSources = ["microvm.ts", "ensure-vm.ts", "run-package.ts", "app.ts"]
      .map(file => readFileSync(join(__dirname, file), "utf8"))

    for (const source of dashboardSources) expect(source).not.toMatch(/CreateMicrovm(Shell)?AuthToken/)
  })
})
