import admin from "firebase-admin";

const { Timestamp } = admin.firestore;

// Answers inner cursor: { docId }. History inner cursor: { seconds, nanoseconds, docId }.
export type AnswersCursor = { docId: string };
export type HistoryCursor = { seconds: number; nanoseconds: number; docId: string };

const isInt = (n: unknown): n is number => typeof n === "number" && Number.isInteger(n);

// Firestore Timestamp valid range (0001-01-01T00:00:00Z .. 9999-12-31T23:59:59Z). `new Timestamp(s, _)`
// with out-of-range seconds throws a RangeError, which is not a badRequest error and would surface as an
// uncaught 500 — so an integer-but-out-of-range seconds must be rejected as BAD_REQUEST before construction.
const TS_MIN_SECONDS = -62_135_596_800;
const TS_MAX_SECONDS = 253_402_300_799;
const isValidTsSeconds = (s: unknown): s is number => isInt(s) && s >= TS_MIN_SECONDS && s <= TS_MAX_SECONDS;

// A Firestore cursor docId must be a PLAIN document id: non-empty and no "/". startAfter(...) on a
// documentId ordering throws synchronously otherwise.
const isPlainDocId = (v: unknown): v is string => typeof v === "string" && v.length > 0 && !v.includes("/");

// Returns a Firestore Timestamp or throws a typed error the handler maps to BAD_REQUEST (never an uncaught 500).
export function reconstructTimestamp(c: HistoryCursor) {
  if (!isValidTsSeconds(c.seconds) || !isInt(c.nanoseconds) || c.nanoseconds < 0 || c.nanoseconds > 999_999_999) {
    const e: any = new Error("inner_cursor has invalid Timestamp fields");
    e.badRequest = true;
    throw e;
  }
  return new Timestamp(c.seconds, c.nanoseconds);
}

export function validateHistoryCursor(c: unknown): asserts c is HistoryCursor | null {
  if (c === null || c === undefined) { return; }
  const o = c as any;
  if (!isValidTsSeconds(o.seconds) || !isInt(o.nanoseconds) || o.nanoseconds < 0 || o.nanoseconds > 999_999_999 ||
      !isPlainDocId(o.docId)) {
    const e: any = new Error("malformed history inner_cursor");
    e.badRequest = true;
    throw e;
  }
}

export function validateAnswersCursor(c: unknown): asserts c is AnswersCursor | null {
  if (c === null || c === undefined) { return; }
  if (!isPlainDocId((c as any).docId)) {
    const e: any = new Error("malformed answers inner_cursor");
    e.badRequest = true;
    throw e;
  }
}
