import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { MAINTENANCE_LIMITS, runMaintenance } from "../src/service";
import { meteredEnv, metered, type Cost } from "./cost";
import { Device, insertLine, makePng, newIdentity, sign } from "./helpers";

/**
 * 免费套餐成本回归测试。
 *
 * D1 的计费口径（本地 wrangler/miniflare 返回同样的 meta）：
 *   rows_read    读行数（扫描到的行 + 索引条目）。免费额度每天 500 万。
 *   rows_written 写行数（表行 + 每个被更新的索引条目）。免费额度每天 10 万。
 * 另外每次 Worker 调用最多 50 次 D1 查询（batch 算一次）。
 *
 * 做法：先往库里灌一大批与测试无关的设备、线路、消息，再逐个接口量一次。
 * 如果哪个查询退化成全表扫描，读行数会比下面的上限大两个数量级。
 */

const DAY = 24 * 3600_000;
const SEED_DEVICES = 600;
const SEED_LINES = 300;

async function seedBigDatabase() {
  const now = Date.now();
  const batches: D1PreparedStatement[][] = [];
  let current: D1PreparedStatement[] = [];
  const push = (stmt: D1PreparedStatement) => {
    current.push(stmt);
    if (current.length >= 100) {
      batches.push(current);
      current = [];
    }
  };
  for (let i = 0; i < SEED_DEVICES; i++) {
    push(
      env.DB.prepare("INSERT INTO devices (id, public_key, created_at, last_seen_at, rnd) VALUES (?1, 'k', ?2, ?2, ?3)").bind(
        `seed-${i}`,
        now,
        Math.floor(Math.random() * 2 ** 31),
      ),
    );
  }
  for (let i = 0; i < SEED_LINES; i++) {
    const closed = i % 3 === 0;
    push(
      env.DB.prepare(
        `INSERT INTO lines (id, state, initiator_id, recipient_id, initiator_alias, recipient_alias,
                            created_at, updated_at, matched_at, closed_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, 'AAAA', 'BBBB', ?5, ?5, ?5, ?6, ?7)`,
      ).bind(`seed-line-${i}`, closed ? "closed" : "connected", `seed-${i}`, `seed-${(i + 1) % SEED_DEVICES}`, now, closed ? now : null, now + 20 * DAY),
    );
    for (let m = 0; m < 3; m++) {
      push(
        env.DB.prepare(
          "INSERT INTO messages (id, line_id, sender_id, to_id, kind, text, sent_at, acked_at) VALUES (?1, ?2, ?3, ?4, 'text', NULL, ?5, ?5)",
        ).bind(`seed-msg-${i}-${m}`, `seed-line-${i}`, `seed-${i}`, `seed-${(i + 1) % SEED_DEVICES}`, now),
      );
    }
  }
  if (current.length) batches.push(current);
  for (const b of batches) await env.DB.batch(b);
}

async function login(): Promise<{ token: string; deviceId: string; cost: Cost }> {
  const id = await newIdentity();
  const ts = Date.now();
  const r = await metered("/v1/session", {
    body: { publicKey: id.publicKeyB64, timestamp: ts, signature: await sign(id, `notchfax-session:${ts}`) },
  });
  return { token: r.body.token, deviceId: id.deviceId, cost: r.cost };
}

function within(label: string, cost: Cost, max: { queries: number; read: number; written: number }) {
  expect(cost.queries, `${label}: queries (per-invocation limit is 50)`).toBeLessThanOrEqual(max.queries);
  expect(cost.read, `${label}: rows read`).toBeLessThanOrEqual(max.read);
  expect(cost.written, `${label}: rows written`).toBeLessThanOrEqual(max.written);
}

