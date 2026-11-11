import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { connectedPair, Device, makePng, rawFetch } from "./helpers";

async function isOnline(device: Device): Promise<boolean> {
  const row = await env.DB.prepare("SELECT online FROM devices WHERE id = ?1").bind(device.id).first<{ online: number }>();
  return row?.online === 1;
}

async function until(cond: () => Promise<boolean>, timeoutMs = 3000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!(await cond())) {
    if (Date.now() > deadline) throw new Error("condition not met in time");
    await new Promise((r) => setTimeout(r, 25));
  }
}

describe("GET /v1/socket", () => {
  it("requires a valid token and a WebSocket upgrade", async () => {
    const device = await Device.create();
    const noUpgrade = await rawFetch(`/v1/socket?token=${device.token}`);
    expect(noUpgrade.status).toBe(426);

    const noToken = await rawFetch("/v1/socket", { headers: { Upgrade: "websocket" } });
    expect(noToken.status).toBe(401);
    expect((await noToken.json<any>()).error.code).toBe("unauthorized");

    const bad = await rawFetch("/v1/socket?token=garbage", { headers: { Upgrade: "websocket" } });
    expect(bad.status).toBe(401);
    expect(bad.webSocket).toBeNull();
  });

  it("marks the device online while connected and offline after it disconnects", async () => {
    const device = await Device.create();
    expect(await isOnline(device)).toBe(false);
    const socket = await device.connect();
    expect(await isOnline(device)).toBe(true);
    socket.close();
    await until(async () => !(await isOnline(device)));
  });
});

