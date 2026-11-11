import { Errors } from "./errors";
import {
  ACTIVE_WINDOW_MS,
  CLOSED_RETENTION_MS,
  CONNECTED_TTL_MS,
  DELIVERED_TTL_MS,
  IMAGES_PER_LINE_PER_DAY,
  IMAGE_RETENTION_MS,
  MAX_NEW_FAXES_PER_DAY,
  MAX_TEXT_CHARS,
  QUEUED_TTL_MS,
  RECIPIENT_DAILY_LIMIT,
  REPORT_THRESHOLD,
  REPORT_WINDOW_MS,
  SUSPEND_DURATION_MS,
} from "./limits";
import { pushEvents } from "./notify";
import { MAX_IMAGE_BYTES, validateFaxPng } from "./png";
import type { AppEnv, DeviceRow, LineRow, LineView, MessageRow, MessageView } from "./types";
import { dayIndex, dayStart, nextDayStart, randomAlias, randomId, readBodyLimited } from "./util";
import { isParticipant, lineView, messageView, peerOf } from "./views";

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

function changes(result: D1Result): number {
  return result.meta.changes ?? 0;
}

export function isSuspended(device: DeviceRow, now: number): boolean {
  return device.suspended_until !== null && device.suspended_until > now;
}

function assertNotSuspended(device: DeviceRow, now: number): void {
  if (isSuspended(device, now)) throw Errors.suspended();
}

/** 去掉首尾空白后 1–500 个 Unicode 标量。 */
export function validateText(input: unknown): string {
  if (typeof input !== "string") throw Errors.invalidText();
  const text = input.trim();
  let count = 0;
  for (const _ of text) {
    count++;
    if (count > MAX_TEXT_CHARS) throw Errors.invalidText();
  }
  if (count < 1) throw Errors.invalidText();
  return text;
}

function isExpired(line: LineRow, now: number): boolean {
  switch (line.state) {
    case "queued":
      return now - line.created_at >= QUEUED_TTL_MS;
    case "delivered":
      return now - (line.matched_at ?? line.created_at) >= DELIVERED_TTL_MS;
    case "connected":
      return now - line.last_message_at >= CONNECTED_TTL_MS;
    default:
      return false;
  }
}

// ---------------------------------------------------------------------------
// 设备与额度
// ---------------------------------------------------------------------------

export async function getDevice(env: AppEnv, id: string): Promise<DeviceRow | null> {
  return env.DB.prepare("SELECT * FROM devices WHERE id = ?1").bind(id).first<DeviceRow>();
}

export async function upsertDevice(env: AppEnv, id: string, publicKeyB64: string, now: number): Promise<void> {
  await env.DB.prepare(
    `INSERT INTO devices (id, public_key, created_at, last_seen_at) VALUES (?1, ?2, ?3, ?3)
     ON CONFLICT (id) DO UPDATE SET last_seen_at = excluded.last_seen_at`,
  )
    .bind(id, publicKeyB64, now)
    .run();
}

/** 已认证请求顺带刷新“最近活跃”，5 分钟内不重复写库。 */
export async function touchDevice(env: AppEnv, device: DeviceRow, now: number): Promise<void> {
  if (now - device.last_seen_at < 5 * 60_000) return;
  await env.DB.prepare("UPDATE devices SET last_seen_at = ?1 WHERE id = ?2").bind(now, device.id).run();
}

export function meView(device: DeviceRow, now: number) {
  const used = device.quota_day === dayIndex(now) ? device.new_faxes_used : 0;
  return {
    deviceId: device.id,
    quota: {
      newFaxesLeft: Math.max(0, device.new_faxes_per_day - used),
      newFaxesPerDay: device.new_faxes_per_day,
      resetsAt: nextDayStart(now),
    },
    suspendedUntil: isSuspended(device, now) ? device.suspended_until : null,
  };
}

/** 原子地占用一个新线路额度；额度用完返回 false。跨日自动从 0 开始（惰性重置）。 */
async function reserveFaxQuota(env: AppEnv, deviceId: string, now: number): Promise<boolean> {
  const today = dayIndex(now);
  const res = await env.DB.prepare(
    `UPDATE devices SET
       new_faxes_used = CASE WHEN quota_day = ?1 THEN new_faxes_used + 1 ELSE 1 END,
       quota_day = ?1
     WHERE id = ?2 AND (CASE WHEN quota_day = ?1 THEN new_faxes_used ELSE 0 END) < new_faxes_per_day`,
  )
    .bind(today, deviceId)
    .run();
  return changes(res) === 1;
}

