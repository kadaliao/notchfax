import type { AppEnv, ServerEvent } from "./types";

/**
 * 向设备的 WebSocket 推送事件。尽力而为：设备不在线或推送失败都不影响 HTTP 请求的结果，
 * 消息本身已经持久化，离线设备通过 GET /v1/inbox 补齐。
 *
 * `online` 是调用方从 D1 里顺带读到的在线标记。标记为离线就不去叫醒 Durable Object——
 * 免费套餐里 Durable Object 每天只有 10 万次请求，不能把它浪费在没人在线的设备上。
 * 返回送达的连接数。
 */
export async function pushEvents(
  env: AppEnv,
  deviceId: string,
  events: ServerEvent[],
  online: boolean | number | null | undefined,
): Promise<number> {
  if (events.length === 0 || !online) return 0;
  try {
    const stub = env.DEVICE_SOCKET.get(env.DEVICE_SOCKET.idFromName(deviceId));
    return await stub.push(deviceId, events);
  } catch {
    return 0;
  }
}
