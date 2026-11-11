import { env, exports } from "cloudflare:workers";

// ---------------------------------------------------------------------------
// base64url / 身份
// ---------------------------------------------------------------------------

export function b64u(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const enc = new TextEncoder();

export interface Identity {
  privateKey: CryptoKey;
  publicKeyB64: string;
  deviceId: string;
}

export async function newIdentity(): Promise<Identity> {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const raw = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", raw));
  return { privateKey: pair.privateKey, publicKeyB64: b64u(raw), deviceId: b64u(digest).slice(0, 22) };
}

export async function sign(identity: Identity, message: string): Promise<string> {
  const sig = await crypto.subtle.sign("Ed25519", identity.privateKey, enc.encode(message));
  return b64u(new Uint8Array(sig));
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

export interface ApiResult<T = any> {
  status: number;
  body: T;
  res: Response;
}

export async function rawFetch(path: string, init: RequestInit = {}): Promise<Response> {
  return exports.default.fetch(new Request(`http://notchfax.test${path}`, init));
}

export async function apiFetch(
  path: string,
  opts: { method?: string; token?: string; body?: unknown; headers?: Record<string, string> } = {},
): Promise<ApiResult> {
  const headers: Record<string, string> = { ...opts.headers };
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  let body: BodyInit | undefined;
  if (opts.body !== undefined) {
    headers["content-type"] ??= "application/json";
    body = typeof opts.body === "string" || opts.body instanceof Uint8Array ? (opts.body as BodyInit) : JSON.stringify(opts.body);
  }
  const res = await rawFetch(path, { method: opts.method ?? (opts.body !== undefined ? "POST" : "GET"), headers, body });
  if ((res.headers.get("content-type") ?? "").startsWith("image/")) {
    return { status: res.status, body: new Uint8Array(await res.arrayBuffer()), res };
  }
  const text = await res.text();
  let parsed: any = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = text;
  }
  return { status: res.status, body: parsed, res };
}

export async function createSessionFor(identity: Identity, timestamp = Date.now()): Promise<ApiResult> {
  return apiFetch("/v1/session", {
    body: { publicKey: identity.publicKeyB64, timestamp, signature: await sign(identity, `notchfax-session:${timestamp}`) },
  });
}

/** 一台已登录的“设备”，封装常用调用。 */
export class Device {
  constructor(
    readonly identity: Identity,
    public token: string,
  ) {}

  static async create(): Promise<Device> {
    const identity = await newIdentity();
    const res = await createSessionFor(identity);
    if (res.status !== 200) throw new Error(`session failed: ${JSON.stringify(res.body)}`);
    return new Device(identity, res.body.token);
  }

  get id(): string {
    return this.identity.deviceId;
  }

  call(path: string, opts: { method?: string; body?: unknown; headers?: Record<string, string> } = {}) {
    return apiFetch(path, { ...opts, token: this.token });
  }
  me() {
    return this.call("/v1/me");
  }
  fax(text: string) {
    return this.call("/v1/faxes", { body: { text } });
  }
  say(lineId: string, text: string) {
    return this.call(`/v1/lines/${lineId}/messages`, { body: { text } });
  }
  image(lineId: string, bytes: Uint8Array, contentType = "image/png") {
    return this.call(`/v1/lines/${lineId}/images`, { method: "POST", body: bytes, headers: { "content-type": contentType } });
  }
  tear(lineId: string, report = false) {
    return this.call(`/v1/lines/${lineId}/tear`, { body: { report } });
  }
  lines() {
    return this.call("/v1/lines");
  }
  inbox() {
    return this.call("/v1/inbox");
  }
  ack(messageId: string) {
    return this.call(`/v1/messages/${messageId}/ack`, { method: "POST" });
  }
  fetchImage(imageId: string) {
    return this.call(`/v1/images/${imageId}`);
  }
  connect(): Promise<WsClient> {
    return WsClient.connect(this.token);
  }
}

/** a 发第一封，b（唯一候选人）收到；b 回复后线路 connected。返回双方视角的线路 id（相同）。 */
export async function connectedPair(): Promise<{ a: Device; b: Device; lineId: string }> {
  const a = await Device.create();
  const b = await Device.create();
  const sent = await a.fax("hello stranger");
  if (sent.body.line.state !== "delivered") throw new Error("expected delivered");
  const lineId: string = sent.body.line.id;
  const reply = await b.say(lineId, "hi back");
  if (reply.body.line.state !== "connected") throw new Error("expected connected");
  return { a, b, lineId };
}

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

const openSockets = new Set<WsClient>();

export class WsClient {
  events: any[] = [];
  /** 收到的原始文本帧（未解析）。 */
  rawMessages: string[] = [];
  closeInfo: { code: number; reason: string } | null = null;
  private waiters: Array<() => void> = [];

  private constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (ev) => {
      this.rawMessages.push(ev.data as string);
      try {
        this.events.push(JSON.parse(ev.data as string));
      } catch {
        // 忽略非 JSON
      }
      this.wake();
    });
    ws.addEventListener("close", (ev) => {
      this.closeInfo = { code: ev.code, reason: ev.reason };
      this.wake();
    });
  }

  static async connect(token: string): Promise<WsClient> {
    const res = await rawFetch(`/v1/socket?token=${encodeURIComponent(token)}`, { headers: { Upgrade: "websocket" } });
    if (res.status !== 101 || !res.webSocket) throw new Error(`upgrade failed: ${res.status}`);
    res.webSocket.accept();
    const client = new WsClient(res.webSocket);
    openSockets.add(client);
    return client;
  }

  private wake() {
    const w = this.waiters;
    this.waiters = [];
    for (const fn of w) fn();
  }

  /** 等到出现满足条件的事件（已收到的也算）。 */
  async waitFor(pred: (e: any) => boolean, timeoutMs = 4000): Promise<any> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const found = this.events.find(pred);
      if (found) return found;
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`timed out waiting for event; got ${JSON.stringify(this.events)}`);
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, left);
        this.waiters.push(() => {
          clearTimeout(t);
          resolve();
        });
      });
    }
  }

  /** 等到收到满足条件的原始文本帧。 */
  async waitForRaw(pred: (raw: string) => boolean, timeoutMs = 4000): Promise<string> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const found = this.rawMessages.find(pred);
      if (found !== undefined) return found;
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`timed out waiting for raw frame; got ${JSON.stringify(this.rawMessages)}`);
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, left);
        this.waiters.push(() => {
          clearTimeout(t);
          resolve();
        });
      });
    }
  }

  async waitForClose(timeoutMs = 4000): Promise<{ code: number; reason: string }> {
    const deadline = Date.now() + timeoutMs;
    while (!this.closeInfo) {
      const left = deadline - Date.now();
      if (left <= 0) throw new Error("timed out waiting for close");
      await new Promise<void>((resolve) => {
        const t = setTimeout(resolve, left);
        this.waiters.push(() => {
          clearTimeout(t);
          resolve();
        });
      });
    }
    return this.closeInfo;
  }

  send(obj: unknown) {
    this.ws.send(JSON.stringify(obj));
  }

  close() {
    try {
      this.ws.close(1000, "test done");
    } catch {
      // 已关闭
    }
  }
}

