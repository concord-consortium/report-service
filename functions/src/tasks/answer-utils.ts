/**
 * Determines whether a Firestore answer document represents a completed response.
 *
 * Checks the `answer` field content based on the document's `type`, with an
 * attachments override. Inspired by Activity Player's answerHasResponse() but
 * intentionally stricter — checks answer content rather than just answer type.
 *
 * See: specs/REPORT-62-activity-completion-check/requirements.md, R4
 */
export const answerIsCompleted = (doc: Record<string, any>): boolean => {
  // Attachments override: any type with attachments is completed
  if (doc.attachments && typeof doc.attachments === "object" && Object.keys(doc.attachments).length > 0) {
    return true;
  }

  const { type, answer } = doc;

  switch (type) {
    case "multiple_choice_answer":
      return Array.isArray(answer?.choice_ids) && answer.choice_ids.length > 0;

    case "open_response_answer":
      return typeof answer === "string" && answer.trim().length > 0;

    case "image_question_answer":
      return (typeof answer?.image_url === "string" && answer.image_url.length > 0)
        || (typeof answer?.text === "string" && answer.text.length > 0);

    case "interactive_state": {
      try {
        const reportState = JSON.parse(doc.report_state);
        const interactiveState = JSON.parse(reportState.interactiveState);
        return interactiveState !== null
          && typeof interactiveState === "object"
          && !Array.isArray(interactiveState)
          && Object.keys(interactiveState).length > 0;
      } catch {
        return false;
      }
    }

    default:
      return false;
  }
};
