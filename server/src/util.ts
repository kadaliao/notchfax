export const SECOND = 1000;
export const MINUTE = 60 * SECOND;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

/** UTC 日序号。额度按 UTC 日重置，惰性计算，不需要定时任务。 */
export function dayIndex(ms: number): number {
  return Math.floor(ms / DAY);
}

export function dayStart(ms: number): number {
  return dayIndex(ms) * DAY;
}

export function nextDayStart(ms: number): number {
  return dayStart(ms) + DAY;
}

const B64URL_RE = /^[A-Za-z0-9_-]*$/;

export function base64urlEncode(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]!);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** 严格解码：非法字符或长度返回 null。 */
export function base64urlDecode(input: string): Uint8Array | null {
  if (!B64URL_RE.test(input) || input.length % 4 === 1) return null;
  const b64 = input.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (input.length % 4)) % 4);
  try {
    const bin = atob(b64);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

export function randomId(): string {
  return crypto.randomUUID();
}

/** 4 位大写十六进制别名，如 `A3F2`。每条线路每一方独立随机，与设备无关。 */
export function randomAlias(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(2));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0"))
    .join("")
    .toUpperCase();
}

/**
 * 读取请求体并限制最大字节数。超限返回 null（不会把超大的体读进内存）。
 */
export async function readBodyLimited(request: Request, maxBytes: number): Promise<Uint8Array | null> {
  const declared = request.headers.get("content-length");
  if (declared !== null) {
    const n = Number(declared);
    if (Number.isFinite(n) && n > maxBytes) return null;
  }
  if (!request.body) return new Uint8Array(0);
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      return null;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    out.set(c, off);
    off += c.byteLength;
  }
  return out;
}

/** JSON 体解析；非法、过大或不是对象都返回 null。 */
export async function readJsonObject(request: Request, maxBytes = 16 * 1024): Promise<Record<string, unknown> | null> {
  const bytes = await readBodyLimited(request, maxBytes);
  if (!bytes || bytes.length === 0) return null;
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (value && typeof value === "object" && !Array.isArray(value)) return value as Record<string, unknown>;
    return null;
  } catch {
    return null;
  }
}
