import { Errors } from "./errors";
import {
  ACTIVE_WINDOW_MS,
  CLOSED_RETENTION_MS,
  CONNECTED_TTL_MS,
  DEFAULT_NEW_FAXES_PER_DAY,
  DELIVERED_TTL_MS,
  IMAGES_PER_LINE_PER_DAY,
  IMAGE_RETENTION_MS,
  LAST_SEEN_REFRESH_MS,
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
import type { AppEnv, DeviceRow, LineRow, LineView, LineWithPresence, MessageRow, MessageView } from "./types";
import { dayIndex, dayStart, nextDayStart, randomAlias, randomId, readBodyLimited } from "./util";
import { isParticipant, lineView, messageView, peerOf } from "./views";

// ---------------------------------------------------------------------------
// 免费套餐下的约束（这些数字决定了下面代码的形状）
//  - D1：每次 Worker 调用最多 50 次查询（batch 只算 1 次）；每天写 10 万行、读 500 万行。
//    “写入行数”= 表行 + 每个被更新的索引条目，所以热路径上尽量少索引、少写、合并成 batch。
//  - Durable Object：每天 10 万次请求，只在对方确实在线时才去叫它。
//  - 每次调用 CPU 10 ms：只做 WebCrypto、小 JSON 和一次 64 KB 的 CRC。
// ---------------------------------------------------------------------------

function changes(result: D1Result): number {
  return result.meta.changes ?? 0;
}

/** 0 .. 2^31-1 的随机键，配对时从随机位置起在索引里取第一个合格的设备。 */
function randomKey(): number {
  return crypto.getRandomValues(new Uint32Array(1))[0]! >>> 1;
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
  return line.state !== "closed" && line.expires_at <= now;
}

// ---------------------------------------------------------------------------
// 设备、会话、额度
// ---------------------------------------------------------------------------

export async function getDevice(env: AppEnv, id: string): Promise<DeviceRow | null> {
  return env.DB.prepare("SELECT * FROM devices WHERE id = ?1").bind(id).first<DeviceRow>();
}

function needsRefresh(device: DeviceRow, now: number): boolean {
  return device.rnd === null || now - device.last_seen_at >= LAST_SEEN_REFRESH_MS;
}

/** 刷新 last_seen 并重新抽一个配对随机键（同时把久未活跃被移出配对池的设备放回去）。 */
async function refreshDevice(env: AppEnv, device: DeviceRow, now: number): Promise<void> {
  const rnd = randomKey();
  await env.DB.prepare("UPDATE devices SET last_seen_at = ?1, rnd = ?2 WHERE id = ?3").bind(now, rnd, device.id).run();
  device.last_seen_at = now;
  device.rnd = rnd;
}

/**
 * POST /v1/session：登记设备（首次）或刷新活跃时间。6 小时内重复建立会话不产生任何写入。
 */
export async function openSession(env: AppEnv, id: string, publicKeyB64: string, now: number): Promise<DeviceRow> {
  const existing = await getDevice(env, id);
  if (existing) {
    if (needsRefresh(existing, now)) await refreshDevice(env, existing, now);
    return existing;
  }
  const device: DeviceRow = {
    id,
    public_key: publicKeyB64,
    created_at: now,
    last_seen_at: now,
    online: 0,
    suspended_until: null,
    new_faxes_per_day: DEFAULT_NEW_FAXES_PER_DAY,
    quota_day: 0,
    new_faxes_used: 0,
    rnd: randomKey(),
    recv_day: 0,
    recv_count: 0,
  };
  await env.DB.prepare(
    `INSERT INTO devices (id, public_key, created_at, last_seen_at, rnd) VALUES (?1, ?2, ?3, ?3, ?4)
     ON CONFLICT (id) DO NOTHING`,
  )
    .bind(id, publicKeyB64, now, device.rnd)
    .run();
  return device;
}

/** 已认证请求顺带刷新“最近活跃”：6 小时内最多写一次（HTTP 请求本身不再每次写库）。 */
export async function touchDevice(env: AppEnv, device: DeviceRow, now: number): Promise<void> {
  if (needsRefresh(device, now)) await refreshDevice(env, device, now);
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

/** 原子地占用收件人今天的一个接收名额（每天最多 5 条新线路）。 */
async function reserveRecipientSlot(env: AppEnv, deviceId: string, now: number): Promise<boolean> {
  const today = dayIndex(now);
  const res = await env.DB.prepare(
    `UPDATE devices SET
       recv_count = CASE WHEN recv_day = ?1 THEN recv_count + 1 ELSE 1 END,
       recv_day = ?1
     WHERE id = ?2 AND (CASE WHEN recv_day = ?1 THEN recv_count ELSE 0 END) < ?3`,
  )
    .bind(today, deviceId, RECIPIENT_DAILY_LIMIT)
    .run();
  return changes(res) === 1;
}

async function refundRecipientSlot(env: AppEnv, deviceId: string, now: number): Promise<void> {
  await env.DB.prepare("UPDATE devices SET recv_count = MAX(recv_count - 1, 0) WHERE id = ?1 AND recv_day = ?2")
    .bind(deviceId, dayIndex(now))
    .run();
}

// ---------------------------------------------------------------------------
// 线路读取
// ---------------------------------------------------------------------------

/** 读线路，顺带取对端的在线标记（决定要不要去推送）。 */
async function getLineFor(env: AppEnv, lineId: string, viewerId: string): Promise<LineWithPresence | null> {
  return env.DB.prepare(
    `SELECT l.*,
            (SELECT d.online FROM devices d
              WHERE d.id = CASE WHEN l.initiator_id = ?2 THEN l.recipient_id ELSE l.initiator_id END) AS peer_online
     FROM lines l WHERE l.id = ?1`,
  )
    .bind(lineId, viewerId)
    .first<LineWithPresence>();
}

/** 读线路并要求调用者是参与者（否则 404）；顺带惰性处理超时，不用等定时任务。 */
async function loadParticipantLine(env: AppEnv, deviceId: string, lineId: string, now: number): Promise<LineWithPresence> {
  const line = await getLineFor(env, lineId, deviceId);
  if (!line || !isParticipant(line, deviceId)) throw Errors.notFound("line not found");
  if (isExpired(line, now)) {
    const closed = await closeLineNow(env, line, now);
    if (closed) {
      await pushEvents(env, peerOf(line, deviceId) ?? "", [{ type: "line.updated", line: lineView(closed, peerOf(line, deviceId) ?? "") }], line.peer_online);
      return { ...closed, peer_online: line.peer_online };
    }
    return (await getLineFor(env, lineId, deviceId)) ?? line;
  }
  return line;
}

// ---------------------------------------------------------------------------
// 关闭线路
// ---------------------------------------------------------------------------

/** 关闭一条线路要执行的语句：置 closed + 删掉从未送达任何人的第一封的文字。 */
function closeStatements(env: AppEnv, line: LineRow, now: number): D1PreparedStatement[] {
  return [
    env.DB.prepare(
      "UPDATE lines SET state = 'closed', closed_at = ?1, updated_at = ?1, expires_at = ?2 WHERE id = ?3 AND state != 'closed'",
    ).bind(now, now + CLOSED_RETENTION_MS, line.id),
    env.DB.prepare("UPDATE messages SET text = NULL, acked_at = ?1 WHERE line_id = ?2 AND to_id IS NULL AND acked_at IS NULL").bind(
      now,
      line.id,
    ),
  ];
}

function asClosed(line: LineRow, now: number): LineRow {
  return { ...line, state: "closed", closed_at: now, updated_at: now, expires_at: now + CLOSED_RETENTION_MS };
}

/** 超时关闭一条线路。真正发生状态变化时返回关闭后的行，已经关闭返回 null。 */
async function closeLineNow(env: AppEnv, line: LineRow, now: number): Promise<LineRow | null> {
  const results = await env.DB.batch(closeStatements(env, line, now));
  return changes(results[0]!) === 1 ? asClosed(line, now) : null;
}

// ---------------------------------------------------------------------------
// 配对
// ---------------------------------------------------------------------------

const PAIR_BLOCKED = (candidate: string) => `EXISTS (
  SELECT 1 FROM reports r
  WHERE (r.reporter_id = ?3 AND r.reported_id = ${candidate})
     OR (r.reporter_id = ${candidate} AND r.reported_id = ?3)
)`;

/** 每次挑选最多看多少个候选（索引里从随机位置起的连续 N 个设备）。这给单次配对的读行数设了硬上限。 */
const PICK_WINDOW = 8;
/** 窗口里没有合格设备时换随机位置重试的次数（每次一条查询）。 */
const PICK_ATTEMPTS = 3;

/**
 * 为 senderId 的第一封挑一个收件人：在线的优先，其次最近 7 天活跃的；随机。
 * 排除：自己、有过举报关系的设备、今天新线路已收满的设备、被暂停的设备。
 *
 * 不扫描 devices 全表：每台设备有随机键 rnd，从一个随机位置起顺着索引最多看 PICK_WINDOW 个设备，
 * 取第一个合格的；这个位置之后没有就绕回开头。整个挑选是一条 SQL（四个分支，按顺序懒惰求值，找到就停），
 * 读行数与设备总数无关。窗口里一个合格的都没有时返回 null，调用方换一个随机位置重试。
 */
async function pickRecipient(env: AppEnv, senderId: string, now: number): Promise<{ id: string; online: boolean } | null> {
  const branch = (online: 0 | 1, op: ">=" | "<") => `
    SELECT * FROM (
      SELECT w.id AS id, w.online AS online FROM (
        SELECT d.id, d.online, d.suspended_until, d.recv_day, d.recv_count, d.last_seen_at
        FROM devices d INDEXED BY ${online === 1 ? "idx_devices_online" : "idx_devices_pool"}
        WHERE d.online = ${online} AND d.rnd ${op} ?1 AND d.id != ?3
        ORDER BY d.rnd ASC LIMIT ${PICK_WINDOW}
      ) w
      WHERE (w.suspended_until IS NULL OR w.suspended_until <= ?2)
        ${online === 0 ? "AND w.last_seen_at >= ?7" : ""}
        AND (CASE WHEN w.recv_day = ?4 THEN w.recv_count ELSE 0 END) < ?5
        AND NOT ${PAIR_BLOCKED("w.id")}
      LIMIT 1
    )`;
  const sql = `${branch(1, ">=")} UNION ALL ${branch(1, "<")} UNION ALL ${branch(0, ">=")} UNION ALL ${branch(0, "<")} LIMIT 1`;
  const row = await env.DB.prepare(sql)
    .bind(randomKey(), now, senderId, dayIndex(now), RECIPIENT_DAILY_LIMIT, 0, now - ACTIVE_WINDOW_MS)
    .first<{ id: string; online: number }>();
  return row ? { id: row.id, online: row.online === 1 } : null;
}

function newLineRow(initiatorId: string, recipientId: string | null, now: number): LineRow {
  let recipientAlias: string | null = null;
  const initiatorAlias = randomAlias();
  if (recipientId) {
    recipientAlias = randomAlias();
    while (recipientAlias === initiatorAlias) recipientAlias = randomAlias();
  }
  return {
    id: randomId(),
    state: recipientId ? "delivered" : "queued",
    initiator_id: initiatorId,
    recipient_id: recipientId,
    initiator_alias: initiatorAlias,
    recipient_alias: recipientAlias,
    created_at: now,
    updated_at: now,
    matched_at: recipientId ? now : null,
    closed_at: null,
    expires_at: now + (recipientId ? DELIVERED_TTL_MS : QUEUED_TTL_MS),
  };
}

/**
 * 设备上线（建立会话或连上 socket）时：把排队中的线路按先来后到配给它，直到它今天的接收额度用完。
 * `online`：这台设备此刻是否有存活的 WebSocket（决定要不要把 fax 事件推过去）。
 */
export async function matchQueuedFor(env: AppEnv, device: DeviceRow, now: number, online: boolean): Promise<void> {
  if (isSuspended(device, now)) return;
  const used = device.recv_day === dayIndex(now) ? device.recv_count : 0;
  const room = RECIPIENT_DAILY_LIMIT - used;
  if (room <= 0) return;

  const { results } = await env.DB.prepare(
    `SELECT l.*, (SELECT d.online FROM devices d WHERE d.id = l.initiator_id) AS peer_online
     FROM lines l
     WHERE l.state = 'queued' AND l.created_at > ?2 AND l.initiator_id != ?3
       AND NOT ${PAIR_BLOCKED("l.initiator_id")}
     ORDER BY l.created_at ASC
     LIMIT ?1`,
  )
    .bind(room, now - QUEUED_TTL_MS, device.id)
    .all<LineWithPresence>();

  for (const queued of results) {
    if (!(await reserveRecipientSlot(env, device.id, now))) break;
    let alias = randomAlias();
    while (alias === queued.initiator_alias) alias = randomAlias();
    const claimed = await env.DB.prepare(
      `UPDATE lines SET state = 'delivered', recipient_id = ?1, recipient_alias = ?2, matched_at = ?3, updated_at = ?3, expires_at = ?4
       WHERE id = ?5 AND state = 'queued' RETURNING *`,
    )
      .bind(device.id, alias, now, now + DELIVERED_TTL_MS, queued.id)
      .all<LineRow>();
    const line = claimed.results[0];
    if (!line) {
      await refundRecipientSlot(env, device.id, now); // 被别人抢先了
      continue;
    }
    const messages = await env.DB.prepare("UPDATE messages SET to_id = ?1 WHERE line_id = ?2 AND to_id IS NULL RETURNING *")
      .bind(device.id, line.id)
      .all<MessageRow>();
    const sorted = messages.results.sort((a, b) => a.sent_at - b.sent_at);
    await Promise.all([
      pushEvents(
        env,
        device.id,
        sorted.map((m) => ({ type: "fax" as const, line: lineView(line, device.id), message: messageView(m, device.id) })),
        online,
      ),
      pushEvents(env, line.initiator_id, [{ type: "line.updated", line: lineView(line, line.initiator_id) }], queued.peer_online),
    ]);
  }
}

// ---------------------------------------------------------------------------
// POST /v1/faxes
// ---------------------------------------------------------------------------

const INSERT_LINE = `INSERT INTO lines (id, state, initiator_id, recipient_id, initiator_alias, recipient_alias,
                                       created_at, updated_at, matched_at, expires_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?8, ?9)`;
const INSERT_MESSAGE = `INSERT INTO messages (id, line_id, sender_id, to_id, kind, text, sent_at)
                        VALUES (?1, ?2, ?3, ?4, 'text', ?5, ?6)`;

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

  // 找收件人并占用它今天的接收名额（找不到就排队）
  let recipient: { id: string; online: boolean } | null = null;
  try {
    for (let attempt = 0; attempt < PICK_ATTEMPTS && !recipient; attempt++) {
      const candidate = await pickRecipient(env, device.id, now);
      if (!candidate) break;
      if (await reserveRecipientSlot(env, candidate.id, now)) recipient = candidate;
    }
  } catch (err) {
    await refundFaxQuota(env, device.id, now);
    throw err;
  }

  const line = newLineRow(device.id, recipient?.id ?? null, now);
  const message: MessageRow = {
    id: randomId(),
    line_id: line.id,
    sender_id: device.id,
    to_id: recipient?.id ?? null,
    kind: "text",
    text,
    image_id: null,
    width: null,
    height: null,
    sent_at: now,
    acked_at: null,
    image_expires_at: null,
  };
  try {
    await env.DB.batch([
      env.DB.prepare(INSERT_LINE).bind(
        line.id,
        line.state,
        line.initiator_id,
        line.recipient_id,
        line.initiator_alias,
        line.recipient_alias,
        now,
        line.matched_at,
        line.expires_at,
      ),
      env.DB.prepare(INSERT_MESSAGE).bind(message.id, line.id, device.id, message.to_id, text, now),
    ]);
  } catch (err) {
    await refundFaxQuota(env, device.id, now);
    if (recipient) await refundRecipientSlot(env, recipient.id, now);
    throw err;
  }

  if (recipient) {
    await pushEvents(
      env,
      recipient.id,
      [{ type: "fax", line: lineView(line, recipient.id), message: messageView(message, recipient.id) }],
      recipient.online,
    );
  }
  return { line: lineView(line, device.id), message: messageView(message, device.id) };
}

// ---------------------------------------------------------------------------
// POST /v1/lines/:id/messages
// ---------------------------------------------------------------------------

/** 仅当线路仍是 connected 时才插入（并发被撕掉时插入 0 行）。 */
const INSERT_MESSAGE_IF_CONNECTED = `INSERT INTO messages (id, line_id, sender_id, to_id, kind, text, sent_at)
  SELECT ?1, ?2, ?3, ?4, 'text', ?5, ?6
  WHERE EXISTS (SELECT 1 FROM lines WHERE id = ?2 AND state = 'connected')`;

/**
 * connected 线路上有新消息：updated_at 总是更新；30 天超时点只在偏差超过 6 小时时才重写，
 * 避免每条消息都多写一次 expires_at 的索引（超时精度 6 小时，对 30 天的期限无所谓）。
 */
function touchConnectedStatements(env: AppEnv, lineId: string, now: number): D1PreparedStatement[] {
  return [
    env.DB.prepare("UPDATE lines SET updated_at = ?1 WHERE id = ?2 AND state = 'connected'").bind(now, lineId),
    env.DB.prepare("UPDATE lines SET expires_at = ?1 WHERE id = ?2 AND state = 'connected' AND expires_at < ?3").bind(
      now + CONNECTED_TTL_MS,
      lineId,
      now + CONNECTED_TTL_MS - LAST_SEEN_REFRESH_MS,
    ),
  ];
}

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
  const peerId = peerOf(line, device.id)!;
  const messageId = randomId();
  const insert = env.DB.prepare(INSERT_MESSAGE_IF_CONNECTED).bind(messageId, line.id, device.id, peerId, text, now);

  let flipped = false;
  if (line.state === "delivered") {
    // 收件人回复：delivered → connected（单独一条语句，精确知道是不是我翻的），并抬高发起人的每日额度上限
    const flip = await env.DB.prepare(
      "UPDATE lines SET state = 'connected', updated_at = ?1, expires_at = ?2 WHERE id = ?3 AND state = 'delivered'",
    )
      .bind(now, now + CONNECTED_TTL_MS, line.id)
      .run();
    flipped = changes(flip) === 1;
  }

  const statements: D1PreparedStatement[] = [];
  if (flipped) {
    statements.push(
      env.DB.prepare("UPDATE devices SET new_faxes_per_day = MIN(new_faxes_per_day + 1, ?1) WHERE id = ?2").bind(
        MAX_NEW_FAXES_PER_DAY,
        line.initiator_id,
      ),
    );
  }
  statements.push(insert);
  if (!flipped) statements.push(...touchConnectedStatements(env, line.id, now));
  const results = await env.DB.batch(statements);
  const inserted = changes(results[flipped ? 1 : 0]!);
  if (inserted === 0) throw Errors.lineClosed(); // 并发下被撕掉或超时

  line = { ...line, state: "connected", updated_at: now, expires_at: flipped ? now + CONNECTED_TTL_MS : line.expires_at };
  const row: MessageRow = {
    id: messageId,
    line_id: line.id,
    sender_id: device.id,
    to_id: peerId,
    kind: "text",
    text,
    image_id: null,
    width: null,
    height: null,
    sent_at: now,
    acked_at: null,
    image_expires_at: null,
  };
  await pushEvents(
    env,
    peerId,
    [
      ...(flipped ? [{ type: "line.updated" as const, line: lineView(line, peerId) }] : []),
      { type: "fax", line: lineView(line, peerId), message: messageView(row, peerId) },
    ],
    line.peer_online,
  );
  return { line: lineView(line, device.id), message: messageView(row, device.id) };
}

