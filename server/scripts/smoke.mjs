#!/usr/bin/env node
// 冒烟测试：对着正在运行的 `pnpm dev`（默认 http://127.0.0.1:8787）走一遍完整流程。
//   创建两个身份 → 发传真 → 回复 → 上传 1-bit PNG → 取回图片 → 撕掉线路
// 用法：pnpm smoke            （BASE_URL 可覆盖地址）
// 注意：每次运行会在本地 D1 里留下两台一次性设备；想清空本地数据：rm -rf .wrangler/state

import { generateKeyPairSync, sign } from "node:crypto";
import { deflateSync } from "node:zlib";

const BASE = (process.env.BASE_URL ?? "http://127.0.0.1:8787").replace(/\/$/, "");
const WS_BASE = BASE.replace(/^http/, "ws");

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

let passed = 0;
let failed = 0;
const failures = [];

function ok(name) {
  passed++;
  console.log(`  PASS  ${name}`);
}

function fail(name, detail) {
  failed++;
  failures.push(name);
  console.log(`  FAIL  ${name}  -- ${String(detail).slice(0, 300)}`);
}

/** 断言；失败只记录不抛出，让后面能看到更多结果。detail 只在失败时打印。返回是否通过。 */
function check(name, cond, detail = "condition was false") {
  if (cond) ok(name);
  else fail(name, detail);
  return Boolean(cond);
}

class Abort extends Error {}
function must(name, cond, detail = "") {
  if (!check(name, cond, detail)) throw new Abort(`cannot continue after failed step: ${name}`);
}

const b64u = (buf) => Buffer.from(buf).toString("base64url");

function newIdentity() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const raw = Buffer.from(publicKey.export({ format: "jwk" }).x, "base64url"); // 32 字节原始公钥
  return { privateKey, publicKeyB64: b64u(raw) };
}

async function api(token, method, path, body, headers = {}) {
  const h = { ...headers };
  if (token) h.authorization = `Bearer ${token}`;
  let payload;
  if (body instanceof Uint8Array) payload = body;
  else if (body !== undefined) {
    h["content-type"] = "application/json";
    payload = JSON.stringify(body);
  }
  const res = await fetch(`${BASE}${path}`, { method, headers: h, body: payload });
  const buf = Buffer.from(await res.arrayBuffer());
  const type = res.headers.get("content-type") ?? "";
  let json = null;
  if (type.includes("json")) {
    try {
      json = JSON.parse(buf.toString("utf8"));
    } catch {
      json = null;
    }
  }
  return { status: res.status, json, bytes: buf, type };
}

async function login(label) {
  const id = newIdentity();
  const timestamp = Date.now();
  const signature = b64u(sign(null, Buffer.from(`notchfax-session:${timestamp}`), id.privateKey));
  const res = await api(null, "POST", "/v1/session", { publicKey: id.publicKeyB64, timestamp, signature });
  must(`${label}: POST /v1/session`, res.status === 200 && res.json?.token, `status ${res.status}`);
  return { label, token: res.json.token, deviceId: res.json.deviceId, id };
}

/**
 * 一个带事件收集的 WebSocket 连接。
 * 心跳由客户端发起：发送逐字节固定的文本帧 {"type":"ping"}，服务器回 {"type":"pong"}（见 docs/protocol.md §4）。
 */
const PING_FRAME = '{"type":"ping"}';
const PONG_FRAME = '{"type":"pong"}';

