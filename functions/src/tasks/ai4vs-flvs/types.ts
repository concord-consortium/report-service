import { IJobDocument } from "../types";
import { PortalTokenCache } from "../portal-api";

/**
 * Machine-readable handoff between pipeline steps. Unlike `summary`/`message`, which
 * send-email renders into the teacher-notification email body, `output` is never rendered
 * into any human-facing sink, so it is the only safe carrier for values a later step
 * consumes (e.g. a resolved destination class word).
 */
export interface StepOutput {
  /** Class word the enroll step should resolve and enroll into. */
  destinationClassWord?: string;
  /**
   * The student's ORIGIN class word (the class they registered in), published by
   * resolve-origin-class in the portal's stored (lowercased, trimmed) form. The fall
   * randomization step needs it twice, for the teacher stratum and to derive the destination.
   *
   * Safe to log: authored, environment-stable, neither PII nor a token.
   */
  originClassWord?: string;
  /**
   * The launch offering's class id, published by resolve-origin-class from the SAME
   * offerings#show response that yields originClassWord. send-email needs it for
   * send_class_teachers and would otherwise re-read the offering.
   *
   * ⚠️ A STRING, because readStepOutputField accepts nothing else, while resolveOriginOffering
   * types clazzId as `number | string` and the portal serves a JSON number. Publishing the raw
   * value hands back undefined and send-email falls back forever, silently, with nothing failing.
   *
   * Safe to log: a database id, neither PII nor a token.
   */
  originClazzId?: string;
}

export type StepResult = {
  success: boolean;
  message?: string;
  summary?: string;
  output?: StepOutput;
  /**
   * Set on a failure that is an ordinary student outcome rather than a fault: the student has not
   * answered enough questions yet, or skipped a demographic question the randomization needs. Nothing
   * is written, nobody is locked, and answering another question and clicking again fixes it.
   *
   * ⚠️ It governs the LOG LEVEL of index.ts's per-step failure line and nothing else. The student sees
   * the same message either way, and a step that already logs its own line (demographics.ts logs an
   * error for the skipped-question case) is unaffected. Without it every early click on an "I'm Done"
   * button would raise an error-level line, and an alert built on that volume would be measuring
   * students rather than the system.
   */
  expected?: boolean;
};

/**
 * First non-blank value of `field` across the run's step outputs.
 *
 * Record iteration is insertion order, which is pipeline order, and the invariant is one producer
 * per FIELD. Consuming steps therefore read a handoff with NO ordering guard: our own pipeline
 * wiring is assumed correct rather than checked with defensive run-time code, and a mis-ordered
 * stage fails on the first harness run. The same principle is recorded at length in
 * enroll-specified-class's header.
 *
 * enroll-specified-class keeps its own local scan rather than calling this: its version is
 * entangled with the authored-parameter precedence rule and its conflict error, so folding the two
 * together would rewrite a step this change otherwise does not touch. Deliberate, not overlooked.
 *
 * ⚠️ RELATED CONSTRAINT, on the writer rather than this reader: pipeline entry `name` values must be
 * UNIQUE within a pipeline. index.ts's `stepResults[step.name] = result` is the single writer, so
 * two entries sharing a name silently lose the first result, and send-email prints one line per key,
 * so the teacher's notification quietly loses a line too. This matters wherever one shared core is
 * reached through several named steps, as offering-state.ts is: a stage may run a lock and an open
 * together, and they must not be named alike. Nothing checks this at run time, on the standing
 * principle that our own pipeline wiring is assumed correct.
 */
export const readStepOutputField = (
  stepResults: Record<string, StepResult>,
  field: keyof StepOutput,
): string | undefined => {
  for (const result of Object.values(stepResults)) {
    const value = result.output?.[field];
    if (typeof value === "string" && value.trim()) {
      return value.trim();
    }
  }
  return undefined;
};

export interface StepContext {
  jobPath: string;
  jobDoc: IJobDocument;
  firebaseJwt?: string;
  stepResults: Record<string, StepResult>;
  tokenCache: PortalTokenCache;
  /**
   * The validated, normalized portal base URL (origin) from validatePortalHost. Steps use this for
   * outbound portal HTTP calls instead of the raw jobDoc.platform_id, which is kept only as an identity value.
   */
  portalOrigin: string;
}

export type StepHandler = (context: StepContext) => Promise<StepResult>;
