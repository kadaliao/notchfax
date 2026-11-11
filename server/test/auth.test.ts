import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { signToken } from "../src/auth";
import { apiFetch, createSessionFor, Device, newIdentity, sign } from "./helpers";

describe("POST /v1/session", () => {
  it("issues a token for a valid signature and derives the deviceId from the public key", async () => {
    const identity = await newIdentity();
    const before = Date.now();
    const res = await createSessionFor(identity);
    expect(res.status).toBe(200);
    expect(res.body.deviceId).toBe(identity.deviceId);
    expect(res.body.deviceId).toHaveLength(22);
    expect(typeof res.body.token).toBe("string");
    // 令牌有效 24 小时
    expect(res.body.expiresAt).toBeGreaterThanOrEqual(before + 24 * 3600_000);
    expect(res.body.expiresAt).toBeLessThanOrEqual(Date.now() + 24 * 3600_000);

    const me = await apiFetch("/v1/me", { token: res.body.token });
    expect(me.status).toBe(200);
    expect(me.body.deviceId).toBe(identity.deviceId);
  });

  it("rejects a signature made over a different message", async () => {
    const identity = await newIdentity();
    const timestamp = Date.now();
    const res = await apiFetch("/v1/session", {
      body: { publicKey: identity.publicKeyB64, timestamp, signature: await sign(identity, `notchfax-session:${timestamp + 1}`) },
    });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("bad_signature");
  });

  it("rejects a signature made by a different key", async () => {
    const claimed = await newIdentity();
    const attacker = await newIdentity();
    const timestamp = Date.now();
    const res = await apiFetch("/v1/session", {
      body: { publicKey: claimed.publicKeyB64, timestamp, signature: await sign(attacker, `notchfax-session:${timestamp}`) },
    });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("bad_signature");
  });

  it("rejects malformed keys and signatures as bad_signature", async () => {
    const identity = await newIdentity();
    const timestamp = Date.now();
    const good = await sign(identity, `notchfax-session:${timestamp}`);
    for (const body of [
      { publicKey: "AAAA", timestamp, signature: good },
      { publicKey: identity.publicKeyB64, timestamp, signature: "AAAA" },
      { publicKey: "!!!not-base64!!!", timestamp, signature: good },
      { timestamp, signature: good },
    ]) {
      const res = await apiFetch("/v1/session", { body });
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe("bad_signature");
    }
  });

  it("rejects timestamps more than 5 minutes from server time (past and future)", async () => {
    const identity = await newIdentity();
    for (const skew of [-6 * 60_000, 6 * 60_000]) {
      const res = await createSessionFor(identity, Date.now() + skew);
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe("stale_timestamp");
    }
    // 4 分钟以内可以
    expect((await createSessionFor(identity, Date.now() - 4 * 60_000)).status).toBe(200);
  });

  it("rejects a missing or non-object body", async () => {
    for (const body of ["", "not json", "[]", "null"]) {
      const res = await apiFetch("/v1/session", { method: "POST", body: body || undefined, headers: { "content-type": "application/json" } });
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe("bad_signature");
    }
  });

  it("does not store IP addresses or any request metadata", async () => {
    const identity = await newIdentity();
    const timestamp = Date.now();
    const signature = await sign(identity, `notchfax-session:${timestamp}`);
    const marker = "203.0.113.77";
    const session = await apiFetch("/v1/session", {
      body: { publicKey: identity.publicKeyB64, timestamp, signature },
      headers: { "cf-connecting-ip": marker, "x-forwarded-for": marker, "x-real-ip": marker, "user-agent": "marker-agent" },
    });
    const token = session.body.token;
    await apiFetch("/v1/faxes", {
      token,
      body: { text: "hello" },
      headers: { "cf-connecting-ip": marker, "x-forwarded-for": marker },
    });
    const dump: string[] = [];
    for (const table of ["devices", "lines", "messages", "reports"]) {
      const { results } = await env.DB.prepare(`SELECT * FROM ${table}`).all();
      dump.push(JSON.stringify(results));
    }
    const all = dump.join("\n");
    expect(all).not.toContain(marker);
    expect(all).not.toContain("marker-agent");
    // devices 表里只有公钥、时间戳和计数器
    const cols = await env.DB.prepare("PRAGMA table_info(devices)").all<{ name: string }>();
    expect(cols.results.map((c) => c.name).sort()).toEqual(
      [
        "created_at", "id", "last_seen_at", "new_faxes_per_day", "new_faxes_used", "online",
        "public_key", "quota_day", "recv_count", "recv_day", "rnd", "suspended_until",
      ].sort(),
    );
  });

  it("is idempotent: the same device can open sessions repeatedly", async () => {
    const identity = await newIdentity();
    const one = await createSessionFor(identity);
    const two = await createSessionFor(identity);
    expect(one.body.deviceId).toBe(two.body.deviceId);
    const { results } = await env.DB.prepare("SELECT COUNT(*) AS n FROM devices").all<{ n: number }>();
    expect(results[0]!.n).toBe(1);
  });
});

describe("bearer token", () => {
  it("requires a token", async () => {
    const res = await apiFetch("/v1/me");
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("unauthorized");
  });

  it("rejects garbage and tampered tokens as unauthorized", async () => {
    const device = await Device.create();
    const [payload, sig] = device.token.split(".") as [string, string];
    const forgedPayload = btoa(JSON.stringify({ d: device.id, i: 0, e: Date.now() + 1e9 }))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
    for (const token of ["garbage", "a.b", `${forgedPayload}.${sig}`, `${payload}.${sig.slice(0, -2)}AA`, ""]) {
      const res = await apiFetch("/v1/me", { token: token || undefined, headers: token ? {} : { authorization: "Bearer" } });
      expect(res.status).toBe(401);
      expect(res.body.error.code).toBe("unauthorized");
    }
  });

  it("rejects an expired token with token_expired", async () => {
    const device = await Device.create();
    const now = Date.now();
    const expired = await signToken(env.SESSION_SECRET, device.id, now - 25 * 3600_000, now - 1000);
    const res = await apiFetch("/v1/me", { token: expired });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("token_expired");
  });

  it("rejects a validly signed token for a device that does not exist", async () => {
    const now = Date.now();
    const token = await signToken(env.SESSION_SECRET, "nonexistent-device-id0", now, now + 3600_000);
    const res = await apiFetch("/v1/me", { token });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("unauthorized");
  });

  it("rejects a token signed with another secret", async () => {
    const device = await Device.create();
    const now = Date.now();
    const foreign = await signToken("some-other-secret", device.id, now, now + 3600_000);
    const res = await apiFetch("/v1/me", { token: foreign });
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe("unauthorized");
  });
});

describe("GET /v1/me", () => {
  it("reports the default quota and no suspension", async () => {
    const device = await Device.create();
    const res = await device.me();
    expect(res.status).toBe(200);
    expect(res.body.deviceId).toBe(device.id);
    expect(res.body.quota.newFaxesPerDay).toBe(3);
    expect(res.body.quota.newFaxesLeft).toBe(3);
    expect(res.body.quota.resetsAt).toBeGreaterThan(Date.now());
    expect(res.body.quota.resetsAt - Date.now()).toBeLessThanOrEqual(24 * 3600_000);
    expect(res.body.suspendedUntil).toBeNull();
  });
});

describe("routing", () => {
  it("returns a JSON not_found error for unknown routes", async () => {
    const device = await Device.create();
    const res = await device.call("/v1/nope");
    expect(res.status).toBe(404);
    expect(res.body.error.code).toBe("not_found");
  });
});
