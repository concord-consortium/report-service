// structured-output parsing + the tutor_reply json_schema contract.
import { parseTutorReply, TUTOR_REPLY_FORMAT } from "./openai";

describe("parseTutorReply", () => {
  it("reads a string userText", () => {
    expect(parseTutorReply('{"userText":"try re-reading the passage"}'))
      .toEqual({ userText: "try re-reading the passage" });
  });

  it("reads a null userText (routine log → render nothing)", () => {
    expect(parseTutorReply('{"userText":null}')).toEqual({ userText: null });
  });

  it("coerces a missing userText to null", () => {
    expect(parseTutorReply("{}")).toEqual({ userText: null });
  });

  it("coerces a non-string userText to null", () => {
    expect(parseTutorReply('{"userText":42}')).toEqual({ userText: null });
  });

  it("throws on invalid JSON (caught upstream → status:error, replay covers content)", () => {
    expect(() => parseTutorReply("not json")).toThrow();
  });
});

describe("TUTOR_REPLY_FORMAT", () => {
  it("is a strict json_schema with a nullable userText", () => {
    expect(TUTOR_REPLY_FORMAT.type).toBe("json_schema");
    expect(TUTOR_REPLY_FORMAT.strict).toBe(true);
    expect(TUTOR_REPLY_FORMAT.schema.additionalProperties).toBe(false);
    expect(TUTOR_REPLY_FORMAT.schema.required).toEqual(["userText"]);
    expect(TUTOR_REPLY_FORMAT.schema.properties.userText.type).toEqual(["string", "null"]);
  });
});
