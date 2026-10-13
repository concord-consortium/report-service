// The portal host with dots as underscores, the convention CLUE and report-service share.
export const portalSegment = (iss: string) => new URL(iss).host.replace(/\./g, "_")

// The identity with "/" as "__": one path segment, reversible, and never Firestore's reserved
// `__.*__`, since a package name cannot contain "_".
export const packageKey = (identity: string) => identity.replace(/\//g, "__")

export const root = (portal: string) => `researcher_dashboard/${portal}`
export const workPath = (portal: string, platformUserId: string) => `${root(portal)}/work/${platformUserId}`
export const runnerPath = (portal: string, platformUserId: string) => `${root(portal)}/runners/${platformUserId}`
export const vmPath = (portal: string, platformUserId: string) => `${root(portal)}/vms/${platformUserId}`
export const classPath = (portal: string, classHash: string) => `${root(portal)}/classes/${classHash}`
export const resultPath = (portal: string, classHash: string, platformUserId: string, key: string) =>
  `${classPath(portal, classHash)}/researchers/${platformUserId}/results/${key}`

// What a collection-group query returned, read back from its path; anything outside the
// dashboard's tree is null and ignored.
const RESULT_PATH = /^researcher_dashboard\/([^/]+)\/classes\/([^/]+)\/researchers\/([^/]+)\/results\/([^/]+)$/
const VM_PATH = /^researcher_dashboard\/([^/]+)\/vms\/([^/]+)$/

export function parseResultPath(path: string) {
  const m = RESULT_PATH.exec(path)
  return m ? { portal: m[1], classHash: m[2], platformUserId: m[3], packageKey: m[4] } : null
}

export function parseVmPath(path: string) {
  const m = VM_PATH.exec(path)
  return m ? { portal: m[1], platformUserId: m[2] } : null
}
