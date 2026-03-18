import * as functions from "firebase-functions";
import { collection, query, where, getDocs } from "firebase/firestore";
import { createHash } from "crypto";
import admin from "firebase-admin";
import { StepContext, StepResult } from "./types";
import { getClientFirestore } from "../../firebase-client";
import { portalOidcFetch } from "../portal-api";

// --- Baked-in constants ---

const STUDENT_FAILURE_MESSAGE =
  "Unable to complete your assignment. Please try again or contact your teacher.";

/** Prompt substrings used to identify demographic answer docs. */
const DIMENSIONS = ["Gender", "Grade", "Module", "Race"] as const;
type Dimension = typeof DIMENSIONS[number];

interface DimensionConfig {
  promptSubstring: string;
}

const DIMENSION_CONFIGS: Record<Dimension, DimensionConfig> = {
  Gender: { promptSubstring: "your sex" },
  Grade:  { promptSubstring: "grade are you in" },
  Module: { promptSubstring: "Algebra 1 module" },
  Race:   { promptSubstring: "race or ethnicity" },
};

/** Choice content text → category mappings. Exact match after trim. */
const GENDER_MAP: Record<string, string> = {
  "Female": "Female",
  "Male": "Male",
  "Prefer not to answer": "Female",
};

const GRADE_MAP: Record<string, string> = {
  "9th Grade": "High",
  "10th Grade": "High",
  "11th Grade": "High",
  "12th Grade": "High",
  "6th Grade": "Mid",
  "7th Grade": "Mid",
  "8th Grade": "Mid",
  "Other": "Mid",
};

/** Module uses default fallback: Mod1 and Mod2 are explicit, everything else → Other. */
const MODULE_MOD1 = "Module 1: One-Variable Equations and Inequalities";
const MODULE_MOD2 = "Module 2: Two-Variable Linear Functions";

/** Race binary reduction constant. */
const RACE_WHITE = "White";

/** Class names (baked in). Portal class IDs come from request params. */
const CLASS_NAMES: Record<string, string> = {
  treatment: "FL-spring-2026-GATOR",
  control: "FL-spring-2026-SHARK",
};

/**
 * Assignment table — all 24 strata.
 * Key format: "Gender|Race|Grade|Module" → "treatment" | "control"
 */
const ASSIGNMENT_TABLE: Record<string, "treatment" | "control"> = {
  "Female|White|High|Mod2": "treatment",
  "Male|non-White|High|Mod2": "control",
  "Male|White|Mid|Mod2": "treatment",
  "Female|White|High|Mod1": "control",
  "Female|White|Mid|Mod1": "treatment",
  "Female|non-White|High|Mod1": "control",
  "Male|White|High|Mod2": "treatment",
  "Female|White|Mid|Other": "control",
  "Male|non-White|High|Mod1": "treatment",
  "Female|White|Mid|Mod2": "control",
  "Female|non-White|High|Mod2": "treatment",
  "Female|White|High|Other": "control",
  "Female|non-White|High|Other": "treatment",
  "Male|White|High|Other": "control",
  "Female|non-White|Mid|Mod2": "treatment",
  "Male|non-White|High|Other": "control",
  "Male|White|Mid|Other": "treatment",
  "Male|non-White|Mid|Other": "control",
  "Female|non-White|Mid|Other": "treatment",
  "Male|non-White|Mid|Mod2": "control",
  "Male|White|Mid|Mod1": "treatment",
  "Male|White|High|Mod1": "control",
  "Female|non-White|Mid|Mod1": "treatment",
  "Male|non-White|Mid|Mod1": "control",
};

// --- Helper functions ---

/**
 * Parse report_state JSON string → { authoredState, interactiveState }.
 * authoredState and interactiveState are themselves JSON strings that get parsed.
 */
const parseReportState = (reportState: string) => {
  let parsed: any;
  try {
    parsed = JSON.parse(reportState);
  } catch (e) {
    throw new Error(`Failed to parse report_state as JSON: ${(e as Error).message}`);
  }

  let authoredState: any;
  try {
    authoredState = JSON.parse(parsed.authoredState);
  } catch (e) {
    throw new Error(`Failed to parse report_state.authoredState as JSON: ${(e as Error).message}`);
  }

  let interactiveState: any;
  try {
    interactiveState = JSON.parse(parsed.interactiveState);
  } catch (e) {
    throw new Error(`Failed to parse report_state.interactiveState as JSON: ${(e as Error).message}`);
  }

  return { authoredState, interactiveState };
};

/**
 * Find the answer doc matching a prompt substring.
 * Returns the parsed authoredState and interactiveState.
 * Fails if zero or multiple docs match.
 */
