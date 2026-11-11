import { DurableObject } from "cloudflare:workers";
import type { AppEnv, ServerEvent } from "./types";

/** 每 30 秒发一次 ping；100 秒内没有收到客户端任何消息（pong）就认为连接已死并关闭。 */
const PING_INTERVAL_MS = 30_000;
const DEAD_AFTER_MS = 100_000;

interface Attachment {
  lastSeen: number;
}

/**
 * 每台设备一个实例（idFromName(deviceId)），持有该设备的 WebSocket（Hibernation API）。
 * 新连接会顶掉旧连接。在线状态写入 D1 的 devices.online，供配对时“优先在线”使用。
 */
export class DeviceSocket extends DurableObject<AppEnv> {
  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const deviceId = request.headers.get("x-device-id");
    if (!deviceId) return new Response("missing device", { status: 400 });

    // 同一设备新连接顶掉旧连接
    for (const old of this.ctx.getWebSockets()) {
      try {
        old.close(4000, "replaced by a newer connection");
      } catch {
        // 已经关闭
      }
    }

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ lastSeen: Date.now() } satisfies Attachment);

    await this.ctx.storage.put("deviceId", deviceId);
    await this.env.DB.prepare("UPDATE devices SET online = 1, last_seen_at = ?1 WHERE id = ?2")
      .bind(Date.now(), deviceId)
      .run();
    await this.ctx.storage.setAlarm(Date.now() + PING_INTERVAL_MS);

    return new Response(null, { status: 101, webSocket: client });
  }

  /** 由 Worker 通过 RPC 调用：把事件推给这台设备当前所有存活的连接，返回送达的连接数。 */
  async push(events: ServerEvent[]): Promise<number> {
    let delivered = 0;
    for (const ws of this.liveSockets()) {
      try {
        for (const event of events) ws.send(JSON.stringify(event));
        delivered++;
      } catch {
        // 发送失败视为连接已死，交给 close/alarm 清理
      }
    }
    if (delivered === 0) await this.markOffline();
    return delivered;
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // 客户端只会发 {"type":"pong"}；任何消息都视为存活信号，其余内容忽略。
    ws.serializeAttachment({ lastSeen: Date.now() } satisfies Attachment);
    if (typeof message === "string" && message.length > 1024) ws.close(1009, "message too large");
  }

  override async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    try {
      ws.close(safeCloseCode(code), "closing");
    } catch {
      // 已经关闭
    }
    await this.afterSocketGone(ws);
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    try {
      ws.close(1011, "error");
    } catch {
      // 已经关闭
    }
    await this.afterSocketGone(ws);
  }

  override async alarm(): Promise<void> {
    const now = Date.now();
    let alive = 0;
    for (const ws of this.liveSockets()) {
      const att = ws.deserializeAttachment() as Attachment | null;
      if (!att || now - att.lastSeen > DEAD_AFTER_MS) {
        try {
          ws.close(4001, "heartbeat timeout");
        } catch {
          // 已经关闭
        }
        continue;
      }
      try {
        ws.send(JSON.stringify({ type: "ping" } satisfies ServerEvent));
        alive++;
      } catch {
        // 发送失败，下一轮清理
      }
    }
    if (alive > 0) {
      await this.ctx.storage.setAlarm(now + PING_INTERVAL_MS);
    } else {
      await this.markOffline();
    }
  }

  private liveSockets(except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets().filter((ws) => ws !== except && ws.readyState === WebSocket.OPEN);
  }

  private async afterSocketGone(gone: WebSocket): Promise<void> {
    if (this.liveSockets(gone).length === 0) await this.markOffline();
  }

  private async markOffline(): Promise<void> {
    const deviceId = await this.ctx.storage.get<string>("deviceId");
    if (!deviceId) return;
    await this.env.DB.prepare("UPDATE devices SET online = 0, last_seen_at = ?1 WHERE id = ?2 AND online = 1")
      .bind(Date.now(), deviceId)
      .run();
  }
}

function safeCloseCode(code: number): number {
  if (code === 1005 || code === 1006 || code === 1015) return 1000;
  if (code < 1000 || code >= 5000) return 1000;
  return code;
}
