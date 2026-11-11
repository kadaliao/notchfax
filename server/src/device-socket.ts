import { DurableObject } from "cloudflare:workers";
import type { AppEnv, ServerEvent } from "./types";

/** 心跳帧必须逐字节一致（见 docs/protocol.md §4）：客户端发 PING，服务器回 PONG。 */
export const PING_FRAME = '{"type":"ping"}';
export const PONG_FRAME = '{"type":"pong"}';

interface Attachment {
  deviceId: string;
}

/**
 * 每台设备一个实例（idFromName(deviceId)），持有该设备的 WebSocket（Hibernation API）。
 *
 * 免费套餐友好：
 *  - 心跳由客户端发起，服务器用 setWebSocketAutoResponse 在不唤醒对象的情况下回 pong；
 *  - 没有任何定时器（不用 alarm），也不写 Durable Object 自己的存储；
 *  - 对象只在新连接、推送事件、连接关闭时才会被唤醒。
 *
 * 在线状态写入 D1 的 devices.online（只在 0→1 / 1→0 变化时写），供配对时“优先在线”使用。
 */
export class DeviceSocket extends DurableObject<AppEnv> {
  constructor(ctx: DurableObjectState, env: AppEnv) {
    super(ctx, env);
    // 每次实例化（包括从休眠中醒来）都重新登记；对象本身没有状态，登记是幂等的
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING_FRAME, PONG_FRAME));
  }

  override async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const deviceId = request.headers.get("x-device-id");
    if (!deviceId) return new Response("missing device", { status: 400 });

    // 同一设备新连接顶掉旧连接，关闭码 4000（客户端收到后不应自动重连）
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
    server.serializeAttachment({ deviceId } satisfies Attachment);

    // 只在离线 → 在线时写库；顶掉旧连接（本来就在线）不产生任何写入
    await this.env.DB.prepare("UPDATE devices SET online = 1 WHERE id = ?1 AND online = 0").bind(deviceId).run();

    return new Response(null, { status: 101, webSocket: client });
  }

  /** 由 Worker 通过 RPC 调用：把事件推给这台设备当前所有存活的连接，返回送达的连接数。 */
  async push(deviceId: string, events: ServerEvent[]): Promise<number> {
    let delivered = 0;
    for (const ws of this.liveSockets()) {
      try {
        for (const event of events) ws.send(JSON.stringify(event));
        delivered++;
      } catch {
        // 发送失败视为连接已死，交给 close 事件清理
      }
    }
    // 标记说在线，但其实一个存活连接都没有：纠正标记，之后不再来叫醒这个对象
    if (delivered === 0) await this.markOffline(deviceId);
    return delivered;
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // 标准心跳帧由 auto-response 处理，走不到这里。到这里的只有：
    //  - 格式略有出入的 ping（比如多了空格）——也回一个 pong，客户端不会因此误判断线；
    //  - 其他内容——协议里客户端只会发 ping，忽略。
    if (typeof message !== "string" || message.length > 1024) return;
    try {
      const parsed: unknown = JSON.parse(message);
      if (parsed && typeof parsed === "object" && (parsed as { type?: unknown }).type === "ping") ws.send(PONG_FRAME);
    } catch {
      // 不是 JSON，忽略
    }
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

  private liveSockets(except?: WebSocket): WebSocket[] {
    return this.ctx.getWebSockets().filter((ws) => ws !== except && ws.readyState === WebSocket.OPEN);
  }

  private async afterSocketGone(gone: WebSocket): Promise<void> {
    const att = gone.deserializeAttachment() as Attachment | null;
    if (att?.deviceId && this.liveSockets(gone).length === 0) await this.markOffline(att.deviceId);
  }

  private async markOffline(deviceId: string): Promise<void> {
    await this.env.DB.prepare("UPDATE devices SET online = 0 WHERE id = ?1 AND online = 1").bind(deviceId).run();
  }
}

function safeCloseCode(code: number): number {
  if (code === 1005 || code === 1006 || code === 1015) return 1000;
  if (code < 1000 || code >= 5000) return 1000;
  return code;
}