const findAnswerByPrompt = (
  answerDocs: Array<{ data: any }>,
  dimension: Dimension,
): { authoredState: any; interactiveState: any } => {
  const substring = DIMENSION_CONFIGS[dimension].promptSubstring;
  const matches: Array<{ authoredState: any; interactiveState: any }> = [];

  for (const doc of answerDocs) {
    try {
      const parsed = parseReportState(doc.data.report_state);
      if (parsed.authoredState.prompt?.toLowerCase().includes(substring.toLowerCase())) {
        matches.push(parsed);
      }
    } catch (err) {
      // Skip docs with unparseable report_state, but log for debugging
      functions.logger.warn(`random-assignment: skipping answer doc with unparseable report_state`, err);
    }
  }

  if (matches.length === 0) {
    const err = new Error(`No answer doc found for ${dimension} (prompt substring: "${substring}")`);
    (err as any).isMissingAnswer = true;
    throw err;
  }
  if (matches.length > 1) {
    throw new Error(`Multiple answer docs (${matches.length}) matched ${dimension} (prompt substring: "${substring}")`);
  }

  return matches[0];
};

/**
 * Resolve selectedChoiceIds to content text via authoredState.choices.
 */
const resolveChoices = (
  authoredState: any,
  interactiveState: any,
  dimension: Dimension,
): string[] => {
  const selectedIds: string[] = interactiveState.selectedChoiceIds || [];
  if (selectedIds.length === 0) {
    const err = new Error(`Empty selectedChoiceIds for ${dimension}`);
    (err as any).isMissingAnswer = true;
    throw err;
  }

  const choices: Array<{ id: string; content: string }> = authoredState.choices || [];
  return selectedIds.map(id => {
    const choice = choices.find(c => c.id === id);
    if (!choice) {
      throw new Error(`Choice ID "${id}" not found in authoredState.choices for ${dimension}`);
    }
    return choice.content.trim();
  });
};

/**
 * Map resolved choice content text to a category for the given dimension.
 */
const mapToCategory = (dimension: Dimension, choiceTexts: string[]): string => {
  switch (dimension) {
    case "Gender": {
      const text = choiceTexts[0];
      const category = GENDER_MAP[text];
      if (!category) {
        throw new Error(`Unmapped Gender choice: "${text}"`);
      }
      return category;
    }
    case "Grade": {
      const text = choiceTexts[0];
      const category = GRADE_MAP[text];
      if (!category) {
        throw new Error(`Unmapped Grade choice: "${text}"`);
      }
      return category;
    }
    case "Module": {
      // Default fallback: anything not Mod1 or Mod2 → Other
      const text = choiceTexts[0];
      if (text === MODULE_MOD1) return "Mod1";
      if (text === MODULE_MOD2) return "Mod2";
      return "Other";
    }
    case "Race": {
      // Binary reduction: only-White → White, otherwise → non-White
      const hasOnlyWhite = choiceTexts.length === 1 && choiceTexts[0] === RACE_WHITE;
      return hasOnlyWhite ? "White" : "non-White";
    }
  }
};

// --- Assignment document helpers ---

export const computeAssignmentDocId = (
  interactiveId: string,
  platform_id: string,
  resource_link_id: string,
  context_id: string,
): string => {
  const input = `ai4vs-flvs-assignments|${interactiveId}|${platform_id}|${resource_link_id}|${context_id}`;
  return createHash("sha256").update(input).digest("hex");
};

export const getAlternatingAssignment = async (
  source_key: string,
  interactiveId: string,
  platform_id: string,
  resource_link_id: string,
  context_id: string,
  platform_user_id: string,
  stratumKey: string,
  n1Assignment: "treatment" | "control",
): Promise<"treatment" | "control"> => {
  const db = admin.firestore();
  const docId = computeAssignmentDocId(interactiveId, platform_id, resource_link_id, context_id);
  const docRef = db.doc(`sources/${source_key}/jobs-task-data/${docId}`);

  return db.runTransaction(async (tx) => {
    const doc = await tx.get(docRef);
    const data = doc.data() || {};
    const strata = data.strata || {};
    const stratum = strata[stratumKey] || {};
    const users = stratum.users || {};

    // Dedup: if user already assigned, return cached assignment
    if (users[platform_user_id]) {
      return users[platform_user_id] as "treatment" | "control";
    }

    // Determine assignment: use nextAssignment if set, otherwise n1
    const assignment: "treatment" | "control" = stratum.nextAssignment || n1Assignment;
    const opposite: "treatment" | "control" = assignment === "treatment" ? "control" : "treatment";

    // Write back
    tx.set(docRef, {
      type: "ai4vs-flvs-assignments",
      interactiveId,
      platform_id,
      resource_link_id,
      context_id,
      strata: {
        ...strata,
        [stratumKey]: {
          nextAssignment: opposite,
          users: { ...users, [platform_user_id]: assignment },
        },
      },
    }, { merge: true });

    return assignment;
  });
};

// --- Main step function ---

