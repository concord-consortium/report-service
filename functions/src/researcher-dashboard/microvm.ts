import {
  GetMicrovmCommand,
  GetMicrovmImageCommand,
  LambdaMicrovmsClient,
  ResumeMicrovmCommand,
  RunMicrovmCommand
} from "@aws-sdk/client-lambda-microvms"
import { UPSTREAM_TIMEOUT_MS } from "./ensure-vm"

// The runner stack's region
const REGION = "us-east-1"
// A VM's maximum life, which also bounds how long an old image keeps serving
const MAXIMUM_DURATION_SECONDS = 8 * 60 * 60

/**
 * The MicroVM calls the function makes. There is deliberately no auth-token method: nothing
 * here calls into a VM, and the launcher's policy does not grant minting one.
 */
export interface MicrovmApi {
  currentImageVersion(imageIdentifier: string): Promise<string | undefined>
  /** The VM's state, or null when the API has no such VM. */
  get(microvmId: string): Promise<{ state?: string } | null>
  run(input: { imageIdentifier: string; imageVersion?: string; executionRoleArn: string; runHookPayload: string }):
    Promise<{ microvmId: string; imageVersion?: string }>
  resume(microvmId: string): Promise<void>
}

export function makeMicrovmApi(credentials: { accessKeyId: string; secretAccessKey: string }): MicrovmApi {
  // One attempt, cut off at the timeout: a failure is answered and the queued work kept, and
  // retries would not fit the function's own timeout.
  const client = new LambdaMicrovmsClient({
    region: REGION,
    credentials,
    maxAttempts: 1,
    requestHandler: { requestTimeout: UPSTREAM_TIMEOUT_MS, throwOnRequestTimeout: true }
  })

  return {
    async currentImageVersion(imageIdentifier) {
      const image = await client.send(new GetMicrovmImageCommand({ imageIdentifier }))
      return image.latestActiveImageVersion
    },

    async get(microvmId) {
      try {
        const vm = await client.send(new GetMicrovmCommand({ microvmIdentifier: microvmId }))
        return { state: vm.state }
      } catch (e) {
        if ((e as { name?: string })?.name === "ResourceNotFoundException") return null
        throw e
      }
    },

    // No idlePolicy: the platform measures idle by inbound traffic, which the pull model never
    // sends, so every VM would look idle. No ingress connectors: nothing calls into the VM.
    async run({ imageIdentifier, imageVersion, executionRoleArn, runHookPayload }) {
      const vm = await client.send(new RunMicrovmCommand({
        imageIdentifier,
        imageVersion,
        executionRoleArn,
        runHookPayload,
        egressNetworkConnectors: ["INTERNET_EGRESS"],
        maximumDurationInSeconds: MAXIMUM_DURATION_SECONDS
      }))
      if (!vm.microvmId) throw new Error("RunMicrovm returned no microvm id")
      return { microvmId: vm.microvmId, imageVersion: vm.imageVersion }
    },

    async resume(microvmId) {
      await client.send(new ResumeMicrovmCommand({ microvmIdentifier: microvmId }))
    }
  }
}