async function refundFaxQuota(env: AppEnv, deviceId: string, now: number): Promise<void> {
  await env.DB.prepare(
    "UPDATE devices SET new_faxes_used = MAX(new_faxes_used - 1, 0) WHERE id = ?1 AND quota_day = ?2",
  )
    .bind(deviceId, dayIndex(now))
    .run();
}

// ---------------------------------------------------------------------------
// 线路读取
// ---------------------------------------------------------------------------

async function getLine(env: AppEnv, id: string): Promise<LineRow | null> {
  return env.DB.prepare("SELECT * FROM lines WHERE id = ?1").bind(id).first<LineRow>();
}

/** 读线路并要求调用者是参与者（否则 404）；顺带惰性处理超时，不用等定时任务。 */
async function loadParticipantLine(env: AppEnv, deviceId: string, lineId: string, now: number): Promise<LineRow> {
  let line = await getLine(env, lineId);
  if (!line || !isParticipant(line, deviceId)) throw Errors.notFound("line not found");
  if (isExpired(line, now)) {
    const closed = await closeLine(env, line, now);
    if (closed) await notifyClosed(env, closed, null);
    line = (await getLine(env, lineId)) ?? line;
  }
  return line;
}

// ---------------------------------------------------------------------------
// 关闭线路
// ---------------------------------------------------------------------------

/** 把线路置为 closed。只有真正发生状态变化时返回新行；已经 closed 返回 null。 */
async function closeLine(env: AppEnv, line: LineRow, now: number): Promise<LineRow | null> {
  const res = await env.DB.prepare(
    "UPDATE lines SET state = 'closed', closed_at = ?1, updated_at = ?1 WHERE id = ?2 AND state != 'closed'",
  )
    .bind(now, line.id)
    .run();
  if (changes(res) === 0) return null;
  if (line.recipient_id === null) {
    // 从未送达任何人的第一封：没人需要这段文字了，直接删
    await env.DB.prepare("UPDATE messages SET text = NULL, acked_at = ?1 WHERE line_id = ?2 AND acked_at IS NULL")
      .bind(now, line.id)
      .run();
  }
  return getLine(env, line.id);
}

/** 向线路双方（可排除一方）推送 line.updated。 */
async function notifyClosed(env: AppEnv, line: LineRow, except: string | null): Promise<void> {
  const targets = [line.initiator_id, line.recipient_id].filter((id): id is string => !!id && id !== except);
  await Promise.all(
    targets.map((id) => pushEvents(env, id, [{ type: "line.updated", line: lineView(line, id) }])),
  );
}

// ---------------------------------------------------------------------------
// 配对
// ---------------------------------------------------------------------------

const PAIR_BLOCK_SQL = `EXISTS (
  SELECT 1 FROM reports r
  WHERE (r.reporter_id = ?1 AND r.reported_id = %CAND%)
     OR (r.reporter_id = %CAND% AND r.reported_id = ?1)
)`;

/**
 * 为 senderId 的第一封挑一个收件人：最近 7 天活跃（或当前在线）、优先在线、随机。
 * 排除：自己、有过举报关系的设备、今天新线路已收满的设备、被暂停的设备。
 */
async function pickRecipient(env: AppEnv, senderId: string, now: number): Promise<string | null> {
  const row = await env.DB.prepare(
    `SELECT d.id AS id FROM devices d
     WHERE d.id != ?1
       AND (d.suspended_until IS NULL OR d.suspended_until <= ?2)
       AND (d.online = 1 OR d.last_seen_at >= ?3)
       AND NOT ${PAIR_BLOCK_SQL.replaceAll("%CAND%", "d.id")}
       AND (SELECT COUNT(*) FROM lines l WHERE l.recipient_id = d.id AND l.matched_at >= ?4) < ?5
     ORDER BY d.online DESC, RANDOM()
     LIMIT 1`,
  )
    .bind(senderId, now, now - ACTIVE_WINDOW_MS, dayStart(now), RECIPIENT_DAILY_LIMIT)
    .first<{ id: string }>();
  return row?.id ?? null;
}

