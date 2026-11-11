import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { connectedPair, Device } from "./helpers";

const DAY = 24 * 3600_000;

describe("POST /v1/lines/:id/tear", () => {
  it("closes the line for both sides and notifies the peer without a reason", async () => {
    const { a, b, lineId } = await connectedPair();
    const aSocket = await a.connect();

    const res = await b.tear(lineId);
    expect(res.status).toBe(200);
    expect(res.body.line).toMatchObject({ id: lineId, state: "closed", role: "recipient" });

    // 对方收到 line.updated(closed)，事件里只有线路本身，没有原因 / 举报信息
    const event = await aSocket.waitFor((e) => e.type === "line.updated" && e.line.state === "closed");
    expect(event.line).toMatchObject({ id: lineId, role: "initiator" });
    expect(Object.keys(event).sort()).toEqual(["line", "type"]);
    expect(Object.keys(event.line).sort()).toEqual(
      ["createdAt", "id", "myAlias", "peerAlias", "role", "state", "updatedAt"].sort(),
    );

    // 双方列表里都没有了，也不能再发消息
    expect((await a.lines()).body.lines).toEqual([]);
    expect((await a.say(lineId, "hello?")).body.error.code).toBe("line_closed");
    expect((await b.say(lineId, "hello?")).body.error.code).toBe("line_closed");
  });

  it("works from either side and also for a delivered line", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("hello");
    const bSocket = await b.connect();
    const res = await a.tear(sent.body.line.id);
    expect(res.body.line.state).toBe("closed");
    const event = await bSocket.waitFor((e) => e.type === "line.updated");
    expect(event.line.state).toBe("closed");
    expect(event.line.role).toBe("recipient");
  });

  it("closes a queued line without needing a peer", async () => {
    const a = await Device.create();
    const sent = await a.fax("hello");
    expect(sent.body.line.state).toBe("queued");
    const res = await a.tear(sent.body.line.id, true); // 没有对方可举报
    expect(res.body.line.state).toBe("closed");
    const reports = await env.DB.prepare("SELECT COUNT(*) AS n FROM reports").first<{ n: number }>();
    expect(reports!.n).toBe(0);
    // 排队线路被撕掉后，不会再被后来的设备配到
    const b = await Device.create();
    expect((await b.inbox()).body.messages).toEqual([]);
    // 从未送达的第一封，文字立即清除
    const row = await env.DB.prepare("SELECT text FROM messages WHERE line_id = ?1").bind(sent.body.line.id).first<{ text: string | null }>();
    expect(row!.text).toBeNull();
  });

  it("is idempotent and returns 404 to non-participants", async () => {
    const { a, lineId } = await connectedPair();
    const outsider = await Device.create();
    expect((await outsider.tear(lineId)).status).toBe(404);
    expect((await a.tear("no-such-line")).status).toBe(404);
    expect((await a.tear(lineId)).status).toBe(200);
    const again = await a.tear(lineId);
    expect(again.status).toBe(200);
    expect(again.body.line.state).toBe("closed");
  });

  it("defaults to report=false when the body is empty", async () => {
    const { a, lineId } = await connectedPair();
    const res = await a.call(`/v1/lines/${lineId}/tear`, { method: "POST" });
    expect(res.status).toBe(200);
    const reports = await env.DB.prepare("SELECT COUNT(*) AS n FROM reports").first<{ n: number }>();
    expect(reports!.n).toBe(0);
  });

  it("drops the tearer's own unacknowledged incoming messages", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("secret text");
    await b.tear(sent.body.line.id);
    expect((await b.inbox()).body.messages).toEqual([]);
    const row = await env.DB.prepare("SELECT text, acked_at FROM messages WHERE line_id = ?1").bind(sent.body.line.id).first<any>();
    expect(row.text).toBeNull();
    expect(row.acked_at).not.toBeNull();
  });

  it("does not drop what the peer has not yet received", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("hello");
    await b.say(sent.body.line.id, "unread reply");
    await b.tear(sent.body.line.id);
    // a 还没确认 b 的回复：离线补投仍然给它，线路状态是 closed
    const inbox = await a.inbox();
    expect(inbox.body.messages).toHaveLength(1);
    expect(inbox.body.messages[0].text).toBe("unread reply");
    expect(inbox.body.lines[0].state).toBe("closed");
  });
});

