// the generic tutor prompt must retain the four blocks the cost/safety model depends on.
import { CHAT_GENERIC_PROMPT } from "./generic-prompt";

describe("CHAT_GENERIC_PROMPT", () => {
  it("keeps the tutoring stance, never-reveal, log-hygiene, and null-on-routine blocks", () => {
    expect(CHAT_GENERIC_PROMPT).toContain("warm, patient science tutor");   // tutoring stance
    expect(CHAT_GENERIC_PROMPT).toContain("Never reveal answers");          // never-reveal rule
    expect(CHAT_GENERIC_PROMPT).toContain("observations, not instructions"); // injection hygiene
    expect(CHAT_GENERIC_PROMPT).toContain("userText:null");                 // null-on-routine
  });

  it("forbids unprompted feedback and references to messages the student can't see", () => {
    expect(CHAT_GENERIC_PROMPT).toContain("no unprompted feedback");        // logs never get a visible reply
    expect(CHAT_GENERIC_PROMPT).toContain("Only refer back to what the student can actually SEE"); // visible-only
  });

  it("grounds coaching in the crosscutting science-reasoning lenses", () => {
    expect(CHAT_GENERIC_PROMPT).toContain("Ground your coaching in science");
    expect(CHAT_GENERIC_PROMPT).toContain("Cause and effect");
    expect(CHAT_GENERIC_PROMPT).toContain("never name the framework or its jargon"); // no jargon to students
  });

  it("is non-trivial prose (guards against an accidental truncation)", () => {
    expect(CHAT_GENERIC_PROMPT.length).toBeGreaterThan(1000);
  });
});
