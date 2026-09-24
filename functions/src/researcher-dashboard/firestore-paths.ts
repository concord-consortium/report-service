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
