import { portalTokenFetch } from "./portal-api";

/** One offering as returned inside classes#info's `offerings[]` (get_info shape). */
export interface PortalOffering {
  id: number;
  name: string;
  active: boolean;
  locked: boolean;
  /** Per-student metadata array; opaque to the callers here. */
  metadata: unknown[];
  /** The offering's own portal API URL (get_info `url` => api_v1_offering_url). */
  offeringApiUrl?: string;
  /** The underlying activity URL (get_info `external_url` => runnable.url). */
  activityUrl?: string;
}

/**
 * PII NOTE: unlike students (get_info anonymizes their names, and student emails are
 * synthetic), get_info returns teachers' REAL first_name/last_name. `teachers[]` is
 * therefore real PII — never log a PortalClass.teachers[] and never place it in a
 * StepResult (send-email renders StepResult text into the teacher-notification email).
 */
export interface PortalTeacher {
  id: string;
  user_id: number;
  first_name: string;
  last_name: string;
}

/** The subset of classes#info the pipeline steps consume. */
export interface PortalClass {
  id: number;
  name: string;
  classWord: string;
  teachers: PortalTeacher[];
  offerings: PortalOffering[];
}

export interface ClassLookupResult {
  status: number;
  class?: PortalClass;
}

/**
 * Resolve a class by its environment-stable class word via
 * GET /api/v1/classes/info?class_word=<word>.
 *
 * `classes#info` performs no per-class authorization, so ANY valid teacher token
 * suffices — the caller passes the origin (unscoped) teacher token. The endpoint
 * hardcodes anonymize=true (names come back as "Student"), and student emails are
 * synthetic on all environments, so the body carries no real student PII.
 *
 * The token is passed straight to portalTokenFetch and never inspected here.
 */
export const lookupClassByWord = async (
  portalUrl: string,
  token: string,
  classWord: string,
): Promise<ClassLookupResult> => {
  const path = `/api/v1/classes/info?class_word=${encodeURIComponent(classWord)}`;
  const response = await portalTokenFetch({ portalUrl, path, method: "GET", token });

  const ok = response.status >= 200 && response.status < 300 && response.data?.id !== undefined;
  if (!ok) {
    return { status: response.status };
  }

  const data = response.data;
  const resolved: PortalClass = {
    id: data.id,
    name: data.name,
    classWord: data.class_word,
    teachers: Array.isArray(data.teachers) ? data.teachers : [],
    offerings: Array.isArray(data.offerings)
      ? data.offerings.map((o: any) => ({
          id: o.id,
          name: o.name,
          active: !!o.active,
          locked: !!o.locked,
          metadata: Array.isArray(o.metadata) ? o.metadata : [],
          // get_info returns BOTH: `url` = the offering's API URL, `external_url` = the activity URL.
          offeringApiUrl: typeof o.url === "string" ? o.url : undefined,
          activityUrl: typeof o.external_url === "string" ? o.external_url : undefined,
        }))
      : [],
  };
  return { status: response.status, class: resolved };
};

export interface OriginOffering {
  clazzId: number | string;
  classWord?: string;
}

export interface OriginOfferingResult {
  status: number;
  offering?: OriginOffering;
}

/**
 * Read the student's origin offering by resource_link_id, returning both clazz_id
 * (unconditional) and class_word (teacher-gated; present for the origin-class teacher
 * token these pipelines mint) from the single offerings#show response.
 */
export const resolveOriginOffering = async (
  portalUrl: string,
  token: string,
  offeringId: string,
): Promise<OriginOfferingResult> => {
  const response = await portalTokenFetch({
    portalUrl,
    path: `/api/v1/offerings/${offeringId}`,
    method: "GET",
    token,
  });
  const clazzId = response.data?.clazz_id;
  const ok =
    response.status >= 200 && response.status < 300 && clazzId !== undefined && clazzId !== null;
  if (!ok) {
    return { status: response.status };
  }
  return {
    status: response.status,
    offering: {
      clazzId,
      classWord: typeof response.data?.class_word === "string" ? response.data.class_word : undefined,
    },
  };
};