describe("D1 cost per request (free plan: 100k rows written/day, 5M rows read/day, 50 queries/invocation)", () => {
  beforeEach(async () => {
    await seedBigDatabase();
  });

  it("a full conversation stays within a small, table-size-independent budget", async () => {
    const a = await login();
    const b = await login();
    within("new device session", a.cost, { queries: 6, read: 12, written: 3 });

    // 重复建立会话：6 小时内不写库
    const again = await Device.create();
    expect(again.token).toBeTruthy();
    const idleSession = await (async () => {
      const id = await newIdentity();
      const ts = Date.now();
      const body = { publicKey: id.publicKeyB64, timestamp: ts, signature: await sign(id, `notchfax-session:${ts}`) };
      await metered("/v1/session", { body });
      return metered("/v1/session", { body });
    })();
    within("repeat session", idleSession.cost, { queries: 6, read: 12, written: 0 });

    // b 连上 socket → 在线，配对优先它
    await new Device(await newIdentityFor(b), b.token).connect();

    const me = await metered("/v1/me", { token: a.token });
    expect(me.cost.written, "authenticated requests must not write").toBe(0);
    expect(me.cost.queries).toBe(1);

    const fax = await metered("/v1/faxes", { token: a.token, body: { text: "hello" } });
    expect(fax.body.line.state).toBe("delivered");
    within("POST /v1/faxes (matched)", fax.cost, { queries: 6, read: 20, written: 10 });

    const lineId: string = fax.body.line.id;
    within("GET /v1/inbox", (await metered("/v1/inbox", { token: b.token })).cost, { queries: 4, read: 15, written: 0 });
    within("GET /v1/lines", (await metered("/v1/lines", { token: b.token })).cost, { queries: 3, read: 10, written: 0 });
    within(
      "POST ack",
      (await metered(`/v1/messages/${fax.body.message.id}/ack`, { token: b.token, method: "POST" })).cost,
      { queries: 3, read: 6, written: 2 },
    );
    const reply = await metered(`/v1/lines/${lineId}/messages`, { token: b.token, body: { text: "hi" } });
    expect(reply.body.line.state).toBe("connected");
    within("POST reply (-> connected)", reply.cost, { queries: 6, read: 15, written: 7 });
    const more = await metered(`/v1/lines/${lineId}/messages`, { token: a.token, body: { text: "more" } });
    within("POST message (connected)", more.cost, { queries: 5, read: 12, written: 5 });

    const png = await makePng({ width: 384, height: 384 });
    const img = await metered(`/v1/lines/${lineId}/images`, { token: a.token, body: png, headers: { "content-type": "image/png" } });
    expect(img.status).toBe(201);
    within("POST image", img.cost, { queries: 5, read: 20, written: 8 });
    within("GET image", (await metered(`/v1/images/${img.body.message.imageId}`, { token: b.token })).cost, { queries: 4, read: 8, written: 0 });
    within(
      "POST ack (image)",
      (await metered(`/v1/messages/${img.body.message.id}/ack`, { token: b.token, method: "POST" })).cost,
      { queries: 3, read: 6, written: 3 },
    );
    const tear = await metered(`/v1/lines/${lineId}/tear`, { token: b.token, body: { report: false } });
    expect(tear.status).toBe(200);
    within("POST tear", tear.cost, { queries: 5, read: 20, written: 4 });
  });

  it("matching a fax into a large pool reads a handful of rows, not the whole devices table", async () => {
    const sender = await login();
    await env.DB.prepare("UPDATE devices SET new_faxes_per_day = 1000 WHERE id = ?1").bind(sender.deviceId).run();
    let worst = 0;
    let total = 0;
    for (let i = 0; i < 25; i++) {
      const res = await metered("/v1/faxes", { token: sender.token, body: { text: `probe ${i}` } });
      expect(res.body.line.state).toBe("delivered");
      worst = Math.max(worst, res.cost.read);
      total += res.cost.read;
    }
    expect(total / 25, "average rows read per fax").toBeLessThanOrEqual(15);
    expect(worst, "worst case rows read per fax").toBeLessThan(100); // 全表扫描会是 SEED_DEVICES * 2 以上
  });

  it("matching still reads a bounded number of rows when most of the pool is full or unusable", async () => {
    const sender = await login();
    await env.DB.prepare("UPDATE devices SET new_faxes_per_day = 1000 WHERE id = ?1").bind(sender.deviceId).run();
    // 除一台之外全部收满
    await env.DB.prepare("UPDATE devices SET recv_day = ?1, recv_count = 5 WHERE id LIKE 'seed-%' AND id != 'seed-7'")
      .bind(Math.floor(Date.now() / DAY))
      .run();
    for (let i = 0; i < 5; i++) {
      const res = await metered("/v1/faxes", { token: sender.token, body: { text: `probe ${i}` } });
      expect(res.cost.read, "hard upper bound, independent of pool size").toBeLessThan(700);
      expect(res.cost.queries).toBeLessThanOrEqual(10);
    }
  });

  it("matching queued lines for a connecting device is bounded by its daily room (5), not by the queue length", async () => {
    // 灌 300 条已排队的线路
    const now = Date.now();
    for (let i = 0; i < 300; i += 50) {
      const stmts: D1PreparedStatement[] = [];
      for (let j = i; j < i + 50; j++) {
        stmts.push(
          env.DB.prepare(
            `INSERT INTO lines (id, state, initiator_id, initiator_alias, created_at, updated_at, expires_at)
             VALUES (?1, 'queued', ?2, 'AAAA', ?3, ?3, ?4)`,
          ).bind(`queued-${j}`, `ghost-${j}`, now - (300 - j) * 1000, now + 3 * DAY),
        );
        stmts.push(
          env.DB.prepare("INSERT INTO messages (id, line_id, sender_id, kind, text, sent_at) VALUES (?1, ?2, ?3, 'text', 'hi', ?4)").bind(
            `queued-msg-${j}`,
            `queued-${j}`,
            `ghost-${j}`,
            now,
          ),
        );
      }
      await env.DB.batch(stmts);
    }
    const c = await login();
    // 5 条配对：每条 保留名额 + 认领 + 补 to_id（RETURNING）≈ 3 次查询；加上登录、读设备、选队列
    within("session that matches 5 queued lines", c.cost, { queries: 25, read: 60, written: 45 });
    const matched = await env.DB.prepare("SELECT COUNT(*) AS n FROM lines WHERE recipient_id = ?1").bind(c.deviceId).first<{ n: number }>();
    expect(matched!.n).toBe(5);
  });

  it("an authenticated request refreshes last_seen at most once per 6 hours", async () => {
    const d = await login();
    await env.DB.prepare("UPDATE devices SET last_seen_at = ?1 WHERE id = ?2").bind(Date.now() - 5 * 3600_000, d.deviceId).run();
    expect((await metered("/v1/me", { token: d.token })).cost.written).toBe(0);
    await env.DB.prepare("UPDATE devices SET last_seen_at = ?1 WHERE id = ?2").bind(Date.now() - 7 * 3600_000, d.deviceId).run();
    const refreshed = await metered("/v1/me", { token: d.token });
    expect(refreshed.cost.written).toBeGreaterThan(0);
    expect(refreshed.cost.written).toBeLessThanOrEqual(3);
    expect((await metered("/v1/me", { token: d.token })).cost.written).toBe(0);
  });
});

