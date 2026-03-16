import { answerIsCompleted } from "./answer-utils";

describe("answerIsCompleted", () => {
  describe("multiple_choice_answer", () => {
    it("returns true when choice_ids is non-empty", () => {
      expect(answerIsCompleted({
        type: "multiple_choice_answer",
        answer: { choice_ids: ["a"] },
      })).toBe(true);
    });

    it("returns false when choice_ids is empty", () => {
      expect(answerIsCompleted({
        type: "multiple_choice_answer",
        answer: { choice_ids: [] },
      })).toBe(false);
    });

    it("returns false when answer is missing", () => {
      expect(answerIsCompleted({
        type: "multiple_choice_answer",
      })).toBe(false);
    });
  });

  describe("open_response_answer", () => {
    it("returns true for non-empty string", () => {
      expect(answerIsCompleted({
        type: "open_response_answer",
        answer: "hello",
      })).toBe(true);
    });

    it("returns false for empty string", () => {
      expect(answerIsCompleted({
        type: "open_response_answer",
        answer: "",
      })).toBe(false);
    });

    it("returns false for whitespace-only string", () => {
      expect(answerIsCompleted({
        type: "open_response_answer",
        answer: "   ",
      })).toBe(false);
    });
  });

  describe("image_question_answer", () => {
    it("returns true when image_url is non-empty", () => {
      expect(answerIsCompleted({
        type: "image_question_answer",
        answer: { image_url: "https://example.com/img.png", text: "" },
      })).toBe(true);
    });

    it("returns true when text is non-empty", () => {
      expect(answerIsCompleted({
        type: "image_question_answer",
        answer: { image_url: "", text: "description" },
      })).toBe(true);
    });

    it("returns false when both are empty", () => {
      expect(answerIsCompleted({
        type: "image_question_answer",
        answer: { image_url: "", text: "" },
      })).toBe(false);
    });
  });

  describe("interactive_state", () => {
    const withReportState = (interactiveState: any) => ({
      type: "interactive_state",
      answer: "ignored",
      report_state: JSON.stringify({
        interactiveState: JSON.stringify(interactiveState),
      }),
    });

    it("returns true when interactiveState has keys", () => {
      expect(answerIsCompleted(withReportState({ foo: "bar" }))).toBe(true);
    });

    it("returns false when interactiveState is empty object", () => {
      expect(answerIsCompleted(withReportState({}))).toBe(false);
    });

    it("returns false when interactiveState is null", () => {
      expect(answerIsCompleted(withReportState(null))).toBe(false);
    });

    it("returns false when interactiveState is an array", () => {
      expect(answerIsCompleted(withReportState(["a", "b"]))).toBe(false);
    });

    it("returns false when report_state is missing", () => {
      expect(answerIsCompleted({ type: "interactive_state" })).toBe(false);
    });

    it("returns false when report_state is malformed JSON", () => {
      expect(answerIsCompleted({
        type: "interactive_state",
        report_state: "not json",
      })).toBe(false);
    });
  });

  describe("attachments override", () => {
    it("returns true for any type with non-empty attachments", () => {
      expect(answerIsCompleted({
        type: "interactive_state",
        attachments: { "att-1": { publicUrl: "https://..." } },
      })).toBe(true);
    });

    it("returns false for empty attachments map", () => {
      expect(answerIsCompleted({
        type: "interactive_state",
        attachments: {},
      })).toBe(false);
    });

    it("returns false when attachments is an array", () => {
      expect(answerIsCompleted({
        type: "interactive_state",
        attachments: ["x"],
      })).toBe(false);
    });
  });

  describe("unknown type", () => {
    it("returns false for unknown type", () => {
      expect(answerIsCompleted({ type: "something_new", answer: "data" })).toBe(false);
    });

    it("returns false when type is missing", () => {
      expect(answerIsCompleted({ answer: "data" })).toBe(false);
    });
  });
});
