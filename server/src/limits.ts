import { DAY, HOUR } from "./util";

/** 已认证请求顺带刷新 last_seen 的最小间隔。只用于“最近 7 天活跃”的判断，不需要精确。 */
export const LAST_SEEN_REFRESH_MS = 6 * HOUR;

export const MAX_TEXT_CHARS = 500;

/** 每台设备每天新线路额度的默认值与上限（对方回复一次 +1）。 */
export const DEFAULT_NEW_FAXES_PER_DAY = 3;
export const MAX_NEW_FAXES_PER_DAY = 10;

/** 每台设备每天最多被配对收到的新线路数。 */
export const RECIPIENT_DAILY_LIMIT = 5;
/** 配对候选：最近 7 天活跃过。 */
export const ACTIVE_WINDOW_MS = 7 * DAY;

/** 每条线路每人每天最多发送的图片数。 */
export const IMAGES_PER_LINE_PER_DAY = 10;
/** 收件人确认后图片保留时长。 */
export const IMAGE_RETENTION_MS = 24 * HOUR;

/** 举报：窗口、阈值、暂停时长。 */
export const REPORT_WINDOW_MS = 7 * DAY;
export const REPORT_THRESHOLD = 3;
export const SUSPEND_DURATION_MS = 7 * DAY;

/** 线路超时。 */
export const QUEUED_TTL_MS = 72 * HOUR;
export const DELIVERED_TTL_MS = 7 * DAY;
export const CONNECTED_TTL_MS = 30 * DAY;

/** 线路关闭多久后，连同其全部消息元数据一起从数据库里清掉（含未被确认的内容）。 */
export const CLOSED_RETENTION_MS = 30 * DAY;