describe("WebSocket events", () => {
  it("pushes `fax` for a new line's first message", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const socket = await b.connect();

    const sent = await a.fax("knock knock");
    const event = await socket.waitFor((e) => e.type === "fax");
    expect(event.line).toMatchObject({ id: sent.body.line.id, state: "delivered", role: "recipient" });
    expect(event.line.myAlias).toBe(sent.body.line.peerAlias);
    expect(event.line.peerAlias).toBe(sent.body.line.myAlias);
    expect(event.message).toMatchObject({
      id: sent.body.message.id,
      lineId: sent.body.line.id,
      from: "peer",
      kind: "text",
      text: "knock knock",
    });
  });

  it("pushes `line.updated` (connected) and `fax` to the initiator when the recipient replies", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const aSocket = await a.connect();
    const sent = await a.fax("hello");
    const reply = await b.say(sent.body.line.id, "hi!");

    const updated = await aSocket.waitFor((e) => e.type === "line.updated");
    expect(updated.line).toMatchObject({ id: sent.body.line.id, state: "connected", role: "initiator" });
    const fax = await aSocket.waitFor((e) => e.type === "fax");
    expect(fax.message).toMatchObject({ id: reply.body.message.id, from: "peer", text: "hi!" });
    expect(fax.line.state).toBe("connected");
    // 状态变化先于消息
    expect(aSocket.events.findIndex((e) => e.type === "line.updated")).toBeLessThan(
      aSocket.events.findIndex((e) => e.type === "fax"),
    );
  });

  it("pushes follow-up texts and images as `fax` events", async () => {
    const { a, b, lineId } = await connectedPair();
    const bSocket = await b.connect();
    await a.say(lineId, "text after connect");
    const text = await bSocket.waitFor((e) => e.type === "fax" && e.message.kind === "text");
    expect(text.message.text).toBe("text after connect");

    const up = await a.image(lineId, await makePng({ width: 120, height: 80 }));
    const image = await bSocket.waitFor((e) => e.type === "fax" && e.message.kind === "image");
    expect(image.message).toMatchObject({
      id: up.body.message.id,
      from: "peer",
      imageId: up.body.message.imageId,
      width: 120,
      height: 80,
    });
    expect(image.message.text).toBeUndefined();
    // 推送里给出的 imageId 可以直接取到图片
    expect((await b.fetchImage(image.message.imageId)).status).toBe(200);
  });

  it("does not push anything to the sender about its own messages", async () => {
    const a = await Device.create();
    await Device.create();
    const aSocket = await a.connect();
    await a.fax("hello");
    await new Promise((r) => setTimeout(r, 100));
    expect(aSocket.events.filter((e) => e.type === "fax")).toEqual([]);
  });

  it("messages sent while the device is offline are not lost: they are in the inbox when it reconnects", async () => {
    const { a, b, lineId } = await connectedPair();
    const socket = await b.connect();
    socket.close();
    await until(async () => !(await isOnline(b)));
    await a.say(lineId, "sent while offline");

    const inbox = await b.inbox();
    expect(inbox.body.messages.map((m: any) => m.text)).toContain("sent while offline");
    const reconnected = await b.connect();
    expect(reconnected.events.filter((e) => e.type === "fax")).toEqual([]); // 不重复推送，靠 inbox 补齐
  });

  it("a new socket for the same device replaces the old one", async () => {
    const a = await Device.create();
    const b = await Device.create();
    const first = await b.connect();
    const second = await b.connect();

    const closed = await first.waitForClose();
    expect(closed.code).toBe(4000);
    expect(await isOnline(b)).toBe(true); // 被顶掉的旧连接不会把设备标为离线

    await a.fax("who gets this?");
    await second.waitFor((e) => e.type === "fax");
    expect(first.events.filter((e) => e.type === "fax")).toEqual([]);
  });

  it("answers the client's heartbeat with the exact pong frame, without the server ever pinging first", async () => {
    const device = await Device.create();
    const raw = await device.connect();
    raw.ws.send('{"type":"ping"}');
    const pong = await raw.waitForRaw((m) => m === '{"type":"pong"}');
    expect(pong).toBe('{"type":"pong"}');
    // 服务器从不主动发心跳：等一会儿，除了 pong 以外不会有别的帧
    await new Promise((r) => setTimeout(r, 150));
    expect(raw.rawMessages).toEqual(['{"type":"pong"}']);
  });

  it("keeps answering heartbeats after the Durable Object has been evicted (hibernation)", async () => {
    const device = await Device.create();
    const socket = await device.connect();
    const stub = env.DEVICE_SOCKET.get(env.DEVICE_SOCKET.idFromName(device.id));
    await evictDurableObject(stub);
    socket.ws.send('{"type":"ping"}');
    await socket.waitForRaw((m) => m === '{"type":"pong"}');
    // 休眠醒来后仍能收到推送
    const other = await Device.create();
    await other.fax("wake up");
    const fax = await socket.waitFor((e) => e.type === "fax");
    expect(fax.message.text).toBe("wake up");
  });

  it("answers a heartbeat that differs in whitespace too, so a sloppy client is not mistaken for dead", async () => {
    const device = await Device.create();
    const socket = await device.connect();
    socket.ws.send('{ "type": "ping" }');
    await socket.waitForRaw((m) => m === '{"type":"pong"}');
  });

  it("never schedules an alarm and never writes Durable Object storage", async () => {
    const device = await Device.create();
    const socket = await device.connect();
    const other = await Device.create();
    await other.fax("hello");
    await socket.waitFor((e) => e.type === "fax");
    socket.ws.send('{"type":"ping"}');
    await socket.waitForRaw((m) => m === '{"type":"pong"}');
    const stub = env.DEVICE_SOCKET.get(env.DEVICE_SOCKET.idFromName(device.id));
    const state = await runInDurableObject(stub, async (_instance, ctx) => ({
      alarm: await ctx.storage.getAlarm(),
      keys: [...(await ctx.storage.list()).keys()],
    }));
    expect(state.alarm).toBeNull();
    expect(state.keys).toEqual([]);
  });

  it("stays connected without any client traffic for as long as the test runs (no server-side timeout)", async () => {
    const device = await Device.create();
    const socket = await device.connect();
    await new Promise((r) => setTimeout(r, 300));
    expect(socket.closeInfo).toBeNull();
    expect(await isOnline(device)).toBe(true);
  });
});