// ---------------------------------------------------------------------------
// POST /v1/lines/:id/images
// ---------------------------------------------------------------------------

/** 条件：线路仍是 connected，且调用者今天在这条线路上发的图不足 10 张。 */
const IMAGE_ALLOWED = `EXISTS (SELECT 1 FROM lines WHERE id = ?2 AND state = 'connected')
  AND (SELECT COUNT(*) FROM messages
       WHERE line_id = ?2 AND sender_id = ?3 AND kind = 'image' AND sent_at >= ?8) < ?9`;

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
  const peerId = peerOf(line, device.id)!;
  const blob = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;

  // 图片本体和消息元数据在同一个 batch 里，条件相同（线路仍 connected 且未超每日上限），要么都写要么都不写。
  const results = await env.DB.batch([
    env.DB.prepare(`INSERT INTO images (id, data) SELECT ?1, ?10 WHERE ${IMAGE_ALLOWED}`).bind(
      imageId,
      line.id,
      device.id,
      null,
      null,
      null,
      null,
      dayStart(now),
      IMAGES_PER_LINE_PER_DAY,
      blob,
    ),
    env.DB.prepare(
      `INSERT INTO messages (id, line_id, sender_id, to_id, kind, image_id, width, height, sent_at)
       SELECT ?1, ?2, ?3, ?4, 'image', ?5, ?6, ?7, ?10 WHERE ${IMAGE_ALLOWED}`,
    ).bind(messageId, line.id, device.id, peerId, imageId, check.width, check.height, dayStart(now), IMAGES_PER_LINE_PER_DAY, now),
    ...touchConnectedStatements(env, line.id, now),
  ]);
  if (changes(results[1]!) === 0) {
    const current = await getLineFor(env, line.id, device.id);
    if (!current || current.state !== "connected") throw Errors.lineNotConnected();
    throw Errors.quotaExceeded("at most 10 images per line per day");
  }

  line = { ...line, updated_at: now };
  const row: MessageRow = {
    id: messageId,
    line_id: line.id,
    sender_id: device.id,
    to_id: peerId,
    kind: "image",
    text: null,
    image_id: imageId,
    width: check.width,
    height: check.height,
    sent_at: now,
    acked_at: null,
    image_expires_at: null,
  };
  await pushEvents(env, peerId, [{ type: "fax", line: lineView(line, peerId), message: messageView(row, peerId) }], line.peer_online);
  return { line: lineView(line, device.id), message: messageView(row, device.id) };
}

