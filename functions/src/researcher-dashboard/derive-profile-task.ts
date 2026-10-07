import { onTaskDispatched } from "firebase-functions/v2/tasks"
import { rdAuthoringHosts, SERVICE_ACCOUNT_ID } from "./config"
import { DeriveTask, parseAllowedHosts } from "./derive-profile-route"
import { defaultDerivationDeps, runDerivation } from "./derive-profile-worker"

// Only index.ts imports this module: Jest 24 cannot resolve firebase-functions/v2 subpaths.
export const deriveProfileWorker = onTaskDispatched(
  {
    retryConfig: { maxAttempts: 3, minBackoffSeconds: 10 },
    rateLimits: { maxConcurrentDispatches: 10 },
    timeoutSeconds: 300,
    memory: "512MiB",
    // The account researcherDashboard runs as, and names in each task's OIDC token. A deploy grants
    // it run.invoker on this function and cloudtasks.enqueuer on this function's queue.
    invoker: `${SERVICE_ACCOUNT_ID}@`
  },
  async req => runDerivation(defaultDerivationDeps(parseAllowedHosts(rdAuthoringHosts.value())), req.data as DeriveTask)
)
