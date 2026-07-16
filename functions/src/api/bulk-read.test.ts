import bulkRead from "./bulk-read";

function mockRes() {
  const res: any = {};
  res.error = jest.fn((status: number, message: any) => { res._status = status; res._message = message; return res; });
  res.success = jest.fn((payload: any) => { res._payload = payload; return res; });
  return res;
}

async function call(body: any) {
  const res = mockRes();
  await bulkRead({ body } as any, res);
  return res;
}

const valid = {
  collection: "answers",
  source_endpoints: [],
  inner_cursor: null,
  limit: 500,
  endpoint_limit: 250,
  read_limit: 5000,
};

describe("bulkRead boundary validation", () => {
  it("400s an invalid collection", async () => {
    const res = await call({ ...valid, collection: "nope" });
    expect(res.error).toHaveBeenCalledWith(400, expect.any(String));
  });

  it("400s a non-array source_endpoints", async () => {
    const res = await call({ ...valid, source_endpoints: {} });
    expect(res._status).toBe(400);
  });

  it("400s each cap when 0, negative, or non-integer", async () => {
    for (const cap of ["limit", "endpoint_limit", "read_limit"]) {
      for (const bad of [0, -1, 1.5, "5"]) {
        const res = await call({ ...valid, [cap]: bad });
        expect(res._status).toBe(400);
      }
    }
  });

  it("400s each cap above its max", async () => {
    for (const [cap, over] of [["limit", 2001], ["endpoint_limit", 10001], ["read_limit", 100001]] as const) {
      const res = await call({ ...valid, [cap]: over });
      expect(res._status).toBe(400);
    }
  });

  it("400s malformed endpoint objects", async () => {
    const cases = [
      [{}],
      [{ source: "s" }],
      [{ source: "", remote_endpoint: "e" }],
      [{ source: "s", remote_endpoint: "e", lti_tuple: { platform_id: "p" } }],
      [{ source: "a/b", remote_endpoint: "e" }],
    ];
    for (const source_endpoints of cases) {
      const res = await call({ ...valid, source_endpoints });
      expect(res._status).toBe(400);
    }
  });

  it("passes the guard for a well-formed (empty) request", async () => {
    const res = await call(valid);
    expect(res.error).not.toHaveBeenCalled();
    expect(res.success).toHaveBeenCalled();
    expect(res._payload.items).toEqual([]);
    expect(res._payload.endpoint_exhausted).toBe(true);
  });
});
