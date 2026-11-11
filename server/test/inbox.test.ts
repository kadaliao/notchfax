import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { runMaintenance } from "../src/service";
import { connectedPair, Device, makePng } from "./helpers";

const HOUR = 3600_000;
const DAY = 24 * HOUR;

async function messageRow(id: string) {
  return env.DB.prepare("SELECT * FROM messages WHERE id = ?1").bind(id).first<any>();
}

describe("GET /v1/inbox and ack lifecycle", () => {
  it("holds messages for an offline device until they are acknowledged", async () => {
    const a = await Device.create();
    const b = await Device.create(); // b 全程没有连 socket
    const sent = await a.fax("while you were out");
    const lineId: string = sent.body.line.id;

    const first = await b.inbox();
    expect(first.status).toBe(200);
    expect(first.body.messages).toHaveLength(1);
    expect(first.body.messages[0]).toMatchObject({ lineId, from: "peer", kind: "text", text: "while you were out" });
    expect(first.body.lines).toHaveLength(1);
    expect(first.body.lines[0]).toMatchObject({ id: lineId, state: "delivered", role: "recipient" });

    // 没确认之前，每次都还在
    expect((await b.inbox()).body.messages).toHaveLength(1);
    // 发件人自己不会在收件箱里看到自己的消息
    expect((await a.inbox()).body.messages).toEqual([]);
  });

  it("returns messages oldest first across lines, with the lines they belong to", async () => {
    const { a, b, lineId } = await connectedPair();
    await a.say(lineId, "second");
    await b.say(lineId, "third");
    const aInbox = await a.inbox();
    // a 的收件箱：b 的两条（"hi back" 与 "third"）
    expect(aInbox.body.messages.map((m: any) => m.text)).toEqual(["hi back", "third"]);
    expect(aInbox.body.lines).toHaveLength(1);
    expect(aInbox.body.lines[0]).toMatchObject({ id: lineId, state: "connected", role: "initiator" });
    const bInbox = await b.inbox();
    expect(bInbox.body.messages.map((m: any) => m.text)).toEqual(["hello stranger", "second"]);
  });

  it("ack returns 204, removes the message from the inbox and deletes its text but keeps metadata", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("burn after reading");
    const messageId: string = sent.body.message.id;

    const ack = await b.ack(messageId);
    expect(ack.status).toBe(204);
    expect(ack.body).toBeNull();

    expect((await b.inbox()).body.messages).toEqual([]);
    const row = await messageRow(messageId);
    expect(row.text).toBeNull();
    expect(row.acked_at).not.toBeNull();
    expect(row.sender_id).toBe(a.id); // 元数据保留
    expect(row.kind).toBe("text");

    // 幂等
    expect((await b.ack(messageId)).status).toBe(204);
  });

  it("only the recipient of a message may ack it; anyone else gets 404", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("hi");
    const messageId: string = sent.body.message.id;
    const outsider = await Device.create(); // 在配对完成之后才出现，不可能是收件人

    expect((await a.ack(messageId)).status).toBe(404); // 发送者不能替对方确认
    expect((await outsider.ack(messageId)).status).toBe(404);
    expect((await b.ack("no-such-message")).status).toBe(404);
    expect((await b.ack("no-such-message")).body.error.code).toBe("not_found");
    // 被拒绝的确认没有任何副作用
    expect((await messageRow(messageId)).text).toBe("hi");
    expect((await b.inbox()).body.messages).toHaveLength(1);
  });

  it("acking an image starts a 24 hour countdown; the image stays fetchable until then", async () => {
    const { a, b, lineId } = await connectedPair();
    const up = await a.image(lineId, await makePng());
    const imageId: string = up.body.message.imageId;
    const messageId: string = up.body.message.id;

    // 确认之前没有倒计时
    expect((await messageRow(messageId)).image_expires_at).toBeNull();
    const inbox = await b.inbox();
    const imageMsg = inbox.body.messages.find((m: any) => m.kind === "image");
    expect(imageMsg).toMatchObject({ imageId, from: "peer", width: 64, height: 64 });

    const before = Date.now();
    expect((await b.ack(messageId)).status).toBe(204);
    const row = await messageRow(messageId);
    expect(row.image_expires_at).toBeGreaterThanOrEqual(before + DAY);
    expect(row.image_expires_at).toBeLessThanOrEqual(Date.now() + DAY);
    expect((await b.fetchImage(imageId)).status).toBe(200);

    // 23 小时：定时任务不删
    const early = await runMaintenance(env, Date.now() + 23 * HOUR);
    expect(early.imagesDeleted).toBe(0);
    expect(await env.IMAGES.head(`images/${imageId}`)).not.toBeNull();

    // 25 小时：定时任务删除 R2 对象，之后任何人都取不到
    const late = await runMaintenance(env, Date.now() + 25 * HOUR);
    expect(late.imagesDeleted).toBe(1);
    expect(await env.IMAGES.head(`images/${imageId}`)).toBeNull();
    expect((await b.fetchImage(imageId)).status).toBe(404);
    expect((await a.fetchImage(imageId)).status).toBe(404);
    // 元数据仍在
    expect((await messageRow(messageId)).width).toBe(64);
  });

  it("refuses to serve an image whose retention has run out even before the cron has run", async () => {
    const { a, b, lineId } = await connectedPair();
    const up = await a.image(lineId, await makePng());
    await b.ack(up.body.message.id);
    await env.DB.prepare("UPDATE messages SET image_expires_at = ?1 WHERE id = ?2").bind(Date.now() - 1, up.body.message.id).run();
    expect((await b.fetchImage(up.body.message.imageId)).status).toBe(404);
  });

  it("keeps unacknowledged images indefinitely", async () => {
    const { a, lineId } = await connectedPair();
    const up = await a.image(lineId, await makePng());
    const report = await runMaintenance(env, Date.now() + 10 * DAY);
    expect(report.imagesDeleted).toBe(0);
    expect(await env.IMAGES.head(`images/${up.body.message.imageId}`)).not.toBeNull();
  });
});

