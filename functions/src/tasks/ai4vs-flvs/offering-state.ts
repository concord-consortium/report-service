import { StepContext } from "./types";
import {
  getScopedPortalToken, portalTokenFetch, classifyPortalFailure, PortalFailureBucket,
} from "../portal-api";

/**
 * The `{active, locked}` update_student_metadata echoes back. Two booleans and no names, so a
 * caller may log it.
 *
 * Optional because a 2xx with NO body is a supported success on this path, so callers must read
 * through the optional rather than off a bare `returned`.
 */
export interface PortalOfferingFlags {
  active?: boolean;
  locked?: boolean;
}

export interface ApplyOfferingStateParams {
  /**
   * The two callers supply different forms: `resource_link_id` is a decimal string,
   * `PortalOffering.id` is a JSON number. Both interpolate into the request path correctly.
   */
  offeringId: string | number;
  locked: boolean;
  active: boolean;
}

/**
 * A discriminated outcome rather than a StepResult: this core does not render student-facing copy.
 * Each caller maps the bucket to its own failure message, which is what every sibling step already
 * does, and what lets a caller render its non-portal failures through that same single path.
 */
export type OfferingStateOutcome =
  | { ok: true; returned?: PortalOfferingFlags }
  | {
      ok: false;
      bucket: PortalFailureBucket;
      /**
       * Set only when the WRITE was rejected, so the caller can log the portal's status and body
       * under its own step prefix. Absent for a failed mint, which mintScopedPortalToken has
       * already logged; a caller that logged a write failure there would name a request that was
       * never issued.
       */
      status?: number;
      data?: any;
    };

/**
 * Set one student's per-offering state via PUT /api/v1/offerings/:id/update_student_metadata.
 *
 * ⚠️ BOTH FLAGS ARE ALWAYS SENT. `user_offering_metadata` defaults `active` to true and `locked` to
 * false, and all four portal consumers resolve the effective state as "the row wins IF A ROW
 * EXISTS", not "if the value is non-null" (offering_policy.rb:62, runnables_helper.rb:31,
 * offering.rb:52, clazz.rb:251). A PUT carrying only `locked` writes only that key, leaving any
 * pre-existing `active: false` row hidden and an unlock pointless. Sending both makes the resulting
 * state fully determined by the request rather than partly inherited. The portal's own teacher UI
 * works around the same thing (offering-progress-row.tsx:34-35).
 *
 * `active` is an explicit argument rather than a hardcoded true, so a future caller that needs to
 * hide an offering needs no change here.
 *
 * Makes NO host check of its own: like every step here it assumes the pipeline ran
 * validatePortalHost before the loop, and calls the portal at StepContext.portalOrigin.
 *
 * Does not log either. The convention here is one prefix per step, and a shared core would emit the
 * same prefix for both callers, losing which of the two wrote on a stage that runs both. The
 * response body is threaded out instead.
 */
export const applyOfferingState = async (
  context: StepContext,
  { offeringId, locked, active }: ApplyOfferingStateParams,
): Promise<OfferingStateOutcome> => {
  const { jobDoc, firebaseJwt, tokenCache, portalOrigin } = context;
  const { platform_user_id } = jobDoc;
  const pilot = String(jobDoc.jobInfo.request.pilot);

  // Type narrowing: both callers validate firebaseJwt and log the missing field before reaching
  // here, so this is unreachable in a wired pipeline.
  if (!firebaseJwt) {
    return { ok: false, bucket: PortalFailureBucket.TellTeacher };
  }

  // The write acts as a minted teacher of the offering's class, which the origin (unscoped) mint
  // already satisfies: oidc_mint resolves a no-class_id teacher mint to a teacher of the origin
  // class, and both callers' targets are inside that class. The shared per-run cache means a stage
  // running several offering-state steps mints once.
  const tokenResult = await getScopedPortalToken({
    cache: tokenCache, portalUrl: portalOrigin, firebaseToken: firebaseJwt, tokenType: "teacher", pilot,
  });
  if (!tokenResult.ok || !tokenResult.token) {
    return { ok: false, bucket: classifyPortalFailure({ status: tokenResult.status, reason: tokenResult.reason }) };
  }

  const response = await portalTokenFetch({
    portalUrl: portalOrigin,
    path: `/api/v1/offerings/${offeringId}/update_student_metadata`,
    method: "PUT",
    token: tokenResult.token,
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      locked: String(locked),
      active: String(active),
      user_id: String(platform_user_id),
    }).toString(),
  });

  if (response.status >= 200 && response.status < 300) {
    // Any 2xx succeeds regardless of body. The body is read through a guard because a 2xx with a
    // null body would otherwise raise inside the caller's try, turning a write that already landed
    // into a student-facing failure.
    const data = response.data;
    return { ok: true, returned: data ? { active: data.active, locked: data.locked } : undefined };
  }

  return {
    ok: false,
    bucket: classifyPortalFailure({ status: response.status, reason: response.data?.details?.reason }),
    status: response.status,
    data: response.data,
  };
};
