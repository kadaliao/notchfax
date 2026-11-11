import type { AppEnv, ServerEvent } from "./types";

/**
 * 向设备的 WebSocket 推送事件（尽力而为：设备不在线或推送失败都不影响 HTTP 请求结果，
 * 消息本身已经持久化，离线设备通过 GET /v1/inbox 补齐）。返回送达的连接数。
 */
export async function pushEvents(env: AppEnv, deviceId: string, events: ServerEvent[]): Promise<number> {
  if (events.length === 0) return 0;
  try {
    const stub = env.DEVICE_SOCKET.get(env.DEVICE_SOCKET.idFromName(deviceId));
    return await stub.push(events);
  } catch {
    return 0;
  }
}
