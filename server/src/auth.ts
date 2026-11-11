import { Errors } from "./errors";
import { base64urlDecode, base64urlEncode, MINUTE, DAY } from "./util";

export const SESSION_MAX_SKEW_MS = 5 * MINUTE;
export const TOKEN_TTL_MS = DAY;

const encoder = new TextEncoder();

/** deviceId = base64url(SHA-256(公钥原始 32 字节)) 的前 22 个字符。 */
export async function deviceIdFromPublicKey(publicKey: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", publicKey);
  return base64urlEncode(new Uint8Array(digest)).slice(0, 22);
}

export function sessionMessage(timestamp: number): string {
  return `notchfax-session:${timestamp}`;
}

/** 校验 POST /v1/session 的请求体，通过则返回设备公钥与 deviceId。 */
export async function verifySessionRequest(
  body: Record<string, unknown> | null,
  now: number,
): Promise<{ publicKey: Uint8Array; deviceId: string }> {
  if (!body) throw Errors.badSignature("request body must be a JSON object");
  const timestamp = body.timestamp;
  if (typeof timestamp !== "number" || !Number.isInteger(timestamp)) throw Errors.staleTimestamp();
  if (Math.abs(now - timestamp) > SESSION_MAX_SKEW_MS) throw Errors.staleTimestamp();

  const publicKeyB64 = body.publicKey;
  const signatureB64 = body.signature;
  if (typeof publicKeyB64 !== "string" || typeof signatureB64 !== "string") {
    throw Errors.badSignature("publicKey and signature are required");
  }
  const publicKey = base64urlDecode(publicKeyB64);
  const signature = base64urlDecode(signatureB64);
  if (!publicKey || publicKey.length !== 32) throw Errors.badSignature("publicKey must be 32 bytes (base64url)");
  if (!signature || signature.length !== 64) throw Errors.badSignature("signature must be 64 bytes (base64url)");

  let ok = false;
  try {
    const key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
    ok = await crypto.subtle.verify("Ed25519", key, signature, encoder.encode(sessionMessage(timestamp)));
  } catch {
    ok = false;
  }
  if (!ok) throw Errors.badSignature();
  return { publicKey, deviceId: await deviceIdFromPublicKey(publicKey) };
}

// ---- 会话令牌：base64url(payload JSON) + "." + base64url(HMAC-SHA256(secret, payload)) ----

interface TokenPayload {
  d: string; // deviceId
  i: number; // issuedAt
  e: number; // expiresAt
}

const hmacKeys = new Map<string, Promise<CryptoKey>>();

function hmacKey(secret: string): Promise<CryptoKey> {
  let key = hmacKeys.get(secret);
  if (!key) {
    key = crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
      "sign",
      "verify",
    ]);
    hmacKeys.set(secret, key);
  }
  return key;
}

function requireSecret(secret: string | undefined): string {
  if (!secret) throw new Error("SESSION_SECRET is not configured");
  return secret;
}

export async function signToken(secret: string | undefined, deviceId: string, issuedAt: number, expiresAt: number) {
  const payload: TokenPayload = { d: deviceId, i: issuedAt, e: expiresAt };
  const body = base64urlEncode(encoder.encode(JSON.stringify(payload)));
  const key = await hmacKey(requireSecret(secret));
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(body)));
  return `${body}.${base64urlEncode(sig)}`;
}

/** 返回 deviceId。格式错/签名错 → unauthorized；签名对但已过期 → token_expired。 */
export async function verifyToken(secret: string | undefined, token: string, now: number): Promise<string> {
  const parts = token.split(".");
  if (parts.length !== 2) throw Errors.unauthorized();
  const [body, sigB64] = parts as [string, string];
  const sig = base64urlDecode(sigB64);
  const raw = base64urlDecode(body);
  if (!sig || !raw) throw Errors.unauthorized();
  const key = await hmacKey(requireSecret(secret));
  const valid = await crypto.subtle.verify("HMAC", key, sig, encoder.encode(body));
  if (!valid) throw Errors.unauthorized();
  let payload: TokenPayload;
  try {
    payload = JSON.parse(new TextDecoder().decode(raw)) as TokenPayload;
  } catch {
    throw Errors.unauthorized();
  }
  if (typeof payload.d !== "string" || typeof payload.e !== "number") throw Errors.unauthorized();
  if (now >= payload.e) throw Errors.tokenExpired();
  return payload.d;
}
