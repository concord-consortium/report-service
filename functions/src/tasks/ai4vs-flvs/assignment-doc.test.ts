import { createHash } from "crypto";

// Mock firebase-admin for assignment document transactions
const mockTransactionGet = jest.fn();
const mockTransactionSet = jest.fn();
const mockDocRef = { path: "mock-doc-ref" };
const mockDoc = jest.fn().mockReturnValue(mockDocRef);
const mockRunTransaction = jest.fn((fn: any) =>
  fn({ get: mockTransactionGet, set: mockTransactionSet })
);
jest.mock("firebase-admin", () => ({
  __esModule: true,
  default: {
    firestore: () => ({
      doc: (...args: any[]) => mockDoc(...args),
      runTransaction: (fn: any) => mockRunTransaction(fn),
    }),
  },
}));

// Must import after jest.mock
import {
  computeAssignmentDocId, computePooledAssignmentDocId, getAlternatingAssignment,
  perClassScope, pooledProgramScope,
} from "./assignment-doc";

describe("computeAssignmentDocId", () => {
  it("produces a deterministic hex string for the same inputs", () => {
    const id1 = computeAssignmentDocId("int-1", "https://learn.concord.org", "rl-1", "ctx-1");
    const id2 = computeAssignmentDocId("int-1", "https://learn.concord.org", "rl-1", "ctx-1");

    expect(id1).toBe(id2);
    expect(id1).toMatch(/^[a-f0-9]{64}$/);
  });

  it("produces different IDs for different inputs", () => {
    const id1 = computeAssignmentDocId("int-1", "https://learn.concord.org", "rl-1", "ctx-1");
    const id2 = computeAssignmentDocId("int-2", "https://learn.concord.org", "rl-1", "ctx-1");
    const id3 = computeAssignmentDocId("int-1", "https://learn.concord.org", "rl-1", "ctx-2");

    expect(id1).not.toBe(id2);
    expect(id1).not.toBe(id3);
    expect(id2).not.toBe(id3);
  });
});

describe("assignment scopes", () => {
  it("keeps the shipped per-class document id byte-identical", () => {
    // Pinned against a direct sha256 of the shipped input string, not against perClassScope itself,
    // so a change to the formula fails here rather than agreeing with itself.
    const expected = createHash("sha256")
      .update("ai4vs-flvs-assignments|i1|https://learn.concord.org|off-1|ctx-1")
      .digest("hex");

    expect(perClassScope("i1", "https://learn.concord.org", "off-1", "ctx-1").docId).toBe(expected);
    expect(computeAssignmentDocId("i1", "https://learn.concord.org", "off-1", "ctx-1")).toBe(expected);
  });

  it("gives the three flex sections one pooled document and three per-class documents", () => {
    const sections = [["off-1", "ctx-1"], ["off-2", "ctx-2"], ["off-3", "ctx-3"]];

    const perClass = sections.map(([o, c]) => perClassScope("green", "p1", o, c).docId);
    const pooled = sections.map(() => pooledProgramScope("fall-2026-flex", "green", "p1").docId);

    expect(new Set(perClass).size).toBe(3);
    expect(new Set(pooled).size).toBe(1);
  });

  it("separates the two programs on one shared interactiveId", () => {
    expect(pooledProgramScope("fall-2026-flex", "green", "p1").docId)
      .not.toBe(pooledProgramScope("fall-2026-full-time", "green", "p1").docId);
  });

  it("cannot be collided by per-class fields chosen to forge the pooled input", () => {
    expect(pooledProgramScope("fall-2026-flex", "green", "p1").docId)
      .not.toBe(computeAssignmentDocId("pooled", "fall-2026-flex", "green", "p1"));
    expect(pooledProgramScope("fall-2026-flex", "green", "p1").docId)
      .not.toBe(computeAssignmentDocId("green", "p1", "pooled", "fall-2026-flex"));
  });

  it("pins the pooled key format against a direct hash of its input", () => {
    // Not against the constructor, so a changed key format fails here rather than agreeing with
    // itself. The program-id half of this pin lives in fall-programs.test.ts, where the constant is
    // defined; this file must not import it, since the scopes are program-agnostic.
    const expected = createHash("sha256")
      .update("ai4vs-flvs-assignments-pooled|fall-2026-flex|green|https://learn.concord.org")
      .digest("hex");

    expect(pooledProgramScope("fall-2026-flex", "green", "https://learn.concord.org").docId).toBe(expected);
    expect(computePooledAssignmentDocId("fall-2026-flex", "green", "https://learn.concord.org")).toBe(expected);
  });

  it("records the fields each scope pools on", () => {
    expect(perClassScope("i1", "p1", "off-1", "ctx-1").fields).toEqual({
      interactiveId: "i1", platform_id: "p1", resource_link_id: "off-1", context_id: "ctx-1",
    });
    expect(pooledProgramScope("fall-2026-flex", "green", "p1").fields).toEqual({
      interactiveId: "green", platform_id: "p1", program: "fall-2026-flex",
    });
  });
});