/** 原子地把 queued 线路配对给收件人（同时再次检查收件人今日额度）。成功返回 true。 */
async function claimLine(env: AppEnv, line: LineRow, recipientId: string, now: number): Promise<boolean> {
  let alias = randomAlias();
  while (alias === line.initiator_alias) alias = randomAlias();
  const res = await env.DB.prepare(
    `UPDATE lines SET state = 'delivered', recipient_id = ?1, recipient_alias = ?2, matched_at = ?3, updated_at = ?3
     WHERE id = ?4 AND state = 'queued'
       AND (SELECT COUNT(*) FROM lines x WHERE x.recipient_id = ?1 AND x.matched_at >= ?5) < ?6`,
  )
    .bind(recipientId, alias, now, line.id, dayStart(now), RECIPIENT_DAILY_LIMIT)
    .run();
  return changes(res) === 1;
}

/** 给一条 queued 线路找收件人。返回配对后的线路行；没有合适的人返回 null。 */
async function matchLine(env: AppEnv, line: LineRow, now: number): Promise<LineRow | null> {
  for (let attempt = 0; attempt < 5; attempt++) {
    const candidate = await pickRecipient(env, line.initiator_id, now);
    if (!candidate) return null;
    if (await claimLine(env, line, candidate, now)) return getLine(env, line.id);
    const current = await getLine(env, line.id);
    if (!current || current.state !== "queued") return current && current.state !== "closed" ? current : null;
  }
  return null;
}

/** 配对成功后通知：收件人收到 fax（第一封），发起人（若不是正在等 HTTP 响应的那个）收到 line.updated。 */
async function announceMatch(env: AppEnv, line: LineRow, notifyInitiator: boolean): Promise<void> {
  if (!line.recipient_id) return;
  const first = await env.DB.prepare("SELECT * FROM messages WHERE line_id = ?1 ORDER BY sent_at ASC, rowid ASC LIMIT 1")
    .bind(line.id)
    .first<MessageRow>();
  const jobs: Promise<unknown>[] = [];
  if (first) {
    jobs.push(
      pushEvents(env, line.recipient_id, [
        { type: "fax", line: lineView(line, line.recipient_id), message: messageView(first, line.recipient_id) },
      ]),
    );
  }
  if (notifyInitiator) {
    jobs.push(pushEvents(env, line.initiator_id, [{ type: "line.updated", line: lineView(line, line.initiator_id) }]));
  }
  await Promise.all(jobs);
}

/**
 * 设备上线（建立会话或连接 socket）时：把排队中的线路按先来后到配给它，直到它今天的接收额度用完。
 */
export async function matchQueuedFor(env: AppEnv, deviceId: string, now: number): Promise<void> {
  const device = await getDevice(env, deviceId);
  if (!device || isSuspended(device, now)) return;

  const received = await env.DB.prepare("SELECT COUNT(*) AS n FROM lines WHERE recipient_id = ?1 AND matched_at >= ?2")
    .bind(deviceId, dayStart(now))
    .first<{ n: number }>();
  const room = RECIPIENT_DAILY_LIMIT - (received?.n ?? 0);
  if (room <= 0) return;

  const { results } = await env.DB.prepare(
    `SELECT * FROM lines
     WHERE state = 'queued' AND created_at > ?2 AND initiator_id != ?1
       AND NOT ${PAIR_BLOCK_SQL.replaceAll("%CAND%", "lines.initiator_id")}
     ORDER BY created_at ASC
     LIMIT ?3`,
  )
    .bind(deviceId, now - QUEUED_TTL_MS, room)
    .all<LineRow>();

  for (const queued of results) {
    if (await claimLine(env, queued, deviceId, now)) {
      const matched = await getLine(env, queued.id);
      if (matched) await announceMatch(env, matched, true);
    }
  }
}

// ---------------------------------------------------------------------------
// POST /v1/faxes
// ---------------------------------------------------------------------------

