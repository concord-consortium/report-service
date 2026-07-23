import { clearFirestore } from "../test/emulator-setup";
import { seedAnswer, seedHistory } from "../test/seed-helpers";
import fetchAttachmentMeta from "./attachment-meta";

const SOURCE = "example.com";
const LTI = { platform_id: "p1", platform_user_id: "u1", resource_link_id: "r1" };

function mockRes() {
  const res: any = {};
  res.error = jest.fn((s: number, m: any) => { res._status = s; res._message = m; return res; });
  res.success = jest.fn((p: any) => { res._payload = p; return res; });
  return res;
}

const call = async (items: any) => {
  const res = mockRes();
  await fetchAttachmentMeta({ body: { items } } as any, res);
  return res;
};

const attachments = (name: string, publicPath: string | null, contentType = "application/json") => ({
  [name]: publicPath === null ? { contentType } : { publicPath, contentType, folder: { id: "f", ownerId: "re-1" } },
});

beforeEach(async () => { await clearFirestore(); });

it("returns authoritative meta for an answer doc's attachment", async () => {
  await seedAnswer({
    ...LTI, source: SOURCE, remote_endpoint: "re-1", question_id: "q1", answer_id: "d1",
    extra: { attachments: attachments("file.json", "interactive-attachments/f/u/file.json", "application/json") },
  });

  const res = await call([{ collection: "answers", source: SOURCE, doc_id: "d1", name: "file.json" }]);
  expect(res._payload.results).toEqual([
    { doc_id: "d1", name: "file.json", meta: { publicPath: "interactive-attachments/f/u/file.json", contentType: "application/json", remote_endpoint: "re-1" } },
  ]);
});

it("resolves an attachment on a history state doc", async () => {
  await seedHistory({
    ...LTI, source: SOURCE, remote_endpoint: "re-1", question_id: "q1", answer_id: "a1", history_id: "h1",
    created_at: { seconds: 1000, nanoseconds: 0 },
    extra: { attachments: attachments("audio.mp3", "interactive-attachments/f/u/audio.mp3", "audio/mpeg") },
  });

  const res = await call([{ collection: "history", source: SOURCE, doc_id: "h1", name: "audio.mp3" }]);
  expect(res._payload.results[0].meta).toEqual({
    publicPath: "interactive-attachments/f/u/audio.mp3", contentType: "audio/mpeg", remote_endpoint: "re-1",
  });
});

it("returns meta: null for a missing name", async () => {
  await seedAnswer({
    ...LTI, source: SOURCE, remote_endpoint: "re-1", question_id: "q1", answer_id: "d1",
    extra: { attachments: attachments("file.json", "interactive-attachments/f/u/file.json") },
  });

  const res = await call([{ collection: "answers", source: SOURCE, doc_id: "d1", name: "absent.json" }]);
  expect(res._payload.results[0].meta).toBeNull();
});

it("returns meta: null when attachments[name] has no publicPath", async () => {
  await seedAnswer({
    ...LTI, source: SOURCE, remote_endpoint: "re-1", question_id: "q1", answer_id: "d1",
    extra: { attachments: attachments("file.json", null) },
  });

  const res = await call([{ collection: "answers", source: SOURCE, doc_id: "d1", name: "file.json" }]);
  expect(res._payload.results[0].meta).toBeNull();
});

it("returns meta: null for a missing doc", async () => {
  const res = await call([{ collection: "answers", source: SOURCE, doc_id: "nope", name: "file.json" }]);
  expect(res._payload.results[0].meta).toBeNull();
});

it("400s a '/' in source or doc_id", async () => {
  expect((await call([{ collection: "answers", source: "a/b", doc_id: "d1", name: "f" }]))._status).toBe(400);
  expect((await call([{ collection: "answers", source: "s", doc_id: "a/b", name: "f" }]))._status).toBe(400);
});

it("400s more than 500 items", async () => {
  const items = Array.from({ length: 501 }, (_, i) => ({ collection: "answers", source: SOURCE, doc_id: `d${i}`, name: "f" }));
  expect((await call(items))._status).toBe(400);
});
