import {
  reconstructTimestamp, validateAnswersCursor, validateHistoryCursor,
} from "./bulk-cursor";

const badRequest = (fn: () => void) => {
  try {
    fn();
  } catch (e: any) {
    return e && e.badRequest === true;
  }
  return false;
};

describe("reconstructTimestamp", () => {
  it("builds a Timestamp for valid fields", () => {
    const ts = reconstructTimestamp({ seconds: 1_700_000_000, nanoseconds: 133_000_000, docId: "x" });
    expect(ts.seconds).toBe(1_700_000_000);
    expect(ts.nanoseconds).toBe(133_000_000);
  });

  it("throws badRequest for a stringified seconds", () => {
    expect(badRequest(() => reconstructTimestamp({ seconds: "1" as any, nanoseconds: 0, docId: "x" }))).toBe(true);
  });

  it("throws badRequest for out-of-range nanoseconds", () => {
    expect(badRequest(() => reconstructTimestamp({ seconds: 1, nanoseconds: 1_000_000_000, docId: "x" }))).toBe(true);
    expect(badRequest(() => reconstructTimestamp({ seconds: 1, nanoseconds: -1, docId: "x" }))).toBe(true);
  });

  it("rejects out-of-range seconds (never a RangeError from new Timestamp)", () => {
    expect(badRequest(() => reconstructTimestamp({ seconds: 253_402_300_800, nanoseconds: 0, docId: "x" }))).toBe(true);
    expect(badRequest(() => reconstructTimestamp({ seconds: -62_135_596_801, nanoseconds: 0, docId: "x" }))).toBe(true);
  });

  it("accepts the in-range boundary seconds", () => {
    expect(reconstructTimestamp({ seconds: 253_402_300_799, nanoseconds: 0, docId: "x" }).seconds).toBe(253_402_300_799);
    expect(reconstructTimestamp({ seconds: -62_135_596_800, nanoseconds: 0, docId: "x" }).seconds).toBe(-62_135_596_800);
  });
});

describe("validateHistoryCursor", () => {
  it("accepts null/undefined", () => {
    expect(badRequest(() => validateHistoryCursor(null))).toBe(false);
    expect(badRequest(() => validateHistoryCursor(undefined))).toBe(false);
  });

  it("accepts a valid cursor", () => {
    expect(badRequest(() => validateHistoryCursor({ seconds: 1, nanoseconds: 0, docId: "abc" }))).toBe(false);
  });

  it("rejects out-of-range seconds", () => {
    expect(badRequest(() => validateHistoryCursor({ seconds: 253_402_300_800, nanoseconds: 0, docId: "a" }))).toBe(true);
    expect(badRequest(() => validateHistoryCursor({ seconds: -62_135_596_801, nanoseconds: 0, docId: "a" }))).toBe(true);
  });

  it("rejects a non-plain docId (slash or empty)", () => {
    expect(badRequest(() => validateHistoryCursor({ seconds: 1, nanoseconds: 0, docId: "a/b" }))).toBe(true);
    expect(badRequest(() => validateHistoryCursor({ seconds: 1, nanoseconds: 0, docId: "" }))).toBe(true);
  });
});

describe("validateAnswersCursor", () => {
  it("accepts null and a plain docId", () => {
    expect(badRequest(() => validateAnswersCursor(null))).toBe(false);
    expect(badRequest(() => validateAnswersCursor({ docId: "abc" }))).toBe(false);
  });

  it("rejects a non-plain docId (slash or empty)", () => {
    expect(badRequest(() => validateAnswersCursor({ docId: "a/b" }))).toBe(true);
    expect(badRequest(() => validateAnswersCursor({ docId: "" }))).toBe(true);
  });
});