export async function sendFax(
  env: AppEnv,
  device: DeviceRow,
  rawText: unknown,
  now: number,
): Promise<{ line: LineView; message: MessageView }> {
  assertNotSuspended(device, now);
  const text = validateText(rawText);
  if (!(await reserveFaxQuota(env, device.id, now))) {
    throw Errors.quotaExceeded("daily new-fax quota used up");
  }

  const lineId = randomId();
  const messageId = randomId();
  try {
    await env.DB.batch([
      env.DB.prepare(
        `INSERT INTO lines (id, state, initiator_id, initiator_alias, created_at, updated_at, last_message_at)
         VALUES (?1, 'queued', ?2, ?3, ?4, ?4, ?4)`,
      ).bind(lineId, device.id, randomAlias(), now),
      env.DB.prepare(
        `INSERT INTO messages (id, line_id, sender_id, kind, text, sent_at) VALUES (?1, ?2, ?3, 'text', ?4, ?5)`,
      ).bind(messageId, lineId, device.id, text, now),
    ]);
  } catch (err) {
    await refundFaxQuota(env, device.id, now);
    throw err;
  }

  let line = (await getLine(env, lineId))!;
  const matched = await matchLine(env, line, now);
  if (matched) {
    line = matched;
    await announceMatch(env, line, false);
  }

  const message: MessageRow = {
    id: messageId,
    line_id: lineId,
    sender_id: device.id,
    kind: "text",
    text,
    image_id: null,
    width: null,
    height: null,
    sent_at: now,
    acked_at: null,
    image_expires_at: null,
    image_deleted: 0,
  };
  return { line: lineView(line, device.id), message: messageView(message, device.id) };
}

// ---------------------------------------------------------------------------
// POST /v1/lines/:id/messages
// ---------------------------------------------------------------------------

export async function sendMessage(
  env: AppEnv,
  device: DeviceRow,
  lineId: string,
  rawText: unknown,
  now: number,
): Promise<{ line: LineView; message: MessageView }> {
  let line = await loadParticipantLine(env, device.id, lineId, now);
  assertNotSuspended(device, now);

  const isInitiator = line.initiator_id === device.id;
  switch (line.state) {
    case "closed":
      throw Errors.lineClosed();
    case "queued":
      throw Errors.lineNotReady();
    case "delivered":
      if (isInitiator) throw Errors.awaitingReply();
      break;
    case "connected":
      break;
  }
  const text = validateText(rawText);

  let flipped = false;
  if (line.state === "delivered") {
    // 收件人回复：delivered → connected，并抬高发起人的每日额度上限
    const res = await env.DB.prepare(
      `UPDATE lines SET state = 'connected', connected_at = ?1, updated_at = ?1, last_message_at = ?1
       WHERE id = ?2 AND state = 'delivered'`,
    )
      .bind(now, line.id)
      .run();
    if (changes(res) === 1) {
      flipped = true;
      await env.DB.prepare("UPDATE devices SET new_faxes_per_day = MIN(new_faxes_per_day + 1, ?1) WHERE id = ?2")
        .bind(MAX_NEW_FAXES_PER_DAY, line.initiator_id)
        .run();
    }
  } else {
    await env.DB.prepare("UPDATE lines SET updated_at = ?1, last_message_at = ?1 WHERE id = ?2 AND state = 'connected'")
      .bind(now, line.id)
      .run();
  }
  // 并发下状态可能已变（被撕掉等），以库里的最终状态为准
  line = (await getLine(env, line.id)) ?? line;
  if (line.state === "closed") throw Errors.lineClosed();

  const messageId = randomId();
  await env.DB.prepare(
    `INSERT INTO messages (id, line_id, sender_id, kind, text, sent_at) VALUES (?1, ?2, ?3, 'text', ?4, ?5)`,
  )
    .bind(messageId, line.id, device.id, text, now)
    .run();

  const row: MessageRow = {
    id: messageId,
    line_id: line.id,
    sender_id: device.id,
    kind: "text",
    text,
    image_id: null,
    width: null,
    height: null,
    sent_at: now,
    acked_at: null,
    image_expires_at: null,
    image_deleted: 0,
  };

  const peerId = peerOf(line, device.id);
  if (peerId) {
    await pushEvents(env, peerId, [
      ...(flipped ? [{ type: "line.updated" as const, line: lineView(line, peerId) }] : []),
      { type: "fax", line: lineView(line, peerId), message: messageView(row, peerId) },
    ]);
  }
  return { line: lineView(line, device.id), message: messageView(row, device.id) };
}

// ---------------------------------------------------------------------------
// POST /v1/lines/:id/images
// ---------------------------------------------------------------------------

