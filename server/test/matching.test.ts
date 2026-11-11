import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { createSessionFor, Device } from "./helpers";

const DAY = 24 * 3600_000;

async function setSeen(device: Device, lastSeenAt: number) {
  await env.DB.prepare("UPDATE devices SET last_seen_at = ?1 WHERE id = ?2").bind(lastSeenAt, device.id).run();
}

async function recipientOf(lineId: string): Promise<string | null> {
  const row = await env.DB.prepare("SELECT recipient_id FROM lines WHERE id = ?1").bind(lineId).first<{ recipient_id: string | null }>();
  return row?.recipient_id ?? null;
}

describe("POST /v1/faxes matching", () => {
  it("delivers to another device with distinct aliases", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const res = await a.fax("  hello there  ");
    expect(res.status).toBe(202);
    expect(res.body.line.state).toBe("delivered");
    expect(res.body.line.role).toBe("initiator");
    expect(res.body.line.myAlias).toMatch(/^[0-9A-F]{4}$/);
    expect(res.body.line.peerAlias).toMatch(/^[0-9A-F]{4}$/);
    expect(res.body.line.myAlias).not.toBe(res.body.line.peerAlias);
    expect(res.body.message.from).toBe("me");
    expect(res.body.message.kind).toBe("text");
    expect(res.body.message.text).toBe("hello there"); // 首尾空白已去掉
    expect(await recipientOf(res.body.line.id)).toBe(b.id);

    // 收件人视角：role / 别名互换
    const lines = await b.lines();
    expect(lines.body.lines).toHaveLength(1);
    expect(lines.body.lines[0].role).toBe("recipient");
    expect(lines.body.lines[0].myAlias).toBe(res.body.line.peerAlias);
    expect(lines.body.lines[0].peerAlias).toBe(res.body.line.myAlias);
  });

  it("never matches the sender with itself: a lone device gets a queued line", async () => {
    const a = await Device.create();
    const res = await a.fax("anyone there?");
    expect(res.status).toBe(202);
    expect(res.body.line.state).toBe("queued");
    expect(res.body.line.peerAlias).toBeNull();
    expect(await recipientOf(res.body.line.id)).toBeNull();
  });

  it("uses a different random alias pair for every line (aliases are not linkable)", async () => {
    const a = await Device.create();
    await Device.create();
    const aliases = new Set<string>();
    for (let i = 0; i < 3; i++) {
      const res = await a.fax(`message ${i}`);
      aliases.add(res.body.line.myAlias);
      aliases.add(res.body.line.peerAlias);
    }
    // 6 个别名全部取自 65536 个值：全部相同的概率可以忽略，若别名取决于设备则只会有 2 个
    expect(aliases.size).toBeGreaterThan(2);
  });

  it("a full recipient is skipped and the fax stays queued when nobody else is eligible", async () => {
    const b = await Device.create();
    const a = await Device.create();
    // 让 b 今天已经收满 5 条（直接写入历史线路）
    const now = Date.now();
    for (let i = 0; i < 5; i++) {
      await env.DB.prepare(
        `INSERT INTO lines (id, state, initiator_id, recipient_id, initiator_alias, recipient_alias, created_at, updated_at, matched_at, last_message_at)
         VALUES (?1, 'delivered', ?2, ?3, 'AAAA', 'BBBB', ?4, ?4, ?4, ?4)`,
      ).bind(`filler-${i}`, `other-sender-${i}`, b.id, now).run();
    }
    // a 的唯一候选人 b 已满
    const res = await a.fax("hello");
    expect(res.body.line.state).toBe("queued");
    // 昨天收满的不算数（惰性重置）：把 b 的记录挪到昨天，a 再发就能配上
    await env.DB.prepare("UPDATE lines SET matched_at = ?1 WHERE recipient_id = ?2").bind(now - 2 * DAY, b.id).run();
    const again = await a.fax("hello again");
    expect(again.body.line.state).toBe("delivered");
    expect(await recipientOf(again.body.line.id)).toBe(b.id);
  });

  it("excludes devices suspended from sending", async () => {
    const a = await Device.create();
    const b = await Device.create();
    await env.DB.prepare("UPDATE devices SET suspended_until = ?1 WHERE id = ?2").bind(Date.now() + DAY, b.id).run();
    const res = await a.fax("hello");
    expect(res.body.line.state).toBe("queued");
    // 暂停已过期则恢复资格
    await env.DB.prepare("UPDATE devices SET suspended_until = ?1 WHERE id = ?2").bind(Date.now() - 1000, b.id).run();
    const next = await a.fax("hello again");
    expect(next.body.line.state).toBe("delivered");
  });

  it("excludes devices not active in the last 7 days", async () => {
    const a = await Device.create();
    const b = await Device.create();
    await setSeen(b, Date.now() - 8 * DAY);
    expect((await a.fax("hello")).body.line.state).toBe("queued");
    await setSeen(b, Date.now() - 6 * DAY);
    expect((await a.fax("hello again")).body.line.state).toBe("delivered");
  });

  it("excludes pairs that have reported each other, in either direction", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("rude message");
    expect(sent.body.line.state).toBe("delivered");
    // b 撕掉并举报 a
    expect((await b.tear(sent.body.line.id, true)).status).toBe(200);

    // a 再发：唯一候选 b 与 a 有举报关系 → queued
    expect((await a.fax("again")).body.line.state).toBe("queued");
    // b 发给 a 同样被排除（双方以后不再配对）
    expect((await b.fax("hello from b")).body.line.state).toBe("queued");
  });

  it("prefers devices that are currently online", async () => {
    const sender = await Device.create();
    const sleepy = await Device.create();
    const online = await Device.create();
    await env.DB.prepare("UPDATE devices SET new_faxes_per_day = 10").run();
    const socket = await online.connect();
    expect(socket).toBeTruthy();

    const picks: Array<string | null> = [];
    for (let i = 0; i < 4; i++) {
      const res = await sender.fax(`probe ${i}`);
      picks.push(await recipientOf(res.body.line.id));
    }
    // 4 次都应落在在线的那台；纯随机时全中的概率只有 1/16，且接收上限 5 不会触发
    expect(picks.every((p) => p === online.id)).toBe(true);
    expect(picks).not.toContain(sleepy.id);
  });

  it("falls back to an offline active device when no one is online", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const res = await a.fax("hi");
    expect(await recipientOf(res.body.line.id)).toBe(b.id);
  });
});