export async function closeAllSockets(): Promise<void> {
  for (const client of openSockets) client.close();
  openSockets.clear();
}

// ---------------------------------------------------------------------------
// 数据库清理
// ---------------------------------------------------------------------------

export async function resetAll(): Promise<void> {
  await env.DB.batch(["reports", "images", "messages", "lines", "devices"].map((t) => env.DB.prepare(`DELETE FROM ${t}`)));
}

/** images 表（BLOB）里是否还有这张图。 */
export async function imageStored(imageId: string): Promise<boolean> {
  const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM images WHERE id = ?1").bind(imageId).first<{ n: number }>();
  return (row?.n ?? 0) > 0;
}

export async function imageCount(): Promise<number> {
  const row = await env.DB.prepare("SELECT COUNT(*) AS n FROM images").first<{ n: number }>();
  return row?.n ?? 0;
}

/** 直接往库里造一条线路（测试用，绕过配对）。 */
export async function insertLine(opts: {
  id: string;
  state?: "queued" | "delivered" | "connected" | "closed";
  initiator: string;
  recipient?: string | null;
  now?: number;
  expiresAt?: number;
  matchedAt?: number | null;
}): Promise<void> {
  const now = opts.now ?? Date.now();
  const state = opts.state ?? "delivered";
  const recipient = opts.recipient ?? null;
  await env.DB.prepare(
    `INSERT INTO lines (id, state, initiator_id, recipient_id, initiator_alias, recipient_alias,
                        created_at, updated_at, matched_at, closed_at, expires_at)
     VALUES (?1, ?2, ?3, ?4, '1111', ?5, ?6, ?6, ?7, ?8, ?9)`,
  )
    .bind(
      opts.id,
      state,
      opts.initiator,
      recipient,
      recipient ? "2222" : null,
      now,
      opts.matchedAt === undefined ? (recipient ? now : null) : opts.matchedAt,
      state === "closed" ? now : null,
      opts.expiresAt ?? now + 7 * 24 * 3600_000,
    )
    .run();
}

