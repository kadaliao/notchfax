import { signToken, TOKEN_TTL_MS, verifySessionRequest, verifyToken } from "./auth";
import { DeviceSocket } from "./device-socket";
import { ApiError, errorResponse, Errors } from "./errors";
import {
  ackMessage,
  getDevice,
  getImage,
  getInbox,
  listLines,
  matchQueuedFor,
  meView,
  runMaintenance,
  sendFax,
  sendImage,
  sendMessage,
  tearLine,
  touchDevice,
  upsertDevice,
} from "./service";
import type { AppEnv, DeviceRow } from "./types";
import { base64urlEncode, readJsonObject } from "./util";

export { DeviceSocket };

// 注意：这里不读取、不记录请求的 IP（CF-Connecting-IP 等头）；日志只写错误消息本身。

async function authenticate(request: Request, env: AppEnv, now: number, tokenOverride?: string): Promise<DeviceRow> {
  let token = tokenOverride;
  if (!token) {
    const header = request.headers.get("authorization") ?? "";
    const match = /^Bearer\s+(\S+)$/i.exec(header);
    if (!match) throw Errors.unauthorized();
    token = match[1]!;
  }
  const deviceId = await verifyToken(env.SESSION_SECRET, token, now);
  const device = await getDevice(env, deviceId);
  if (!device) throw Errors.unauthorized("unknown device");
  await touchDevice(env, device, now);
  return device;
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}

async function route(request: Request, env: AppEnv, ctx: ExecutionContext): Promise<Response> {
  const url = new URL(request.url);
  const method = request.method;
  const now = Date.now();
  const path = url.pathname.replace(/\/+$/, "") || "/";
  const segments = path.split("/").filter(Boolean); // ["v1", "lines", ":id", "tear"]

  if (path === "/healthz" && method === "GET") return json({ ok: true });

  if (segments[0] !== "v1") throw Errors.notFound("no such endpoint");
  const [, resource, id, action] = segments;

  // POST /v1/session
  if (resource === "session" && segments.length === 2) {
    if (method !== "POST") throw Errors.notFound("no such endpoint");
    const { publicKey, deviceId } = await verifySessionRequest(await readJsonObject(request), now);
    await upsertDevice(env, deviceId, base64urlEncode(publicKey), now);
    const expiresAt = now + TOKEN_TTL_MS;
    const token = await signToken(env.SESSION_SECRET, deviceId, now, expiresAt);
    // 设备打开会话时，把排队中的传真配给它
    await matchQueuedFor(env, deviceId, now);
    return json({ token, expiresAt, deviceId });
  }

  // GET /v1/socket?token=...
  if (resource === "socket" && segments.length === 2) {
    if (method !== "GET") throw Errors.notFound("no such endpoint");
    if (request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
      return errorResponse(426, "not_found", "expected a WebSocket upgrade");
    }
    const device = await authenticate(request, env, now, url.searchParams.get("token") ?? undefined);
    const stub = env.DEVICE_SOCKET.get(env.DEVICE_SOCKET.idFromName(device.id));
    const upgrade = new Request("https://device-socket.internal/connect", {
      headers: { Upgrade: "websocket", "x-device-id": device.id },
    });
    const response = await stub.fetch(upgrade);
    // 新连接建立后，把排队中的传真配给这台设备（它会通过新连接收到 fax 事件）
    ctx.waitUntil(matchQueuedFor(env, device.id, Date.now()).catch(() => undefined));
    return response;
  }

  // 以下全部需要 Bearer 令牌
  const device = await authenticate(request, env, now);

  if (resource === "me" && segments.length === 2 && method === "GET") {
    return json(meView(device, now));
  }

  if (resource === "faxes" && segments.length === 2 && method === "POST") {
    const body = await readJsonObject(request);
    return json(await sendFax(env, device, body?.text, now), 202);
  }

  if (resource === "lines" && segments.length === 2 && method === "GET") {
    return json({ lines: await listLines(env, device.id, now) });
  }

  if (resource === "lines" && id && action === "messages" && segments.length === 4 && method === "POST") {
    const body = await readJsonObject(request);
    return json(await sendMessage(env, device, id, body?.text, now), 201);
  }

  if (resource === "lines" && id && action === "images" && segments.length === 4 && method === "POST") {
    return json(await sendImage(env, device, id, request, now), 201);
  }

  if (resource === "lines" && id && action === "tear" && segments.length === 4 && method === "POST") {
    const body = await readJsonObject(request);
    const line = await tearLine(env, device, id, body?.report === true, now);
    return json({ line });
  }

  if (resource === "images" && id && segments.length === 3 && method === "GET") {
    return getImage(env, device.id, id, now);
  }

  if (resource === "inbox" && segments.length === 2 && method === "GET") {
    return json(await getInbox(env, device.id));
  }

  if (resource === "messages" && id && action === "ack" && segments.length === 4 && method === "POST") {
    await ackMessage(env, device.id, id, now);
    return new Response(null, { status: 204 });
  }

  throw Errors.notFound("no such endpoint");
}

export default {
  async fetch(request, env, ctx): Promise<Response> {
    try {
      return await route(request, env as AppEnv, ctx);
    } catch (err) {
      if (err instanceof ApiError) return errorResponse(err.status, err.code, err.message);
      console.error("unhandled error:", err instanceof Error ? err.message : String(err));
      return errorResponse(500, "internal", "internal error");
    }
  },

  async scheduled(controller, env, ctx): Promise<void> {
    ctx.waitUntil(
      runMaintenance(env as AppEnv, Math.max(Date.now(), controller.scheduledTime)).catch((err) => {
        console.error("maintenance failed:", err instanceof Error ? err.message : String(err));
      }),
    );
  },
} satisfies ExportedHandler<Env>;