function connectSocket(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WS_BASE}/v1/socket?token=${encodeURIComponent(token)}`);
    const events = []; // 解析后的 JSON 帧（不含 pong）
    const frames = []; // 所有原始文本帧
    let closed = null;
    const waiters = [];
    ws.addEventListener("message", (ev) => {
      frames.push(String(ev.data));
      try {
        const msg = JSON.parse(ev.data);
        if (msg.type !== "pong") events.push(msg);
      } catch {
        // 非 JSON 帧忽略
      }
      for (const w of [...waiters]) w();
    });
    ws.addEventListener("close", (ev) => {
      closed = { code: ev.code, reason: ev.reason };
      for (const w of [...waiters]) w();
    });
    const waitUntil = (test, timeoutMs, describe) =>
      new Promise((res, rej) => {
        const poll = () => {
          const hit = test();
          if (hit !== undefined && hit !== false) {
            waiters.splice(waiters.indexOf(poll), 1);
            clearTimeout(timer);
            res(hit);
          }
        };
        const timer = setTimeout(() => {
          waiters.splice(waiters.indexOf(poll), 1);
          rej(new Error(`${describe} not seen within ${timeoutMs} ms; frames: ${JSON.stringify(frames).slice(0, 300)}`));
        }, timeoutMs);
        waiters.push(poll);
        poll();
      });
    const socket = {
      events,
      frames,
      get closed() {
        return closed;
      },
      close: () => ws.close(1000),
      waitFor: (pred, timeoutMs = 4000) => waitUntil(() => events.find(pred), timeoutMs, "event"),
      /** 发一个心跳，等一个 pong。返回 pong 的原始文本。 */
      async ping(timeoutMs = 4000) {
        const before = frames.filter((f) => f === PONG_FRAME).length;
        ws.send(PING_FRAME);
        await waitUntil(() => frames.filter((f) => f === PONG_FRAME).length > before, timeoutMs, "pong");
        return PONG_FRAME;
      },
      waitForClose: (timeoutMs = 4000) => waitUntil(() => closed ?? undefined, timeoutMs, "close"),
    };
    ws.addEventListener("open", () => resolve(socket));
    ws.addEventListener("error", () => reject(new Error("WebSocket connection failed")));
  });
}

// ---------------------------------------------------------------------------
// PNG：1-bit 灰度，结构完整（IHDR / IDAT / IEND，带 CRC）
// ---------------------------------------------------------------------------

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buf) {
  let c = 0xffffffff;
  for (const byte of buf) c = CRC_TABLE[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function pngChunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "ascii");
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}
function makePng({ width, height, bitDepth = 1, colorType = 0 }) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = bitDepth;
  ihdr[9] = colorType;
  const rowBytes = Math.ceil((width * bitDepth * (colorType === 2 ? 3 : 1)) / 8);
  const raw = Buffer.alloc(height * (rowBytes + 1));
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < rowBytes; x++) raw[y * (rowBytes + 1) + 1 + x] = ((x >> 1) + (y >> 3)) % 2 === 0 ? 0xf0 : 0x0f; // 棋盘格
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

// ---------------------------------------------------------------------------
// 流程
// ---------------------------------------------------------------------------

async function main() {
  console.log(`Notchfax smoke test against ${BASE}\n`);

  try {
    const health = await fetch(`${BASE}/healthz`);
    must("server is reachable (GET /healthz)", health.status === 200, `status ${health.status}`);
  } catch (err) {
    if (err instanceof Abort) throw err;
    console.log(`  FAIL  cannot reach ${BASE}: ${err.cause?.code ?? err.message}`);
    console.log("        start the server first:  pnpm dev");
    process.exit(2);
  }

  console.log("\nidentities");
  const alice = await login("alice");
  const bob = await login("bob");
  must("deviceIds differ", alice.deviceId !== bob.deviceId);
  const me = await api(alice.token, "GET", "/v1/me");
  check("alice: GET /v1/me quota is 3/day", me.json?.quota?.newFaxesPerDay === 3 && me.json?.suspendedUntil === null);

  console.log("\nsockets");
  const bobSocket = await connectSocket(bob.token); // bob 在线 → 配对时优先选他
  const aliceFirst = await connectSocket(alice.token);
  ok("both WebSockets connected");
  try {
    const pong = await bobSocket.ping();
    check('client ping {"type":"ping"} -> server replies {"type":"pong"}', pong === PONG_FRAME);
    await aliceFirst.ping();
    ok("heartbeat works on both sockets");
  } catch (err) {
    fail("client ping -> pong", err.message);
  }
  // 同一设备的新连接顶掉旧连接，旧连接收到关闭码 4000
  const aliceSocket = await connectSocket(alice.token);
  try {
    const closed = await aliceFirst.waitForClose();
    check("second socket for the same device replaces the first (close code 4000)", closed.code === 4000, `code=${closed.code}`);
  } catch (err) {
    fail("old socket closed with 4000 on replacement", err.message);
  }

  console.log("\nfax + reply");
  const sent = await api(alice.token, "POST", "/v1/faxes", { text: "  smoke test: hello stranger  " });
  must("alice: POST /v1/faxes -> 202", sent.status === 202, `status ${sent.status} ${JSON.stringify(sent.json)}`);
  const lineId = sent.json.line.id;
  must(
    "line is delivered with distinct aliases",
    sent.json.line.state === "delivered" && /^[0-9A-F]{4}$/.test(sent.json.line.myAlias) && sent.json.line.peerAlias !== sent.json.line.myAlias,
    `state=${sent.json.line.state}`,
  );
  check("first message text is trimmed", sent.json.message.text === "smoke test: hello stranger" && sent.json.message.from === "me");

  let delivered = true;
  try {
    const push = await bobSocket.waitFor((e) => e.type === "fax");
    check("bob receives `fax` over WebSocket", push.line.id === lineId && push.message.from === "peer", `text="${push.message.text}"`);
  } catch (err) {
    delivered = false;
    fail(
      "bob receives `fax` over WebSocket",
      `${err.message}. The fax went to another device in the local DB; reset it with: rm -rf .wrangler/state`,
    );
  }
  if (!delivered) throw new Abort("fax was not delivered to bob");

  const early = await api(alice.token, "POST", `/v1/lines/${lineId}/images`, makePng({ width: 64, height: 64 }), { "content-type": "image/png" });
  check("image before connected -> 403 line_not_connected", early.status === 403 && early.json?.error?.code === "line_not_connected", `status ${early.status}`);

  const again = await api(alice.token, "POST", `/v1/lines/${lineId}/messages`, { text: "are you there?" });
  check("initiator second message -> 403 awaiting_reply", again.status === 403 && again.json?.error?.code === "awaiting_reply", `status ${again.status}`);

  const inbox = await api(bob.token, "GET", "/v1/inbox");
  check("bob: GET /v1/inbox lists the fax", inbox.json?.messages?.length === 1 && inbox.json.lines?.[0]?.id === lineId);
  const ack = await api(bob.token, "POST", `/v1/messages/${inbox.json.messages[0].id}/ack`);
  check("bob: ack -> 204", ack.status === 204, `status ${ack.status}`);
  const inbox2 = await api(bob.token, "GET", "/v1/inbox");
  check("inbox is empty after ack", inbox2.json?.messages?.length === 0);

  const reply = await api(bob.token, "POST", `/v1/lines/${lineId}/messages`, { text: "hello back!" });
  must("bob: reply -> 201, line connected", reply.status === 201 && reply.json?.line?.state === "connected", `status ${reply.status}`);
  try {
    const upd = await aliceSocket.waitFor((e) => e.type === "line.updated" && e.line.state === "connected");
    const fax = await aliceSocket.waitFor((e) => e.type === "fax" && e.message.text === "hello back!");
    check("alice receives line.updated(connected) + fax", upd.line.id === lineId && fax.message.from === "peer");
  } catch (err) {
    fail("alice receives line.updated(connected) + fax", err.message);
  }
  const me2 = await api(alice.token, "GET", "/v1/me");
  check("alice's daily cap rose to 4", me2.json?.quota?.newFaxesPerDay === 4, `cap=${me2.json?.quota?.newFaxesPerDay}`);

  console.log("\nimage");
  const bad = await api(alice.token, "POST", `/v1/lines/${lineId}/images`, makePng({ width: 64, height: 64, bitDepth: 8, colorType: 0 }), { "content-type": "image/png" });
  check("8-bit PNG -> 400 invalid_image", bad.status === 400 && bad.json?.error?.code === "invalid_image", `status ${bad.status}`);
  const wide = await api(alice.token, "POST", `/v1/lines/${lineId}/images`, makePng({ width: 400, height: 10 }), { "content-type": "image/png" });
  check("400 px wide PNG -> 400 invalid_image", wide.status === 400 && wide.json?.error?.code === "invalid_image", `status ${wide.status}`);

  const png = makePng({ width: 384, height: 256 });
  const up = await api(alice.token, "POST", `/v1/lines/${lineId}/images`, png, { "content-type": "image/png" });
  must("alice: upload valid 1-bit PNG -> 201", up.status === 201 && up.json?.message?.kind === "image", `status ${up.status} ${JSON.stringify(up.json)}`);
  check("image metadata has width/height", up.json.message.width === 384 && up.json.message.height === 256);
  const imageId = up.json.message.imageId;

  try {
    const push = await bobSocket.waitFor((e) => e.type === "fax" && e.message.kind === "image");
    check("bob receives the image `fax` event", push.message.imageId === imageId);
  } catch (err) {
    fail("bob receives the image `fax` event", err.message);
  }

  const got = await api(bob.token, "GET", `/v1/images/${imageId}`);
  check("bob: GET /v1/images/:id returns identical PNG bytes", got.status === 200 && got.type.startsWith("image/png") && Buffer.compare(got.bytes, png) === 0, `status ${got.status}, ${got.bytes.length} bytes`);
  const noAuth = await api(null, "GET", `/v1/images/${imageId}`);
  check("image without token -> 401", noAuth.status === 401, `status ${noAuth.status}`);

  console.log("\ntear");
  const tear = await api(alice.token, "POST", `/v1/lines/${lineId}/tear`, { report: false });
  check("alice: tear -> 200 closed", tear.status === 200 && tear.json?.line?.state === "closed", `status ${tear.status}`);
  try {
    const closed = await bobSocket.waitFor((e) => e.type === "line.updated" && e.line.state === "closed");
    check("bob receives line.updated(closed)", closed.line.id === lineId);
  } catch (err) {
    fail("bob receives line.updated(closed)", err.message);
  }
  const after = await api(bob.token, "POST", `/v1/lines/${lineId}/messages`, { text: "hello?" });
  check("message on closed line -> 409 line_closed", after.status === 409 && after.json?.error?.code === "line_closed", `status ${after.status}`);
  const lines = await api(bob.token, "GET", "/v1/lines");
  check("closed line is gone from GET /v1/lines", Array.isArray(lines.json?.lines) && lines.json.lines.length === 0);

  aliceSocket.close();
  bobSocket.close();
}

try {
  await main();
} catch (err) {
  if (!(err instanceof Abort)) {
    failed++;
    failures.push("unexpected error");
    console.log(`  FAIL  unexpected error: ${err?.stack ?? err}`);
  }
}

console.log(`\n${failed === 0 ? "SMOKE PASSED" : "SMOKE FAILED"}: ${passed} passed, ${failed} failed`);
if (failures.length) console.log(`failed: ${failures.join("; ")}`);
console.log("(two throwaway devices remain in the local D1; reset with: rm -rf .wrangler/state)");
process.exit(failed === 0 ? 0 : 1);