// ---------------------------------------------------------------------------
// PNG 构造
// ---------------------------------------------------------------------------

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (const b of bytes) c = CRC_TABLE[(c ^ b) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export function chunk(type: string, data: Uint8Array, opts: { badCrc?: boolean } = {}): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.length);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8);
  const crc = crc32(out.subarray(4, 8 + data.length));
  view.setUint32(8 + data.length, opts.badCrc ? (crc ^ 0xdeadbeef) >>> 0 : crc);
  return out;
}

async function zlibDeflate(data: Uint8Array): Promise<Uint8Array> {
  const cs = new CompressionStream("deflate");
  const writer = cs.writable.getWriter();
  void writer.write(data);
  void writer.close();
  return new Uint8Array(await new Response(cs.readable).arrayBuffer());
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let off = 0;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
}

export interface PngOptions {
  width?: number;
  height?: number;
  bitDepth?: number;
  colorType?: number;
  badIhdrCrc?: boolean;
  /** 在 IDAT 之前插入的额外数据块（例如很大的 tEXt）。 */
  extraChunks?: Uint8Array[];
  omitIend?: boolean;
  trailing?: Uint8Array;
}

const CHANNELS: Record<number, number> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

/** 构造一个结构完整的 PNG（默认 64×64 的 1-bit 灰度棋盘）。 */
export async function makePng(opts: PngOptions = {}): Promise<Uint8Array> {
  const width = opts.width ?? 64;
  const height = opts.height ?? 64;
  const bitDepth = opts.bitDepth ?? 1;
  const colorType = opts.colorType ?? 0;

  const ihdr = new Uint8Array(13);
  const view = new DataView(ihdr.buffer);
  view.setUint32(0, width);
  view.setUint32(4, height);
  ihdr[8] = bitDepth;
  ihdr[9] = colorType;

  const bitsPerPixel = bitDepth * (CHANNELS[colorType] ?? 1);
  const rowBytes = Math.ceil((width * bitsPerPixel) / 8);
  const raw = new Uint8Array(height * (rowBytes + 1));
  for (let y = 0; y < height; y++) {
    const base = y * (rowBytes + 1);
    raw[base] = 0; // filter: none
    for (let x = 0; x < rowBytes; x++) raw[base + 1 + x] = (x + y) % 2 === 0 ? 0xaa : 0x55;
  }

  const parts: Uint8Array[] = [
    new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr, { badCrc: opts.badIhdrCrc }),
    ...(opts.extraChunks ?? []),
    chunk("IDAT", await zlibDeflate(raw)),
  ];
  if (!opts.omitIend) parts.push(chunk("IEND", new Uint8Array(0)));
  if (opts.trailing) parts.push(opts.trailing);
  return concat(...parts);
}

export function textChunk(totalBytes: number): Uint8Array {
  return chunk("tEXt", new Uint8Array(totalBytes).fill(0x61));
}