describe("getAlternatingAssignment", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockTransactionGet.mockResolvedValue({ exists: false, data: () => undefined });
  });

  it("returns n1 assignment when document does not exist (first student)", async () => {
    const result = await getAlternatingAssignment(
      "src-1", perClassScope("int-1", "plat-1", "rl-1", "ctx-1"), "user-1", "Female|White|High|Mod1", "control"
    );

    expect(result).toBe("control");
  });

  it("returns opposite of n1 when nextAssignment is set (second student)", async () => {
    mockTransactionGet.mockResolvedValue({
      exists: true,
      data: () => ({
        strata: {
          "Female|White|High|Mod1": {
            nextAssignment: "treatment",
            users: { "user-1": "control" },
          },
        },
      }),
    });

    const result = await getAlternatingAssignment(
      "src-1", perClassScope("int-1", "plat-1", "rl-1", "ctx-1"), "user-2", "Female|White|High|Mod1", "control"
    );

    expect(result).toBe("treatment");
  });

  it("returns n1 again on third student (verifies continued alternation)", async () => {
    mockTransactionGet.mockResolvedValue({
      exists: true,
      data: () => ({
        strata: {
          "Female|White|High|Mod1": {
            nextAssignment: "control",
            users: { "user-1": "control", "user-2": "treatment" },
          },
        },
      }),
    });

    const result = await getAlternatingAssignment(
      "src-1", perClassScope("int-1", "plat-1", "rl-1", "ctx-1"), "user-3", "Female|White|High|Mod1", "control"
    );

    expect(result).toBe("control");
  });

  it("returns cached assignment without flipping nextAssignment on dedup", async () => {
    mockTransactionGet.mockResolvedValue({
      exists: true,
      data: () => ({
        strata: {
          "Female|White|High|Mod1": {
            nextAssignment: "treatment",
            users: { "user-1": "control" },
          },
        },
      }),
    });

    const result = await getAlternatingAssignment(
      "src-1", perClassScope("int-1", "plat-1", "rl-1", "ctx-1"), "user-1", "Female|White|High|Mod1", "control"
    );

    expect(result).toBe("control");
    // Should NOT have written to the document
    expect(mockTransactionSet).not.toHaveBeenCalled();
  });

  it("returns the first assignment when the student's stratum has changed", async () => {
    mockTransactionGet.mockResolvedValue({
      exists: true,
      data: () => ({
        strata: {
          "Female|White|High|Mod1": {
            nextAssignment: "control",
            users: { "user-1": "treatment" },
          },
        },
      }),
    });

    const result = await getAlternatingAssignment(
      "src-1", perClassScope("i1", "p1", "off-1", "ctx-1"), "user-1", "Female|White|High|Mod2", "control"
    );

    // Before the per-student walk the same input produced "control", a SECOND assignment under the
    // new stratum, which enrolled the student into a second class alongside the first.
    expect(result).toBe("treatment");
    expect(mockTransactionSet).not.toHaveBeenCalled();
  });

  it("creates document with correct structure on first call", async () => {
    await getAlternatingAssignment(
      "src-1", perClassScope("int-1", "plat-1", "rl-1", "ctx-1"), "user-1", "Female|White|High|Mod1", "control"
    );

    expect(mockTransactionSet).toHaveBeenCalledWith(
      mockDocRef,
      expect.objectContaining({
        type: "ai4vs-flvs-assignments",
        interactiveId: "int-1",
        platform_id: "plat-1",
        resource_link_id: "rl-1",
        context_id: "ctx-1",
        strata: {
          "Female|White|High|Mod1": {
            nextAssignment: "treatment",
            users: { "user-1": "control" },
          },
        },
      }),
      { merge: true }
    );
  });

  it("flips nextAssignment to opposite after each new assignment", async () => {
    // First student gets "treatment" (n1), nextAssignment should flip to "control"
    await getAlternatingAssignment(
      "src-1", perClassScope("int-1", "plat-1", "rl-1", "ctx-1"), "user-1", "Female|White|High|Mod2", "treatment"
    );

    expect(mockTransactionSet).toHaveBeenCalledWith(
      mockDocRef,
      expect.objectContaining({
        strata: expect.objectContaining({
          "Female|White|High|Mod2": expect.objectContaining({
            nextAssignment: "control",
          }),
        }),
      }),
      { merge: true }
    );
  });

  it("throws on transaction failure", async () => {
    mockRunTransaction.mockRejectedValueOnce(new Error("transaction failed"));

    await expect(
      getAlternatingAssignment(
        "src-1", perClassScope("int-1", "plat-1", "rl-1", "ctx-1"), "user-1", "Female|White|High|Mod1", "control"
      )
    ).rejects.toThrow("transaction failed");
  });
});