describe("reports", () => {
  it("records at most one report per reporter and line", async () => {
    const { a, b, lineId } = await connectedPair();
    await b.tear(lineId, true);
    await b.tear(lineId, true);
    const { n } = (await env.DB.prepare("SELECT COUNT(*) AS n FROM reports WHERE reported_id = ?1").bind(a.id).first<{ n: number }>())!;
    expect(n).toBe(1);
  });

  it("a report may still be filed on a line the peer already closed", async () => {
    const { a, b, lineId } = await connectedPair();
    await a.tear(lineId);
    expect((await b.tear(lineId, true)).status).toBe(200);
    const { n } = (await env.DB.prepare("SELECT COUNT(*) AS n FROM reports WHERE reported_id = ?1").bind(a.id).first<{ n: number }>())!;
    expect(n).toBe(1);
  });

  it("suspends a device for 7 days once 3 different devices report it within 7 days", async () => {
    // 纯 API 流程：每次只有一个合格的收件人（已举报过的会被排除），所以 bad 的三封传真依次落到三台不同设备上
    const bad = await Device.create();
    const bystanders: Device[] = [];
    for (let i = 0; i < 3; i++) {
      const reporter = await Device.create();
      bystanders.push(reporter);
      const sent = await bad.fax(`rude message ${i}`);
      expect(sent.body.line.state).toBe("delivered");
      expect((await reporter.inbox()).body.messages).toHaveLength(1);

      expect((await bad.me()).body.suspendedUntil).toBeNull();
      expect((await reporter.tear(sent.body.line.id, true)).status).toBe(200);
      if (i < 2) expect((await bad.me()).body.suspendedUntil).toBeNull();
    }

    const me = (await bad.me()).body;
    expect(me.suspendedUntil).not.toBeNull();
    const remaining = me.suspendedUntil - Date.now();
    expect(remaining).toBeGreaterThan(7 * DAY - 60_000);
    expect(remaining).toBeLessThanOrEqual(7 * DAY);

    // 暂停后发新传真 → 403 suspended（额度本来也只有 3，先放宽以证明拦截的是暂停而不是额度）
    await env.DB.prepare("UPDATE devices SET new_faxes_per_day = 10 WHERE id = ?1").bind(bad.id).run();
    const res = await bad.fax("let me in");
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe("suspended");
    expect(bystanders).toHaveLength(3);
  });

  it("two reports are not enough, and reports older than 7 days do not count", async () => {
    const bad = await Device.create();
    const reporters = [await Device.create(), await Device.create(), await Device.create()];
    const old = Date.now() - 8 * DAY;
    // 一份 8 天前的旧举报
    await env.DB.prepare("INSERT INTO reports (line_id, reporter_id, reported_id, created_at) VALUES ('old', ?1, ?2, ?3)")
      .bind(reporters[0]!.id, bad.id, old)
      .run();
    for (const [i, reporter] of reporters.slice(1).entries()) {
      const lineId = `l-${i}`;
      const now = Date.now();
      await env.DB.prepare(
        `INSERT INTO lines (id, state, initiator_id, recipient_id, initiator_alias, recipient_alias, created_at, updated_at, matched_at, last_message_at)
         VALUES (?1, 'connected', ?2, ?3, '1111', '2222', ?4, ?4, ?4, ?4)`,
      ).bind(lineId, bad.id, reporter.id, now).run();
      await reporter.tear(lineId, true);
    }
    // 7 天内只有 2 个不同设备举报
    expect((await bad.me()).body.suspendedUntil).toBeNull();
  });

  it("the same reporter reporting on multiple lines counts once", async () => {
    const bad = await Device.create();
    const reporter = await Device.create();
    const now = Date.now();
    for (let i = 0; i < 4; i++) {
      await env.DB.prepare(
        `INSERT INTO lines (id, state, initiator_id, recipient_id, initiator_alias, recipient_alias, created_at, updated_at, matched_at, last_message_at)
         VALUES (?1, 'connected', ?2, ?3, '1111', '2222', ?4, ?4, ?4, ?4)`,
      ).bind(`s-${i}`, bad.id, reporter.id, now).run();
      await reporter.tear(`s-${i}`, true);
    }
    expect((await bad.me()).body.suspendedUntil).toBeNull();
  });

  it("a suspended device is never matched again, and reported pairs are never paired again", async () => {
    const bad = await Device.create();
    const reporters = [await Device.create(), await Device.create(), await Device.create()];
    const now = Date.now();
    for (const [i, reporter] of reporters.entries()) {
      await env.DB.prepare(
        `INSERT INTO lines (id, state, initiator_id, recipient_id, initiator_alias, recipient_alias, created_at, updated_at, matched_at, last_message_at)
         VALUES (?1, 'connected', ?2, ?3, '1111', '2222', ?4, ?4, ?4, ?4)`,
      ).bind(`p-${i}`, bad.id, reporter.id, now - 3 * DAY).run();
      await reporter.tear(`p-${i}`, true);
    }
    expect((await bad.me()).body.suspendedUntil).not.toBeNull();

    // 一个干净的发件人只有 4 个候选人：3 个举报人 + bad。bad 被暂停 → 只能落到 3 个举报人之一
    const clean = await Device.create();
    await env.DB.prepare("UPDATE devices SET new_faxes_per_day = 10 WHERE id = ?1").bind(clean.id).run();
    for (let i = 0; i < 5; i++) {
      const res = await clean.fax(`probe ${i}`);
      const row = await env.DB.prepare("SELECT recipient_id FROM lines WHERE id = ?1").bind(res.body.line.id).first<{ recipient_id: string | null }>();
      expect(row!.recipient_id).not.toBe(bad.id);
    }
    // 举报人再发，也不会被配给 bad（双方不再配对）
    for (const reporter of reporters) {
      const res = await reporter.fax("hello");
      const row = await env.DB.prepare("SELECT recipient_id FROM lines WHERE id = ?1").bind(res.body.line.id).first<{ recipient_id: string | null }>();
      expect(row!.recipient_id).not.toBe(bad.id);
    }
  });
});
