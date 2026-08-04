// A unit failure that will fail identically on every retry.
//
// The drain's cursor only advances past a unit on SUCCESS, which is what makes a deterministic
// failure at the queue HEAD block that conversation forever: each trigger re-reads the same message,
// throws the same error, and never reaches the messages queued behind it. Observed in production on
// 2026-08-04, where a client sent an activityUrl whose host is not on the AUTHORING_HOSTS allowlist;
// the conversation stayed wedged even after a corrected client sent a well-formed message, because
// the poisoned doc still sat at the head.
//
// Throwing THIS type marks a failure as "retrying cannot help", which lets processAndDrain skip the
// unit and keep draining. Everything else keeps the old behaviour and propagates, because a transient
// failure (OpenAI 5xx, cold-start timeout, network) MUST be retried rather than skipped: skipping one
// would silently swallow a student's message with no reply and no error, which is worse than a
// visible stuck state. Only throw this where the input itself is the problem.
export class PermanentUnitError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PermanentUnitError";
    // Error subclassing across the TS/ES5 target boundary breaks `instanceof` without this.
    Object.setPrototypeOf(this, PermanentUnitError.prototype);
  }
}
