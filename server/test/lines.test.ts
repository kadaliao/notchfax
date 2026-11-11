import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { connectedPair, Device } from "./helpers";

describe("replies and the awaiting_reply rule", () => {
  it("the initiator cannot send a second message before the recipient replies", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("first");
    expect(sent.body.line.state).toBe("delivered");

    const again = await a.say(sent.body.line.id, "second, impatient");
    expect(again.status).toBe(403);
    expect(again.body.error.code).toBe("awaiting_reply");

    // 被拒绝的消息不会被存下来
    const inbox = await b.inbox();
    expect(inbox.body.messages).toHaveLength(1);
  });

  it("a reply from the recipient connects the line and raises the initiator's daily cap by one", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("hello");
    expect((await a.me()).body.quota).toMatchObject({ newFaxesPerDay: 3, newFaxesLeft: 2 });

    const reply = await b.say(sent.body.line.id, "hello back");
    expect(reply.status).toBe(201);
    expect(reply.body.line.state).toBe("connected");
    expect(reply.body.line.role).toBe("recipient");
    expect(reply.body.message).toMatchObject({ from: "me", kind: "text", text: "hello back", lineId: sent.body.line.id });

    // 发起人：上限 3→4，今天已用 1，剩 3
    expect((await a.me()).body.quota).toMatchObject({ newFaxesPerDay: 4, newFaxesLeft: 3 });
    // 回复者自己的上限不变
    expect((await b.me()).body.quota.newFaxesPerDay).toBe(3);

    // 接通后双方都可以继续发文字
    const more = await a.say(sent.body.line.id, "now I can talk");
    expect(more.status).toBe(201);
    expect(more.body.line.state).toBe("connected");
    expect(more.body.line.role).toBe("initiator");
    expect((await b.say(sent.body.line.id, "yes")).status).toBe(201);
    // 后续消息不会再次抬高上限
    expect((await a.me()).body.quota.newFaxesPerDay).toBe(4);
  });

  it("the cap rises with each reply but never beyond 10", async () => {
    const a = await Device.create();
    const b = await Device.create();
    await env.DB.prepare("UPDATE devices SET new_faxes_per_day = 9 WHERE id = ?1").bind(a.id).run();
    for (let i = 0; i < 3; i++) {
      await env.DB.prepare("UPDATE devices SET new_faxes_used = 0 WHERE id = ?1").bind(a.id).run();
      const sent = await a.fax(`line ${i}`);
      expect(sent.body.line.state).toBe("delivered");
      expect((await b.say(sent.body.line.id, "ok")).body.line.state).toBe("connected");
    }
    expect((await a.me()).body.quota.newFaxesPerDay).toBe(10);
  });

  it("returns not_found for non-participants and unknown lines", async () => {
    const { a, lineId } = await connectedPair();
    const outsider = await Device.create();
    // 非参与者：404，与线路不存在无法区分
    const foreign = await outsider.say(lineId, "hi");
    expect(foreign.status).toBe(404);
    expect(foreign.body.error.code).toBe("not_found");
    expect((await a.say("no-such-line", "hi")).status).toBe(404);
  });

  it("returns 409 line_not_ready while the line is still queued", async () => {
    const solo = await Device.create();
    const queued = await solo.fax("anyone?");
    expect(queued.body.line.state).toBe("queued");
    const early = await solo.say(queued.body.line.id, "still waiting");
    expect(early.status).toBe(409);
    expect(early.body.error.code).toBe("line_not_ready");
  });

  it("returns 409 line_closed once the line is closed", async () => {
    const { a, b, lineId } = await connectedPair();
    await a.tear(lineId);
    for (const who of [a, b]) {
      const late = await who.say(lineId, "too late");
      expect(late.status).toBe(409);
      expect(late.body.error.code).toBe("line_closed");
    }
  });
});