export const randomAssignment = async ({
  jobPath,
  jobDoc,
  firebaseJwt,
}: StepContext): Promise<StepResult> => {
  // Validate request parameters first
  const { request } = jobDoc.jobInfo;
  const treatmentClassId = String(request.treatment_class_id ?? "").trim();
  const controlClassId = String(request.control_class_id ?? "").trim();

  if (!treatmentClassId || !controlClassId) {
    const missing = [
      !treatmentClassId && "treatment_class_id",
      !controlClassId && "control_class_id",
    ].filter(Boolean).join(", ");
    functions.logger.error(`random-assignment: missing required request parameters: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  if (!firebaseJwt) {
    functions.logger.error(`random-assignment: missing Firebase JWT for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  const { source_key, platform_user_id, platform_id, resource_link_id, context_id, interactiveId } = jobDoc;

  if (!source_key || !platform_user_id || !platform_id || !resource_link_id || !context_id || !interactiveId) {
    const missing = [
      !source_key && "source_key",
      !platform_user_id && "platform_user_id",
      !platform_id && "platform_id",
      !resource_link_id && "resource_link_id",
      !context_id && "context_id",
      !interactiveId && "interactiveId",
    ].filter(Boolean).join(", ");
    functions.logger.error(`random-assignment: missing required context fields: ${missing} for ${jobPath}`);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  }

  // Query Firestore for answer docs
  let firestoreCleanup: (() => Promise<void>) | undefined;
  try {
    const { firestore, cleanup } = await getClientFirestore(firebaseJwt);
    firestoreCleanup = cleanup;

    const answersRef = collection(firestore, `sources/${source_key}/answers`);
    const q = query(
      answersRef,
      where("platform_id", "==", platform_id),
      where("resource_link_id", "==", resource_link_id),
      where("context_id", "==", context_id),
      where("platform_user_id", "==", platform_user_id),
    );
    const snapshot = await getDocs(q);
    const answerDocs = snapshot.docs.map(doc => ({ data: doc.data() }));

    // Match prompt substrings and resolve categories
    const categories: Record<Dimension, string> = {} as any;
    const missingDimensions: Dimension[] = [];

    for (const dim of DIMENSIONS) {
      try {
        const { authoredState, interactiveState } = findAnswerByPrompt(answerDocs, dim);
        const choiceTexts = resolveChoices(authoredState, interactiveState, dim);
        categories[dim] = mapToCategory(dim, choiceTexts);
      } catch (error: any) {
        // Distinguish missing/empty answer errors from mapping errors
        if (error.isMissingAnswer) {
          missingDimensions.push(dim);
        } else {
          // Mapping error or other error — log details, return student-friendly message
          functions.logger.error(`random-assignment: ${error.message} for ${jobPath}`);
          return { success: false, message: STUDENT_FAILURE_MESSAGE };
        }
      }
    }

    // Report missing/incomplete answers
    if (missingDimensions.length > 0) {
      const names = missingDimensions.join(", ");
      functions.logger.error(
        `random-assignment: missing or incomplete answers for ${names} for user ${platform_user_id} at ${jobPath}`
      );
      return {
        success: false,
        message: `Please complete the following question(s) before continuing: ${names}.`,
      };
    }

    // Look up assignment
    const stratumKey = `${categories.Gender}|${categories.Race}|${categories.Grade}|${categories.Module}`;
    const n1Assignment = ASSIGNMENT_TABLE[stratumKey];
    if (!n1Assignment) {
      functions.logger.error(
        `random-assignment: no matching stratum for ${stratumKey} for user ${platform_user_id} at ${jobPath}`
      );
      return { success: false, message: STUDENT_FAILURE_MESSAGE };
    }

    const assignment = await getAlternatingAssignment(
      source_key, String(interactiveId), String(platform_id),
      String(resource_link_id), String(context_id),
      String(platform_user_id), stratumKey, n1Assignment,
    );

    const className = CLASS_NAMES[assignment];
    const classId = assignment === "treatment" ? treatmentClassId : controlClassId;

    // Enroll in Portal class
    functions.logger.info(
      `random-assignment: enrolling user ${platform_user_id} in class ${className} (${classId}) at ${platform_id} (${jobPath})`
    );

    const response = await portalOidcFetch({
      portalUrl: platform_id,
      path: "/api/v1/students/add_to_class",
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        user_id: String(platform_user_id),
        clazz_id: String(classId),
      }),
    });

    if (response.status >= 200 && response.status < 300 && response.data?.success === true) {
      functions.logger.info(
        `random-assignment: successfully enrolled user ${platform_user_id} in ${className} (${jobPath})`
      );
      return { success: true, summary: `Assigned to ${className}` };
    }

    // Portal returned non-success
    functions.logger.error(
      `random-assignment: Portal enrollment failed for ${jobPath}`,
      { status: response.status, data: response.data }
    );
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  } catch (error) {
    functions.logger.error(`random-assignment: unexpected error for ${jobPath}`, error);
    return { success: false, message: STUDENT_FAILURE_MESSAGE };
  } finally {
    try {
      if (firestoreCleanup) {
        await firestoreCleanup();
      }
    } catch (cleanupErr) {
      functions.logger.warn("random-assignment: cleanup failed", cleanupErr);
    }
  }
};
