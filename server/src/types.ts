import type { DeviceSocket } from "./device-socket";

export interface AppEnv extends Cloudflare.Env {
  SESSION_SECRET: string;
  DB: D1Database;
  DEVICE_SOCKET: DurableObjectNamespace<DeviceSocket>;
}

// ---- 协议里的数据对象（见 docs/protocol.md 第 5 节）----

export type LineState = "queued" | "delivered" | "connected" | "closed";

export interface LineView {
  id: string;
  state: LineState;
  role: "initiator" | "recipient";
  myAlias: string;
  peerAlias: string | null;
  createdAt: number;
  updatedAt: number;
}

export interface MessageView {
  id: string;
  lineId: string;
  from: "me" | "peer";
  kind: "text" | "image";
  text?: string;
  imageId?: string;
  width?: number;
  height?: number;
  sentAt: number;
}

/** 服务器主动推送的帧。心跳的 pong 由 Durable Object 的 auto-response 直接回复，不经过这里。 */
export type ServerEvent =
  | { type: "fax"; line: LineView; message: MessageView }
  | { type: "line.updated"; line: LineView };

// ---- D1 行 ----

export interface DeviceRow {
  id: string;
  public_key: string;
  created_at: number;
  last_seen_at: number;
  online: number;
  suspended_until: number | null;
  new_faxes_per_day: number;
  quota_day: number;
  new_faxes_used: number;
  rnd: number | null;
  recv_day: number;
  recv_count: number;
}

export interface LineRow {
  id: string;
  state: LineState;
  initiator_id: string;
  recipient_id: string | null;
  initiator_alias: string;
  recipient_alias: string | null;
  created_at: number;
  updated_at: number;
  matched_at: number | null;
  closed_at: number | null;
  /** 未关闭：下一个超时时间点；已关闭：清理时间点。 */
  expires_at: number;
}

/** 带对端在线标记的线路行（读线路时顺带取，用来决定要不要去叫醒对方的 Durable Object）。 */
export interface LineWithPresence extends LineRow {
  peer_online: number | null;
}

export interface MessageRow {
  id: string;
  line_id: string;
  sender_id: string;
  to_id: string | null;
  kind: "text" | "image";
  text: string | null;
  image_id: string | null;
  width: number | null;
  height: number | null;
  sent_at: number;
  acked_at: number | null;
  image_expires_at: number | null;
}
