import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { apiFetch, chunk, concat, connectedPair, Device, makePng, rawFetch, textChunk } from "./helpers";

describe("image upload requires a connected line", () => {
  it("is rejected with 403 line_not_connected while the line is delivered (even with a valid PNG)", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("hello");
    const png = await makePng();

    // 发起人、收件人都不行
    for (const who of [a, b]) {
      const res = await who.image(sent.body.line.id, png);
      expect(res.status).toBe(403);
      expect(res.body.error.code).toBe("line_not_connected");
    }
    const { n } = (await env.DB.prepare("SELECT COUNT(*) AS n FROM messages WHERE kind = 'image'").first<{ n: number }>())!;
    expect(n).toBe(0);
    expect((await env.IMAGES.list()).objects).toHaveLength(0);
  });

  it("is rejected while the line is queued", async () => {
    const a = await Device.create();
    const sent = await a.fax("hello");
    expect(sent.body.line.state).toBe("queued");
    const res = await a.image(sent.body.line.id, await makePng());
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("line_not_connected");
  });

  it("is rejected after the line is closed", async () => {
    const { a, b, lineId } = await connectedPair();
    await b.tear(lineId);
    const res = await a.image(lineId, await makePng());
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("line_not_connected");
  });

  it("is accepted once the recipient has replied, and returns the image metadata", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("hello");
    const lineId: string = sent.body.line.id;
    expect((await a.image(lineId, await makePng())).status).toBe(403);

    expect((await b.say(lineId, "hi")).body.line.state).toBe("connected");

    const png = await makePng({ width: 384, height: 512 });
    const res = await a.image(lineId, png);
    expect(res.status).toBe(201);
    expect(res.body.line).toMatchObject({ id: lineId, state: "connected", role: "initiator" });
    expect(res.body.message).toMatchObject({ lineId, from: "me", kind: "image", width: 384, height: 512 });
    expect(typeof res.body.message.imageId).toBe("string");
    expect(res.body.message.text).toBeUndefined();

    // 收件人也能发图
    const back = await b.image(lineId, await makePng({ width: 100, height: 40 }));
    expect(back.status).toBe(201);
    expect(back.body.message).toMatchObject({ width: 100, height: 40 });
  });

  it("returns not_found for non-participants", async () => {
    const { lineId } = await connectedPair();
    const outsider = await Device.create();
    const res = await outsider.image(lineId, await makePng());
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe("not_found");
  });
});

describe("PNG validation", () => {
  let pair: Awaited<ReturnType<typeof connectedPair>>;
  beforeEach(async () => {
    pair = await connectedPair();
  });

  async function expectInvalid(bytes: Uint8Array, contentType = "image/png") {
    const res = await pair.a.image(pair.lineId, bytes, contentType);
    expect(res.status, JSON.stringify(res.body)).toBe(400);
    expect(res.body.error.code).toBe("invalid_image");
    // 被拒绝的图片不落库、不进 R2
    expect((await env.IMAGES.list()).objects).toHaveLength(0);
    const { n } = (await env.DB.prepare("SELECT COUNT(*) AS n FROM messages WHERE kind = 'image'").first<{ n: number }>())!;
    expect(n).toBe(0);
  }

  async function expectValid(bytes: Uint8Array) {
    const res = await pair.a.image(pair.lineId, bytes);
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    return res;
  }

  it("accepts boundary sizes: 384 x 768, 1 x 1", async () => {
    const big = await expectValid(await makePng({ width: 384, height: 768 }));
    expect(big.body.message).toMatchObject({ width: 384, height: 768 });
    await expectValid(await makePng({ width: 1, height: 1 }));
  });

  it("rejects non-PNG data", async () => {
    await expectInvalid(new TextEncoder().encode("definitely not a png, just some text that is long enough to pass length checks"));
    await expectInvalid(new Uint8Array(0));
    await expectInvalid(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])); // 只有签名
    // JPEG 头
    await expectInvalid(new Uint8Array([0xff, 0xd8, 0xff, 0xe0, ...new Array(200).fill(0)]));
  });

  it("rejects a PNG signature followed by garbage", async () => {
    const png = await makePng();
    await expectInvalid(concat(png.subarray(0, 8), new Uint8Array(200).fill(7)));
  });

  it("rejects truncated PNGs", async () => {
    const png = await makePng();
    await expectInvalid(png.subarray(0, png.length - 5)); // 缺 IEND 尾部
    await expectInvalid(png.subarray(0, 40)); // 截在 IHDR 之后
  });

  it("rejects a PNG without IEND or with trailing data", async () => {
    await expectInvalid(await makePng({ omitIend: true }));
    await expectInvalid(await makePng({ trailing: new Uint8Array([1, 2, 3]) }));
  });

  it("rejects wrong colour type (RGB, RGBA, palette, gray+alpha)", async () => {
    await expectInvalid(await makePng({ colorType: 2, bitDepth: 8 }));
    await expectInvalid(await makePng({ colorType: 6, bitDepth: 8 }));
    await expectInvalid(await makePng({ colorType: 3, bitDepth: 1 }));
    await expectInvalid(await makePng({ colorType: 4, bitDepth: 8 }));
  });

  it("rejects wrong bit depth (gray 2/4/8/16 bit)", async () => {
    for (const bitDepth of [2, 4, 8, 16]) await expectInvalid(await makePng({ bitDepth }));
  });

  it("rejects images that are too wide or too tall", async () => {
    await expectInvalid(await makePng({ width: 385, height: 10 }));
    await expectInvalid(await makePng({ width: 800, height: 10 }));
    await expectInvalid(await makePng({ width: 10, height: 769 }));
  });

  it("rejects zero-size images", async () => {
    await expectInvalid(await makePng({ width: 0, height: 10 }));
    await expectInvalid(await makePng({ width: 10, height: 0 }));
  });

  it("rejects a corrupted IHDR CRC", async () => {
    await expectInvalid(await makePng({ badIhdrCrc: true }));
  });

  it("rejects files larger than 64 KB (even if otherwise a valid 1-bit PNG)", async () => {
    const padded = await makePng({ extraChunks: [textChunk(66 * 1024)] });
    expect(padded.length).toBeGreaterThan(64 * 1024);
    await expectInvalid(padded);
    await expectInvalid(new Uint8Array(200 * 1024).fill(1));
  });

  it("accepts a file of exactly 64 KB and rejects one byte over", async () => {
    const base = await makePng({ extraChunks: [textChunk(1)] });
    const overhead = base.length - 1;
    const over = await makePng({ extraChunks: [textChunk(64 * 1024 - overhead + 1)] });
    expect(over.length).toBe(64 * 1024 + 1);
    await expectInvalid(over);
    const exact = await makePng({ extraChunks: [textChunk(64 * 1024 - overhead)] });
    expect(exact.length).toBe(64 * 1024);
    await expectValid(exact);
  });

  it("rejects a wrong Content-Type", async () => {
    const png = await makePng();
    await expectInvalid(png, "image/jpeg");
    await expectInvalid(png, "application/octet-stream");
    await expectInvalid(png, "application/json");
  });

  it("accepts Content-Type with parameters", async () => {
    const res = await pair.a.image(pair.lineId, await makePng(), "image/png; charset=binary");
    expect(res.status).toBe(201);
  });

  it("rejects a PNG whose chunk data is corrupted (CRC) or that has no IDAT", async () => {
    const png = await makePng();
    const corrupted = png.slice();
    corrupted[corrupted.length - 20] = (corrupted[corrupted.length - 20] ?? 0) ^ 0xff; // 破坏 IDAT 数据
    await expectInvalid(corrupted);
    const noIdat = concat(png.subarray(0, 33), chunk("IEND", new Uint8Array(0)));
    await expectInvalid(noIdat);
  });
});

