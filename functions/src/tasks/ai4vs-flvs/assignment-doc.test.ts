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
import { computeAssignmentDocId, getAlternatingAssignment } from "./assignment-doc";

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

describe("getAlternatingAssignment", () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockTransactionGet.mockResolvedValue({ exists: false, data: () => undefined });
  });

  it("returns n1 assignment when document does not exist (first student)", async () => {
    const result = await getAlternatingAssignment(
      "src-1", "int-1", "plat-1", "rl-1", "ctx-1", "user-1", "Female|White|High|Mod1", "control"
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
      "src-1", "int-1", "plat-1", "rl-1", "ctx-1", "user-2", "Female|White|High|Mod1", "control"
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
      "src-1", "int-1", "plat-1", "rl-1", "ctx-1", "user-3", "Female|White|High|Mod1", "control"
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
      "src-1", "int-1", "plat-1", "rl-1", "ctx-1", "user-1", "Female|White|High|Mod1", "control"
    );

    expect(result).toBe("control");
    // Should NOT have written to the document
    expect(mockTransactionSet).not.toHaveBeenCalled();
  });

  it("creates document with correct structure on first call", async () => {
    await getAlternatingAssignment(
      "src-1", "int-1", "plat-1", "rl-1", "ctx-1", "user-1", "Female|White|High|Mod1", "control"
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
      "src-1", "int-1", "plat-1", "rl-1", "ctx-1", "user-1", "Female|White|High|Mod2", "treatment"
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
        "src-1", "int-1", "plat-1", "rl-1", "ctx-1", "user-1", "Female|White|High|Mod1", "control"
      )
    ).rejects.toThrow("transaction failed");
  });
});