// ---------------------------------------------------------------------------
// GET /v1/images/:id
// ---------------------------------------------------------------------------

export async function getImage(env: AppEnv, deviceId: string, imageId: string, now: number): Promise<Response> {
  const meta = await env.DB.prepare(
    `SELECT m.image_expires_at AS expires_at, l.initiator_id AS initiator_id, l.recipient_id AS recipient_id
     FROM messages m JOIN lines l ON l.id = m.line_id
     WHERE m.image_id = ?1`,
  )
    .bind(imageId)
    .first<{ expires_at: number | null; initiator_id: string; recipient_id: string | null }>();
  // 非参与者与不存在一样返回 404，不泄露图片是否存在
  if (!meta || (meta.initiator_id !== deviceId && meta.recipient_id !== deviceId)) throw Errors.notFound("image not found");
  if (meta.expires_at !== null && meta.expires_at <= now) throw Errors.notFound("image not found");

  // BLOB 单独取（上面的查询不带 BLOB，非参与者的请求不会读到图片内容）
  const row = await env.DB.prepare("SELECT data FROM images WHERE id = ?1").bind(imageId).first<{ data: number[] | ArrayBuffer }>();
  if (!row) throw Errors.notFound("image not found");
  // D1 把 BLOB 以数字数组返回
  const bytes = Array.isArray(row.data) ? Uint8Array.from(row.data) : new Uint8Array(row.data);
  return new Response(bytes, {
    headers: {
      "content-type": "image/png",
      "content-length": String(bytes.byteLength),
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
    // 一个 batch：关闭线路 + 撕掉的一方不再需要的、还没确认的内容（文字删除，图片开始 24 小时倒计时）
    const results = await env.DB.batch([
      ...closeStatements(env, line, now),
      env.DB.prepare(
        `UPDATE messages SET text = NULL, acked_at = ?1,
           image_expires_at = CASE WHEN kind = 'image' THEN ?2 END
         WHERE line_id = ?3 AND to_id = ?4 AND acked_at IS NULL`,
      ).bind(now, now + IMAGE_RETENTION_MS, line.id, device.id),
    ]);
    if (changes(results[0]!) === 1) {
      line = { ...asClosed(line, now), peer_online: line.peer_online };
      if (peerId) await pushEvents(env, peerId, [{ type: "line.updated", line: lineView(line, peerId) }], line.peer_online);
    } else {
      line = (await getLineFor(env, line.id, device.id)) ?? line; // 并发下别人先关了
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
  // 两个部分索引（只含未关闭的线路）各查一次，不扫表
  const { results } = await env.DB.prepare(
    `SELECT * FROM lines WHERE initiator_id = ?1 AND closed_at IS NULL
     UNION ALL
     SELECT * FROM lines WHERE recipient_id = ?1 AND closed_at IS NULL`,
  )
    .bind(deviceId)
    .all<LineRow>();
  // 已超时但定时任务还没来得及关的线路，按已关闭处理
  return results
    .filter((l) => !isExpired(l, now))
    .sort((a, b) => b.updated_at - a.updated_at)
    .slice(0, 500)
    .map((l) => lineView(l, deviceId));
}

export async function getInbox(
  env: AppEnv,
  deviceId: string,
): Promise<{ messages: MessageView[]; lines: LineView[] }> {
  const { results: messages } = await env.DB.prepare(
    "SELECT * FROM messages WHERE to_id = ?1 AND acked_at IS NULL ORDER BY sent_at ASC, id ASC LIMIT 500",
  )
    .bind(deviceId)
    .all<MessageRow>();
  if (messages.length === 0) return { messages: [], lines: [] };

  const { results: lines } = await env.DB.prepare(
    `SELECT * FROM lines WHERE id IN (SELECT line_id FROM messages WHERE to_id = ?1 AND acked_at IS NULL)
     ORDER BY created_at ASC`,
  )
    .bind(deviceId)
    .all<LineRow>();
  return {
    messages: messages.map((m) => messageView(m, deviceId)),
    lines: lines.map((l) => lineView(l, deviceId)),
  };
}

export async function ackMessage(env: AppEnv, deviceId: string, messageId: string, now: number): Promise<void> {
  // 只有这条消息的收件人（to_id）能确认；文字删除，图片开始 24 小时倒计时
  const res = await env.DB.prepare(
    `UPDATE messages SET text = NULL, acked_at = ?1, image_expires_at = CASE WHEN kind = 'image' THEN ?2 END
     WHERE id = ?3 AND to_id = ?4 AND acked_at IS NULL`,
  )
    .bind(now, now + IMAGE_RETENTION_MS, messageId, deviceId)
    .run();
  if (changes(res) === 1) return;
  // 没更新到：要么早就确认过了（幂等，204），要么不是收件人 / 不存在（404）
  const row = await env.DB.prepare("SELECT to_id FROM messages WHERE id = ?1").bind(messageId).first<{ to_id: string | null }>();
  if (!row || row.to_id !== deviceId) throw Errors.notFound("message not found");
}

// ---------------------------------------------------------------------------
// 定时任务：每次运行的工作量都有上限（免费套餐每次调用最多 50 次 D1 查询、10 ms CPU）。
// 积压的部分留给下一次运行；超时的线路在被访问时还会惰性关闭，图片过期后取图接口也会拒绝。
// ---------------------------------------------------------------------------

export const MAINTENANCE_LIMITS = { closeLines: 100, purgeLines: 25, deleteImages: 100, demoteDevices: 200 } as const;

export interface MaintenanceReport {
  linesClosed: number;
  imagesDeleted: number;
  linesPurged: number;
  devicesDemoted: number;
}

interface DueLine extends LineRow {
  initiator_online: number | null;
  recipient_online: number | null;
}

/**
 * @param demote 是否顺带把 7 天没活跃的设备移出配对池。默认每小时一次（cron 每 10 分钟跑一次，只有整点那次执行）。
 */
export async function runMaintenance(
  env: AppEnv,
  now: number,
  opts: { demote?: boolean } = {},
): Promise<MaintenanceReport> {
  const report: MaintenanceReport = { linesClosed: 0, imagesDeleted: 0, linesPurged: 0, devicesDemoted: 0 };
  const L = MAINTENANCE_LIMITS;

  // 1. 到期的线路：未关闭的 → 超时关闭；已关闭的 → 清理（连同消息和图片）
  const { results: due } = await env.DB.prepare(
    `SELECT l.*,
            (SELECT d.online FROM devices d WHERE d.id = l.initiator_id) AS initiator_online,
            (SELECT d.online FROM devices d WHERE d.id = l.recipient_id) AS recipient_online
     FROM lines l WHERE l.expires_at <= ?1 ORDER BY l.expires_at ASC LIMIT ?2`,
  )
    .bind(now, L.closeLines + L.purgeLines)
    .all<DueLine>();

  const toClose = due.filter((l) => l.state !== "closed").slice(0, L.closeLines);
  const toPurge = due.filter((l) => l.state === "closed").slice(0, L.purgeLines);

  if (toClose.length > 0) {
    const results = await env.DB.batch(toClose.flatMap((l) => closeStatements(env, l, now)));
    for (const [i, line] of toClose.entries()) {
      if (changes(results[i * 2]!) !== 1) continue;
      report.linesClosed++;
      const closed = asClosed(line, now);
      // 尽力通知双方（只叫醒在线的）
      await Promise.all([
        pushEvents(env, line.initiator_id, [{ type: "line.updated", line: lineView(closed, line.initiator_id) }], line.initiator_online),
        line.recipient_id
          ? pushEvents(env, line.recipient_id, [{ type: "line.updated", line: lineView(closed, line.recipient_id) }], line.recipient_online)
          : Promise.resolve(0),
      ]);
    }
  }

  if (toPurge.length > 0) {
    await env.DB.batch(
      toPurge.flatMap((l) => [
        env.DB.prepare("DELETE FROM images WHERE id IN (SELECT image_id FROM messages WHERE line_id = ?1 AND image_id IS NOT NULL)").bind(l.id),
        env.DB.prepare("DELETE FROM messages WHERE line_id = ?1").bind(l.id),
        env.DB.prepare("DELETE FROM lines WHERE id = ?1").bind(l.id),
      ]),
    );
    report.linesPurged = toPurge.length;
  }

  // 2. 到期的图片（收件人确认 24 小时后）：删 BLOB，并把 image_expires_at 置空让它离开索引
  const { results: images } = await env.DB.prepare(
    "SELECT id, image_id FROM messages WHERE image_expires_at IS NOT NULL AND image_expires_at <= ?1 LIMIT ?2",
  )
    .bind(now, L.deleteImages)
    .all<{ id: string; image_id: string }>();
  if (images.length > 0) {
    await env.DB.batch(
      images.flatMap((m) => [
        env.DB.prepare("DELETE FROM images WHERE id = ?1").bind(m.image_id),
        env.DB.prepare("UPDATE messages SET image_expires_at = NULL WHERE id = ?1").bind(m.id),
      ]),
    );
    report.imagesDeleted = images.length;
  }

  // 3. 把 7 天没活跃且不在线的设备移出配对池（rnd = NULL）。下次它发请求时会自动放回去。
  if (opts.demote ?? new Date(now).getUTCMinutes() < 10) {
    const res = await env.DB.prepare(
      `UPDATE devices SET rnd = NULL WHERE id IN (
         SELECT id FROM devices WHERE rnd IS NOT NULL AND online = 0 AND last_seen_at < ?1 LIMIT ?2)`,
    )
      .bind(now - ACTIVE_WINDOW_MS, L.demoteDevices)
      .run();
    report.devicesDemoted = changes(res);
  }

  return report;
}