describe("line timeouts (cron)", () => {
  it("closes a queued line after 72 hours", async () => {
    const a = await Device.create();
    const queued = await a.fax("hello?");
    const lineId: string = queued.body.line.id;
    expect((await runMaintenance(env, Date.now() + 71 * HOUR)).linesClosed).toBe(0);
    const report = await runMaintenance(env, Date.now() + 73 * HOUR);
    expect(report.linesClosed).toBe(1);
    const row = await env.DB.prepare("SELECT state FROM lines WHERE id = ?1").bind(lineId).first<any>();
    expect(row.state).toBe("closed");
  });

  it("closes a delivered line after 7 days without a reply, counted from delivery", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("hello");
    const aSocket = await a.connect();
    expect((await runMaintenance(env, Date.now() + 6 * DAY)).linesClosed).toBe(0);
    expect((await runMaintenance(env, Date.now() + 8 * DAY)).linesClosed).toBe(1);
    const event = await aSocket.waitFor((e) => e.type === "line.updated");
    expect(event.line).toMatchObject({ id: sent.body.line.id, state: "closed" });
    // 过期未回复的线路不能再回复
    const late = await b.say(sent.body.line.id, "sorry, late");
    expect(late.status).toBe(409);
    expect(late.body.error.code).toBe("line_closed");
  });

  it("closes a connected line after 30 days without messages, and messages reset the clock", async () => {
    const { a, b, lineId } = await connectedPair();
    expect((await runMaintenance(env, Date.now() + 29 * DAY)).linesClosed).toBe(0);
    // 15 天后有人发了一条，计时重置
    await env.DB.prepare("UPDATE lines SET last_message_at = ?1 WHERE id = ?2").bind(Date.now() - 15 * DAY, lineId).run();
    expect((await runMaintenance(env, Date.now() + 20 * DAY)).linesClosed).toBe(1);
    expect((await a.lines()).body.lines).toEqual([]);
    expect((await b.say(lineId, "hello?")).status).toBe(409);
  });

  it("is enforced lazily too: a timed-out line cannot be used before the cron has noticed", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("hello");
    await env.DB.prepare("UPDATE lines SET matched_at = ?1 WHERE id = ?2").bind(Date.now() - 8 * DAY, sent.body.line.id).run();
    expect((await b.lines()).body.lines).toEqual([]);
    const late = await b.say(sent.body.line.id, "hello");
    expect(late.status).toBe(409);
    expect(late.body.error.code).toBe("line_closed");
  });

  it("purges lines closed for more than 30 days, including unacknowledged content and images", async () => {
    const { a, lineId } = await connectedPair();
    const up = await a.image(lineId, await makePng());
    await a.tear(lineId);
    const report = await runMaintenance(env, Date.now() + 31 * DAY);
    expect(report.linesPurged).toBe(1);
    const left = await env.DB.prepare("SELECT (SELECT COUNT(*) FROM lines) AS l, (SELECT COUNT(*) FROM messages) AS m").first<any>();
    expect(left).toEqual({ l: 0, m: 0 });
    expect(await env.IMAGES.head(`images/${up.body.message.imageId}`)).toBeNull();
  });
});