describe("daily image limit", () => {
  it("allows 10 images per person per line per day, then returns 429", async () => {
    const { a, b, lineId } = await connectedPair();
    const png = await makePng({ width: 16, height: 16 });
    for (let i = 0; i < 10; i++) expect((await a.image(lineId, png)).status).toBe(201);
    const denied = await a.image(lineId, png);
    expect(denied.status).toBe(429);
    expect(denied.body.error.code).toBe("quota_exceeded");
    // 被拒绝的没有残留在 R2
    expect((await env.IMAGES.list()).objects).toHaveLength(10);

    // 每人各算各的
    expect((await b.image(lineId, png)).status).toBe(201);

    // 隔天重置：把当天已发的消息挪到昨天
    await env.DB.prepare("UPDATE messages SET sent_at = sent_at - 86400000 WHERE kind = 'image'").run();
    expect((await a.image(lineId, png)).status).toBe(201);
  });
});

describe("GET /v1/images/:imageId", () => {
  it("returns the PNG bytes to both participants and 404 to everyone else", async () => {
    const { a, b, lineId } = await connectedPair();
    const png = await makePng({ width: 64, height: 32 });
    const up = await a.image(lineId, png);
    const imageId: string = up.body.message.imageId;

    for (const who of [a, b]) {
      const res = await who.fetchImage(imageId);
      expect(res.status).toBe(200);
      expect(res.res.headers.get("content-type")).toBe("image/png");
    }
    const raw = await b.call(`/v1/images/${imageId}`);
    expect(raw.status).toBe(200);

    const outsider = await Device.create();
    const denied = await outsider.fetchImage(imageId);
    expect(denied.status).toBe(404);
    expect(denied.body.error.code).toBe("not_found");
    // 不存在的图与无权限的图表现一致
    const missing = await a.fetchImage("00000000-0000-0000-0000-000000000000");
    expect(missing.status).toBe(404);
    expect(missing.body).toEqual(denied.body);
  });

  it("returns exactly the uploaded bytes", async () => {
    const { a, b, lineId } = await connectedPair();
    const png = await makePng({ width: 48, height: 48 });
    const up = await a.image(lineId, png);
    const res = await rawFetch(`/v1/images/${up.body.message.imageId}`, {
      headers: { authorization: `Bearer ${b.token}` },
    });
    expect(res.status).toBe(200);
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(png);
  });

  it("requires authentication", async () => {
    const { a, lineId } = await connectedPair();
    const up = await a.image(lineId, await makePng());
    const res = await apiFetch(`/v1/images/${up.body.message.imageId}`);
    expect(res.status).toBe(401);
  });

  it("stays available to the sender after the line is closed, until deleted", async () => {
    const { a, b, lineId } = await connectedPair();
    const up = await a.image(lineId, await makePng());
    await b.tear(lineId);
    // 撕掉的一方（b）未确认的图片开始 24 小时倒计时；发送方 a 在这段时间内仍可取
    expect((await a.fetchImage(up.body.message.imageId)).status).toBe(200);
  });
});
