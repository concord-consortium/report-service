// Which network connectors a researcher's MicroVM is launched with.
//
// Its own module because it is a policy decision with no AWS client in it, so it can be
// tested without one, and because the decision is the interesting part: the SDK call that
// consumes it is not.
const REGION = "us-east-1"

export const CONNECTOR = (name: string) =>
  `arn:aws:lambda:${REGION}:aws:network-connector:aws-network-connector:${name}`

// A shell connector yields an interactive root PTY on port 8022 to anyone who can call
// create-microvm-shell-auth-token, so it is off unless an environment deliberately asks
// for it. Debugging a VM and running researchers' analyses on it are different jobs, and
// only the first wants a shell. ALL_INGRESS cannot be combined with anything else, which
// is why this is the granular pair rather than a single permissive connector.
export function ingressConnectors(env: NodeJS.ProcessEnv = process.env): string[] {
  const connectors = [CONNECTOR("HTTP_INGRESS")]
  if (env.RD_SHELL_INGRESS === "1") connectors.push(CONNECTOR("SHELL_INGRESS"))
  return connectors
}
