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
  /** Validated non-null; `number | string` mirrors OriginOffering.clazzId. */
  id: number | string;
  name: string;
  classWord: string;
  teachers: PortalTeacher[];
  offerings: PortalOffering[];
}

export interface ClassLookupResult {
  status: number;
  class?: PortalClass;
}

/** A JSON string field is usable when it is present and not just whitespace. */
const isNonBlankString = (value: unknown): value is string =>
  typeof value === "string" && value.trim() !== "";

/**
 * A JSON id is usable when it is a finite number or a nonblank string. Mirrors the shape
 * `OriginOffering.clazzId` already accepts, so the two reads in this file agree on what a
 * valid identifier is.
 */
const isUsableId = (value: unknown): value is number | string =>
  (typeof value === "number" && Number.isFinite(value)) || isNonBlankString(value);

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
 *
 * A 2xx is not by itself a resolved class: the fields the callers consume are validated before
 * one is returned, and a malformed success body is reported as `{ status }` so the caller takes
 * the same classified-failure path as any other unusable response. This matters because the
 * values flow straight into side effects: `id` is minted against and posted as `clazz_id`, so a
 * null one would enroll into class "null", and `name` is rendered into the teacher-notification
 * email. rigse answers an unknown word with a 400 rather than a null-id 200, so this is
 * type-boundary hardening rather than a live defect; it exists so the two reads in this file
 * agree, since resolveOriginOffering already rejects a null clazz_id.
 */
export const lookupClassByWord = async (
  portalUrl: string,
  token: string,
  classWord: string,
): Promise<ClassLookupResult> => {
  const path = `/api/v1/classes/info?class_word=${encodeURIComponent(classWord)}`;
  const response = await portalTokenFetch({ portalUrl, path, method: "GET", token });

  const data = response.data;
  // teachers/offerings need no guard here: the mapper below coerces a non-array to [] for both.
  const ok =
    response.status >= 200 &&
    response.status < 300 &&
    isUsableId(data?.id) &&
    isNonBlankString(data?.name) &&
    isNonBlankString(data?.class_word);
  if (!ok) {
    return { status: response.status };
  }

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
 *
 * `clazz_id` is validated with the same isUsableId the class read uses, which is what makes that
 * helper's claim (that the two reads agree on what a valid identifier is) true for an empty string
 * and a non-scalar as well as for null. It matters because the value now travels as a documented
 * handoff: a blank id is skipped by readStepOutputField, so send-email would fall back to this same
 * read, get the same blank, and post `class_id: ""`; a non-scalar would post "[object Object]". Both
 * end in a portal rejection rather than a wrong class, but neither names its cause.
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
  const ok = response.status >= 200 && response.status < 300 && isUsableId(clazzId);
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