describe("cron work is bounded", () => {
  it("an idle run is a handful of reads and no writes", async () => {
    await seedBigDatabase();
    const { env: menv, meter } = meteredEnv();
    await runMaintenance(menv, Date.now(), { demote: false });
    expect(meter.cost.queries).toBeLessThanOrEqual(3);
    expect(meter.cost.read).toBeLessThanOrEqual(5);
    expect(meter.cost.written).toBe(0);
  });

  it("a run over a big backlog does a capped amount of work and stays under the 50-query limit", async () => {
    const now = Date.now();
    const total = 400;
    for (let i = 0; i < total; i += 100) {
      const stmts: D1PreparedStatement[] = [];
      for (let j = i; j < i + 100; j++) {
        stmts.push(
          env.DB.prepare(
            `INSERT INTO lines (id, state, initiator_id, recipient_id, initiator_alias, recipient_alias, created_at, updated_at, matched_at, expires_at)
             VALUES (?1, 'delivered', ?2, ?3, 'AAAA', 'BBBB', ?4, ?4, ?4, ?5)`,
          ).bind(`due-${j}`, `ghost-a-${j}`, `ghost-b-${j}`, now - 8 * DAY, now - DAY + j),
        );
      }
      await env.DB.batch(stmts);
    }
    const { env: menv, meter } = meteredEnv();
    const first = await runMaintenance(menv, now, { demote: true });
    expect(first.linesClosed).toBe(MAINTENANCE_LIMITS.closeLines);
    expect(meter.cost.queries).toBeLessThanOrEqual(10);

    // 积压留给下一次运行，几次之后清空
    let closed = first.linesClosed;
    for (let run = 0; run < 5 && closed < total; run++) closed += (await runMaintenance(env, now, { demote: false })).linesClosed;
    expect(closed).toBe(total);
  });

  it("purging closed lines is capped per run", async () => {
    const now = Date.now();
    for (let j = 0; j < 40; j++) {
      await insertLine({ id: `old-${j}`, state: "closed", initiator: `g-${j}`, recipient: `h-${j}`, now: now - 40 * DAY, expiresAt: now - DAY });
    }
    const { env: menv, meter } = meteredEnv();
    const report = await runMaintenance(menv, now, { demote: false });
    expect(report.linesPurged).toBe(MAINTENANCE_LIMITS.purgeLines);
    expect(meter.cost.queries).toBeLessThanOrEqual(8);
    expect((await runMaintenance(env, now, { demote: false })).linesPurged).toBe(40 - MAINTENANCE_LIMITS.purgeLines);
  });
});

async function newIdentityFor(d: { deviceId: string }) {
  // 只为复用 Device.connect()：它只需要 token，不需要私钥
  return { privateKey: undefined as unknown as CryptoKey, publicKeyB64: "", deviceId: d.deviceId };
}
