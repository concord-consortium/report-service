import {
  CreateMicrovmAuthTokenCommand,
  GetMicrovmCommand,
  GetMicrovmImageCommand,
  LambdaMicrovmsClient,
  RunMicrovmCommand
} from "@aws-sdk/client-lambda-microvms"
import { CONNECTOR, ingressConnectors } from "./connectors"

// MicroVMs live in the same region as the runner stack, and the same one auto-importer
// already reaches S3 in.
const REGION = "us-east-1"

// Minutes, not hours. The token is minted for one dispatch and the VM outlives it by
// design, so a short life costs nothing and a long one is a credential lying around.
const AUTH_TOKEN_MINUTES = 5

export interface Microvm {
  microvmId: string
  endpoint: string
  imageVersion: string
}

export interface MicrovmApi {
  currentImageVersion(imageIdentifier: string): Promise<string | undefined>
  get(microvmId: string): Promise<{ state?: string; endpoint?: string; imageVersion?: string } | null>
  run(input: {
    imageIdentifier: string
    imageVersion: string
    executionRoleArn: string
    runHookPayload: string
  }): Promise<Microvm>
  authHeaders(microvmId: string, port: number): Promise<Record<string, string>>
}

export function makeMicrovmApi(credentials: { accessKeyId: string; secretAccessKey: string }): MicrovmApi {
  const client = new LambdaMicrovmsClient({ region: REGION, credentials })

  return {
    async currentImageVersion(imageIdentifier) {
      const image = await client.send(new GetMicrovmImageCommand({ imageIdentifier }))
      return image.latestActiveImageVersion
    },

    // A VM the API cannot find is not an error here: it is the ordinary case of a
    // researcher whose last VM has since been torn down.
    async get(microvmId) {
      try {
        const vm = await client.send(new GetMicrovmCommand({ microvmIdentifier: microvmId }))
        return { state: vm.state, endpoint: vm.endpoint, imageVersion: vm.imageVersion }
      } catch (err: any) {
        if (err?.name === "ResourceNotFoundException") return null
        throw err
      }
    },

    async run({ imageIdentifier, imageVersion, executionRoleArn, runHookPayload }) {
      const vm = await client.send(new RunMicrovmCommand({
        imageIdentifier,
        // Pinned to the version the reuse decision was made against. Left to the
        // service, a launch can come up on an older version, and the next request then
        // relaunches for exactly the same reason, forever.
        imageVersion,
        executionRoleArn,
        runHookPayload,
        ingressNetworkConnectors: ingressConnectors(),
        egressNetworkConnectors: [CONNECTOR("INTERNET_EGRESS")],
        // Eight hours is the window the researcher status document advertises as
        // expires_at, and what a package's declared duration is checked against.
        maximumDurationInSeconds: 8 * 60 * 60,
        idlePolicy: {
          maxIdleDurationSeconds: 300,
          suspendedDurationSeconds: 8 * 60 * 60,
          autoResumeEnabled: true
        }
      }))
      return {
        microvmId: vm.microvmId as string,
        endpoint: vm.endpoint as string,
        imageVersion: vm.imageVersion as string
      }
    },

    async authHeaders(microvmId, port) {
      const token = await client.send(new CreateMicrovmAuthTokenCommand({
        microvmIdentifier: microvmId,
        expirationInMinutes: AUTH_TOKEN_MINUTES,
        allowedPorts: [{ port }]
      }))
      return token.authToken ?? {}
    }
  }
}