describe("queued faxes", () => {
  it("are matched when an eligible device next opens a session, and the initiator is notified", async () => {
    const a = await Device.create();
    const aSocket = await a.connect();
    const queued = await a.fax("is anyone out there?");
    expect(queued.body.line.state).toBe("queued");

    // 之后来了一个新设备并建立会话
    const b = await Device.create();
    const matched = await aSocket.waitFor((e) => e.type === "line.updated" && e.line.id === queued.body.line.id);
    expect(matched.line.state).toBe("delivered");
    expect(matched.line.role).toBe("initiator");
    expect(matched.line.peerAlias).toMatch(/^[0-9A-F]{4}$/);

    // b 在 /v1/lines 与 /v1/inbox 里都能看到这封
    const inbox = await b.inbox();
    expect(inbox.body.messages).toHaveLength(1);
    expect(inbox.body.messages[0].text).toBe("is anyone out there?");
    expect(inbox.body.messages[0].from).toBe("peer");
    expect(inbox.body.lines[0].state).toBe("delivered");
    expect(inbox.body.lines[0].role).toBe("recipient");
    expect(inbox.body.lines[0].peerAlias).toBe(queued.body.line.myAlias);
  });

  it("are matched when an eligible device connects its socket, and the fax is pushed on that socket", async () => {
    const a = await Device.create();
    const b = await Device.create();
    // b 暂停 → a 的传真排队
    await env.DB.prepare("UPDATE devices SET suspended_until = ?1 WHERE id = ?2").bind(Date.now() + DAY, b.id).run();
    const queued = await a.fax("hold this");
    expect(queued.body.line.state).toBe("queued");

    // 暂停解除后，b 连上 socket 才触发配对
    await env.DB.prepare("UPDATE devices SET suspended_until = NULL WHERE id = ?1").bind(b.id).run();
    const socket = await b.connect();
    const fax = await socket.waitFor((e) => e.type === "fax");
    expect(fax.line.id).toBe(queued.body.line.id);
    expect(fax.line.state).toBe("delivered");
    expect(fax.message.text).toBe("hold this");
    expect(fax.message.from).toBe("peer");
  });

  it("are never matched to the initiator itself", async () => {
    const a = await Device.create();
    const queued = await a.fax("solo");
    expect(queued.body.line.state).toBe("queued");
    // a 自己再次建立会话、连上 socket，都不会把自己的传真配给自己
    expect((await createSessionFor(a.identity)).status).toBe(200);
    const socket = await a.connect();
    await new Promise((r) => setTimeout(r, 100));
    expect(socket.events.filter((e) => e.type === "fax")).toHaveLength(0);
    expect(await recipientOf(queued.body.line.id)).toBeNull();
  });

  it("are not matched to a device that has a report relationship with the initiator", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const first = await a.fax("first");
    expect(first.body.line.state).toBe("delivered");
    await b.tear(first.body.line.id, true);

    const queued = await a.fax("second");
    expect(queued.body.line.state).toBe("queued");
    // b 重新上线（新会话 + socket）也拿不到
    expect((await createSessionFor(b.identity)).status).toBe(200);
    await b.connect();
    await new Promise((r) => setTimeout(r, 100));
    expect(await recipientOf(queued.body.line.id)).toBeNull();

    // 没有举报关系的新设备可以
    const d = await Device.create();
    expect(await recipientOf(queued.body.line.id)).toBe(d.id);
  });

  it("are not matched to a suspended device", async () => {
    const a = await Device.create();
    const b = await Device.create();
    await env.DB.prepare("UPDATE devices SET suspended_until = ?1 WHERE id = ?2").bind(Date.now() + DAY, b.id).run();
    const queued = await a.fax("hold");
    expect(queued.body.line.state).toBe("queued");
    expect((await createSessionFor(b.identity)).status).toBe(200);
    expect(await recipientOf(queued.body.line.id)).toBeNull();
  });

  it("are matched oldest first, up to the recipient's daily limit of 5", async () => {
    // 直接写库造 7 条已排队的线路（发件人是不存在的设备）
    const now = Date.now();
    for (let i = 0; i < 7; i++) {
      const lineId = `q-${i}`;
      await env.DB.prepare(
        `INSERT INTO lines (id, state, initiator_id, initiator_alias, created_at, updated_at, last_message_at) VALUES (?1, 'queued', ?2, 'AAAA', ?3, ?3, ?3)`,
      ).bind(lineId, `ghost-${i}`, now - (7 - i) * 1000).run();
      await env.DB.prepare(
        `INSERT INTO messages (id, line_id, sender_id, kind, text, sent_at) VALUES (?1, ?2, ?3, 'text', ?4, ?5)`,
      ).bind(`m-${i}`, lineId, `ghost-${i}`, `queued ${i}`, now - (7 - i) * 1000).run();
    }
    const fresh = await Device.create(); // 新设备 → 会话建立触发配对
    const { results } = await env.DB.prepare("SELECT id FROM lines WHERE recipient_id = ?1 ORDER BY created_at").bind(fresh.id).all<{ id: string }>();
    expect(results.map((r) => r.id)).toEqual(["q-0", "q-1", "q-2", "q-3", "q-4"]);
    const left = await env.DB.prepare("SELECT COUNT(*) AS n FROM lines WHERE state = 'queued'").first<{ n: number }>();
    expect(left!.n).toBe(2);
  });

  it("older than 72 hours are not matched", async () => {
    const a = await Device.create();
    const queued = await a.fax("stale");
    await env.DB.prepare("UPDATE lines SET created_at = ?1 WHERE id = ?2").bind(Date.now() - 73 * 3600_000, queued.body.line.id).run();
    await Device.create();
    expect(await recipientOf(queued.body.line.id)).toBeNull();
  });
});