describe("text validation", () => {
  it("accepts 1-500 Unicode scalars after trimming, rejects everything else", async () => {
    const a = await Device.create();
    await Device.create();
    await env.DB.prepare("UPDATE devices SET new_faxes_per_day = 10").run();

    const ok500 = await a.fax("x".repeat(500));
    expect(ok500.status).toBe(202);
    // 首尾空白不计入，但会被去掉
    const padded = await a.fax(`   ${"y".repeat(500)}\n\t `);
    expect(padded.status).toBe(202);
    expect(padded.body.message.text).toBe("y".repeat(500));
    // 一个 emoji（代理对 / 家庭组合除外）算 1 个标量：500 个 emoji 合法
    const emoji = await a.fax("😀".repeat(500));
    expect(emoji.status).toBe(202);
    // 中文按字符计
    expect((await a.fax("你好，陌生人")).status).toBe(202);

    for (const bad of ["", "   ", "\n\t", "x".repeat(501), "😀".repeat(501)]) {
      const res = await a.fax(bad);
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe("invalid_text");
    }
    for (const body of [{}, { text: 123 }, { text: null }, { text: ["a"] }]) {
      const res = await a.call("/v1/faxes", { body });
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe("invalid_text");
    }
    const noBody = await a.call("/v1/faxes", { method: "POST" });
    expect(noBody.status).toBe(400);
    expect(noBody.body.error.code).toBe("invalid_text");
    const garbage = await a.call("/v1/faxes", { body: "{not json" });
    expect(garbage.status).toBe(400);

    // 失败的请求不消耗额度：上面成功 4 封
    const me = await a.me();
    expect(me.body.quota.newFaxesLeft).toBe(10 - 4);
  });

  it("applies the same rules to replies", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const sent = await a.fax("hello");
    for (const bad of ["", "  ", "z".repeat(501)]) {
      const res = await b.say(sent.body.line.id, bad);
      expect(res.status).toBe(400);
      expect(res.body.error.code).toBe("invalid_text");
    }
    // 回复被拒绝后线路仍是 delivered
    expect((await b.lines()).body.lines[0].state).toBe("delivered");
  });
});

describe("quota", () => {
  it("allows 3 new faxes a day, then returns 429 quota_exceeded", async () => {
    const a = await Device.create();
    await Device.create();
    for (let i = 0; i < 3; i++) {
      const res = await a.fax(`fax ${i}`);
      expect(res.status).toBe(202);
      expect((await a.me()).body.quota.newFaxesLeft).toBe(2 - i);
    }
    const denied = await a.fax("one too many");
    expect(denied.status).toBe(429);
    expect(denied.body.error.code).toBe("quota_exceeded");
    // 被拒绝的请求没有创建线路
    const { n } = (await env.DB.prepare("SELECT COUNT(*) AS n FROM lines WHERE initiator_id = ?1").bind(a.id).first<{ n: number }>())!;
    expect(n).toBe(3);
  });

  it("resets lazily when the UTC day changes", async () => {
    const a = await Device.create();
    await Device.create();
    for (let i = 0; i < 3; i++) await a.fax(`fax ${i}`);
    expect((await a.fax("denied")).status).toBe(429);

    // 把“已用额度所属的日子”挪到昨天，等价于跨过了 UTC 零点
    await env.DB.prepare("UPDATE devices SET quota_day = quota_day - 1 WHERE id = ?1").bind(a.id).run();
    const me = await a.me();
    expect(me.body.quota.newFaxesLeft).toBe(3);
    expect((await a.fax("new day")).status).toBe(202);
    expect((await a.me()).body.quota.newFaxesLeft).toBe(2);
  });

  it("queued faxes count against the quota too", async () => {
    const a = await Device.create();
    for (let i = 0; i < 3; i++) expect((await a.fax(`q${i}`)).body.line.state).toBe("queued");
    expect((await a.fax("q3")).status).toBe(429);
  });

  it("a suspended device gets 403 suspended on every send", async () => {
    const { a, b, lineId } = await connectedPair();
    await env.DB.prepare("UPDATE devices SET suspended_until = ?1 WHERE id = ?2").bind(Date.now() + 3600_000, a.id).run();

    const fax = await a.fax("hello");
    expect(fax.status).toBe(403);
    expect(fax.body.error.code).toBe("suspended");
    const say = await a.say(lineId, "hello");
    expect(say.status).toBe(403);
    expect(say.body.error.code).toBe("suspended");
    const me = await a.me();
    expect(me.body.suspendedUntil).toBeGreaterThan(Date.now());

    // 对方不受影响
    expect((await b.say(lineId, "still fine")).status).toBe(201);
    // 暂停过期后恢复
    await env.DB.prepare("UPDATE devices SET suspended_until = ?1 WHERE id = ?2").bind(Date.now() - 1, a.id).run();
    expect((await a.say(lineId, "back")).status).toBe(201);
    expect((await a.me()).body.suspendedUntil).toBeNull();
  });
});

describe("GET /v1/lines", () => {
  it("returns only the caller's open lines from the caller's point of view", async () => {
    const { a, b, lineId } = await connectedPair();
    const la = (await a.lines()).body.lines;
    const lb = (await b.lines()).body.lines;
    expect(la).toHaveLength(1);
    expect(lb).toHaveLength(1);
    expect(la[0]).toMatchObject({ id: lineId, state: "connected", role: "initiator" });
    expect(lb[0]).toMatchObject({ id: lineId, state: "connected", role: "recipient" });
    expect(la[0].myAlias).toBe(lb[0].peerAlias);
    expect(la[0].peerAlias).toBe(lb[0].myAlias);

    const outsider = await Device.create();
    expect((await outsider.lines()).body.lines).toEqual([]);

    await a.tear(lineId);
    expect((await a.lines()).body.lines).toEqual([]);
    expect((await b.lines()).body.lines).toEqual([]);
  });
});