export async function sendImage(
  env: AppEnv,
  device: DeviceRow,
  lineId: string,
  request: Request,
  now: number,
): Promise<{ line: LineView; message: MessageView }> {
  let line = await loadParticipantLine(env, device.id, lineId, now);
  assertNotSuspended(device, now);
  // 核心规则：只有 connected 的线路能发图。先于读取请求体判断，未接通时不会碰上传内容。
  if (line.state !== "connected") throw Errors.lineNotConnected();

  const contentType = (request.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
  if (contentType !== "image/png") throw Errors.invalidImage("Content-Type must be image/png");
  const bytes = await readBodyLimited(request, MAX_IMAGE_BYTES);
  if (!bytes) throw Errors.invalidImage("image is larger than 64 KB");
  const check = validateFaxPng(bytes);
  if (!check.ok) throw Errors.invalidImage(check.reason);

  const imageId = randomId();
  const messageId = randomId();
  const key = imageKey(imageId);
  await env.IMAGES.put(key, bytes, { httpMetadata: { contentType: "image/png" } });

  // 每条线路每人每天最多 10 张：计数与插入在同一条语句里，避免并发突破上限
  const res = await env.DB.prepare(
    `INSERT INTO messages (id, line_id, sender_id, kind, image_id, width, height, sent_at)
     SELECT ?1, ?2, ?3, 'image', ?4, ?5, ?6, ?7
     WHERE (SELECT COUNT(*) FROM messages
            WHERE line_id = ?2 AND sender_id = ?3 AND kind = 'image' AND sent_at >= ?8) < ?9
       AND EXISTS (SELECT 1 FROM lines WHERE id = ?2 AND state = 'connected')`,
  )
    .bind(messageId, line.id, device.id, imageId, check.width, check.height, now, dayStart(now), IMAGES_PER_LINE_PER_DAY)
    .run();
  if (changes(res) === 0) {
    await env.IMAGES.delete(key);
    line = (await getLine(env, line.id)) ?? line;
    if (line.state !== "connected") throw Errors.lineNotConnected();
    throw Errors.quotaExceeded("at most 10 images per line per day");
  }

  await env.DB.prepare("UPDATE lines SET updated_at = ?1, last_message_at = ?1 WHERE id = ?2")
    .bind(now, line.id)
    .run();
  line = (await getLine(env, line.id)) ?? line;

  const row: MessageRow = {
    id: messageId,
    line_id: line.id,
    sender_id: device.id,
    kind: "image",
    text: null,
    image_id: imageId,
    width: check.width,
    height: check.height,
    sent_at: now,
    acked_at: null,
    image_expires_at: null,
    image_deleted: 0,
  };
  const peerId = peerOf(line, device.id);
  if (peerId) {
    await pushEvents(env, peerId, [
      { type: "fax", line: lineView(line, peerId), message: messageView(row, peerId) },
    ]);
  }
  return { line: lineView(line, device.id), message: messageView(row, device.id) };
}

function imageKey(imageId: string): string {
  return `images/${imageId}`;
}

// ---------------------------------------------------------------------------
// GET /v1/images/:id
// ---------------------------------------------------------------------------

export async function getImage(env: AppEnv, deviceId: string, imageId: string, now: number): Promise<Response> {
  const row = await env.DB.prepare(
    `SELECT m.image_expires_at AS expires_at, m.image_deleted AS deleted, l.initiator_id AS initiator_id, l.recipient_id AS recipient_id
     FROM messages m JOIN lines l ON l.id = m.line_id
     WHERE m.image_id = ?1`,
  )
    .bind(imageId)
    .first<{ expires_at: number | null; deleted: number; initiator_id: string; recipient_id: string | null }>();
  // 非参与者与不存在一样返回 404，不泄露图片是否存在
  if (!row || (row.initiator_id !== deviceId && row.recipient_id !== deviceId)) throw Errors.notFound("image not found");
  if (row.deleted === 1 || (row.expires_at !== null && row.expires_at <= now)) throw Errors.notFound("image not found");
  const object = await env.IMAGES.get(imageKey(imageId));
  if (!object) throw Errors.notFound("image not found");
  return new Response(object.body, {
    headers: {
      "content-type": "image/png",
      "content-length": String(object.size),
      "cache-control": "private, no-store",
    },
  });
}

// ---------------------------------------------------------------------------
// POST /v1/lines/:id/tear
// ---------------------------------------------------------------------------

export async function tearLine(
  env: AppEnv,
  device: DeviceRow,
  lineId: string,
  report: boolean,
  now: number,
): Promise<LineView> {
  let line = await loadParticipantLine(env, device.id, lineId, now);
  const peerId = peerOf(line, device.id);

  if (line.state !== "closed") {
    const closed = await closeLine(env, line, now);
    if (closed) {
      line = closed;
      // 撕掉的一方不再需要这条线路上还没确认的内容：文字删除，图片开始 24 小时倒计时
      await env.DB.prepare(
        `UPDATE messages SET text = NULL, acked_at = ?1,
           image_expires_at = CASE WHEN kind = 'image' THEN ?2 ELSE image_expires_at END
         WHERE line_id = ?3 AND sender_id != ?4 AND acked_at IS NULL`,
      )
        .bind(now, now + IMAGE_RETENTION_MS, line.id, device.id)
        .run();
      await notifyClosed(env, line, device.id);
    } else {
      line = (await getLine(env, line.id)) ?? line;
    }
  }

  if (report && peerId) await recordReport(env, line.id, device.id, peerId, now);
  return lineView(line, device.id);
}

async function recordReport(env: AppEnv, lineId: string, reporterId: string, reportedId: string, now: number) {
  const inserted = await env.DB.prepare(
    "INSERT OR IGNORE INTO reports (line_id, reporter_id, reported_id, created_at) VALUES (?1, ?2, ?3, ?4)",
  )
    .bind(lineId, reporterId, reportedId, now)
    .run();
  if (changes(inserted) === 0) return;
  const count = await env.DB.prepare(
    "SELECT COUNT(DISTINCT reporter_id) AS n FROM reports WHERE reported_id = ?1 AND created_at >= ?2",
  )
    .bind(reportedId, now - REPORT_WINDOW_MS)
    .first<{ n: number }>();
  if ((count?.n ?? 0) >= REPORT_THRESHOLD) {
    await env.DB.prepare(
      "UPDATE devices SET suspended_until = ?1 WHERE id = ?2 AND (suspended_until IS NULL OR suspended_until <= ?3)",
    )
      .bind(now + SUSPEND_DURATION_MS, reportedId, now)
      .run();
  }
}

// ---------------------------------------------------------------------------
// GET /v1/lines、GET /v1/inbox、POST /v1/messages/:id/ack
// ---------------------------------------------------------------------------

export async function listLines(env: AppEnv, deviceId: string, now: number): Promise<LineView[]> {
  const { results } = await env.DB.prepare(
    `SELECT * FROM lines WHERE (initiator_id = ?1 OR recipient_id = ?1) AND state != 'closed'
     ORDER BY updated_at DESC LIMIT 500`,
  )
    .bind(deviceId)
    .all<LineRow>();
  // 已超时但定时任务还没来得及关的线路，按已关闭处理
  return results.filter((l) => !isExpired(l, now)).map((l) => lineView(l, deviceId));
}

export async function getInbox(
  env: AppEnv,
  deviceId: string,
): Promise<{ messages: MessageView[]; lines: LineView[] }> {
  const { results: messages } = await env.DB.prepare(
    `SELECT m.* FROM messages m JOIN lines l ON l.id = m.line_id
     WHERE (l.initiator_id = ?1 OR l.recipient_id = ?1)
       AND m.sender_id != ?1 AND m.acked_at IS NULL
     ORDER BY m.sent_at ASC, m.rowid ASC
     LIMIT 500`,
  )
    .bind(deviceId)
    .all<MessageRow>();

  const lineIds = [...new Set(messages.map((m) => m.line_id))];
  const lines: LineRow[] = [];
  for (let i = 0; i < lineIds.length; i += 50) {
    const chunk = lineIds.slice(i, i + 50);
    const { results } = await env.DB.prepare(
      `SELECT * FROM lines WHERE id IN (${chunk.map((_, j) => `?${j + 1}`).join(",")})`,
    )
      .bind(...chunk)
      .all<LineRow>();
    lines.push(...results);
  }
  lines.sort((a, b) => a.created_at - b.created_at);
  return {
    messages: messages.map((m) => messageView(m, deviceId)),
    lines: lines.map((l) => lineView(l, deviceId)),
  };
}

export async function ackMessage(env: AppEnv, deviceId: string, messageId: string, now: number): Promise<void> {
  const row = await env.DB.prepare(
    `SELECT m.sender_id AS sender_id, m.acked_at AS acked_at, l.initiator_id AS initiator_id, l.recipient_id AS recipient_id
     FROM messages m JOIN lines l ON l.id = m.line_id WHERE m.id = ?1`,
  )
    .bind(messageId)
    .first<{ sender_id: string; acked_at: number | null; initiator_id: string; recipient_id: string | null }>();
  // 只有收件人（线路参与者且不是发送者）能确认；其他情况一律 404
  const isParticipantOfLine = row && (row.initiator_id === deviceId || row.recipient_id === deviceId);
  if (!row || !isParticipantOfLine || row.sender_id === deviceId) throw Errors.notFound("message not found");
  if (row.acked_at !== null) return; // 幂等
  await env.DB.prepare(
    `UPDATE messages SET text = NULL, acked_at = ?1,
       image_expires_at = CASE WHEN kind = 'image' THEN ?2 ELSE image_expires_at END
     WHERE id = ?3 AND acked_at IS NULL`,
  )
    .bind(now, now + IMAGE_RETENTION_MS, messageId)
    .run();
}

// ---------------------------------------------------------------------------
// 定时任务：线路超时、图片删除、旧线路清理
// ---------------------------------------------------------------------------

export interface MaintenanceReport {
  linesClosed: number;
  imagesDeleted: number;
  linesPurged: number;
}

export async function runMaintenance(env: AppEnv, now: number): Promise<MaintenanceReport> {
  const report: MaintenanceReport = { linesClosed: 0, imagesDeleted: 0, linesPurged: 0 };
  const BATCH = 200;

  // 1. 超时关闭：queued 72h、delivered 7d 无回复、connected 30d 无消息
  for (let round = 0; round < 25; round++) {
    const { results } = await env.DB.prepare(
      `SELECT * FROM lines
       WHERE state != 'closed' AND (
            (state = 'queued'    AND created_at <= ?1)
         OR (state = 'delivered' AND COALESCE(matched_at, created_at) <= ?2)
         OR (state = 'connected' AND last_message_at <= ?3))
       LIMIT ?4`,
    )
      .bind(now - QUEUED_TTL_MS, now - DELIVERED_TTL_MS, now - CONNECTED_TTL_MS, BATCH)
      .all<LineRow>();
    for (const line of results) {
      const closed = await closeLine(env, line, now);
      if (closed) {
        report.linesClosed++;
        await notifyClosed(env, closed, null);
      }
    }
    if (results.length < BATCH) break;
  }

  // 2. 删除到期图片（收件人确认 24 小时后）
  for (let round = 0; round < 25; round++) {
    const { results } = await env.DB.prepare(
      `SELECT id, image_id FROM messages
       WHERE image_expires_at IS NOT NULL AND image_expires_at <= ?1 AND image_deleted = 0 LIMIT ?2`,
    )
      .bind(now, BATCH)
      .all<{ id: string; image_id: string }>();
    if (results.length === 0) break;
    await env.IMAGES.delete(results.map((r) => imageKey(r.image_id)));
    await env.DB.batch(
      results.map((r) => env.DB.prepare("UPDATE messages SET image_deleted = 1 WHERE id = ?1").bind(r.id)),
    );
    report.imagesDeleted += results.length;
    if (results.length < BATCH) break;
  }

  // 3. 关闭超过 30 天的线路：连同消息（含一直没被确认的）和残留图片一起清掉
  for (let round = 0; round < 25; round++) {
    const { results: lines } = await env.DB.prepare(
      "SELECT id FROM lines WHERE state = 'closed' AND closed_at IS NOT NULL AND closed_at <= ?1 LIMIT ?2",
    )
      .bind(now - CLOSED_RETENTION_MS, 50)
      .all<{ id: string }>();
    if (lines.length === 0) break;
    for (const { id } of lines) {
      const { results: images } = await env.DB.prepare(
        "SELECT image_id FROM messages WHERE line_id = ?1 AND image_id IS NOT NULL AND image_deleted = 0",
      )
        .bind(id)
        .all<{ image_id: string }>();
      if (images.length > 0) await env.IMAGES.delete(images.map((r) => imageKey(r.image_id)));
      await env.DB.batch([
        env.DB.prepare("DELETE FROM messages WHERE line_id = ?1").bind(id),
        env.DB.prepare("DELETE FROM lines WHERE id = ?1").bind(id),
      ]);
      report.linesPurged++;
    }
    if (lines.length < 50) break;
  }

  return report;
}
