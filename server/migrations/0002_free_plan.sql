-- 0002：为 Cloudflare 免费额度重做存储布局。
--
--  1. 图片从 R2 改存 D1（BLOB，每张 <= 64 KB，远小于 D1 单行 2 MB 上限）。迁移前存在 R2 里的图片不会被带过来。
--  2. D1 的“写入行数”按表行 + 每个被更新的索引条目计费（删除不计），所以：
--     - devices / lines / messages 改成 WITHOUT ROWID（TEXT 主键不再多一份自动索引）；
--     - 索引全部改成小的部分索引，只覆盖“还在用”的行；
--     - 删掉热路径上没人用的索引。
--  3. 配对不再扫描 devices 全表：每台设备有一个随机键 rnd，从随机位置起在索引里取第一个合格的。
--  4. 收件人当日接收数改成 devices 上的计数列（recv_day / recv_count），不再每次 COUNT lines。
--  5. messages 多一列 to_id（收件人），收件箱直接按 to_id 取，不再经过 lines 连接。
--  6. lines 用 expires_at 一列表示“下一个要处理的时间点”（超时关闭，或关闭后清理），一个索引搞定定时任务。
--
-- 迁移之后 recv_day / recv_count 从 0 开始：迁移当天各设备的接收额度重新计数，之后精确。

-- ---------------------------------------------------------------------------
-- devices
-- ---------------------------------------------------------------------------
CREATE TABLE devices_new (
  id                 TEXT PRIMARY KEY,
  public_key         TEXT NOT NULL,
  created_at         INTEGER NOT NULL,
  last_seen_at       INTEGER NOT NULL,
  online             INTEGER NOT NULL DEFAULT 0,
  suspended_until    INTEGER,
  new_faxes_per_day  INTEGER NOT NULL DEFAULT 3,
  quota_day          INTEGER NOT NULL DEFAULT 0,
  new_faxes_used     INTEGER NOT NULL DEFAULT 0,
  rnd                INTEGER,                      -- 配对用随机键；NULL = 不在配对池（7 天没活跃）
  recv_day           INTEGER NOT NULL DEFAULT 0,   -- recv_count 对应的 UTC 日；跨日视为 0
  recv_count         INTEGER NOT NULL DEFAULT 0
) WITHOUT ROWID;

INSERT INTO devices_new (id, public_key, created_at, last_seen_at, online, suspended_until,
                         new_faxes_per_day, quota_day, new_faxes_used, rnd)
SELECT id, public_key, created_at, last_seen_at, online, suspended_until,
       new_faxes_per_day, quota_day, new_faxes_used,
       CASE WHEN online = 1 OR last_seen_at >= (CAST(strftime('%s', 'now') AS INTEGER) - 604800) * 1000
            THEN ABS(RANDOM()) % 2147483648 END
FROM devices;

DROP TABLE devices;
ALTER TABLE devices_new RENAME TO devices;

-- 在线设备（配对优先）
CREATE INDEX idx_devices_online ON devices (rnd) WHERE online = 1;
-- 配对池：最近 7 天活跃的设备
CREATE INDEX idx_devices_pool ON devices (rnd) WHERE rnd IS NOT NULL;

-- ---------------------------------------------------------------------------
-- lines
-- ---------------------------------------------------------------------------
CREATE TABLE lines_new (
  id               TEXT PRIMARY KEY,
  state            TEXT NOT NULL CHECK (state IN ('queued', 'delivered', 'connected', 'closed')),
  initiator_id     TEXT NOT NULL,
  recipient_id     TEXT,
  initiator_alias  TEXT NOT NULL,
  recipient_alias  TEXT,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  matched_at       INTEGER,
  closed_at        INTEGER,
  expires_at       INTEGER NOT NULL    -- 未关闭：超时时间点；已关闭：清理时间点
) WITHOUT ROWID;

INSERT INTO lines_new (id, state, initiator_id, recipient_id, initiator_alias, recipient_alias,
                       created_at, updated_at, matched_at, closed_at, expires_at)
SELECT id, state, initiator_id, recipient_id, initiator_alias, recipient_alias,
       created_at, updated_at, matched_at, closed_at,
       CASE state
         WHEN 'queued'    THEN created_at + 259200000
         WHEN 'delivered' THEN COALESCE(matched_at, created_at) + 604800000
         WHEN 'connected' THEN last_message_at + 2592000000
         ELSE COALESCE(closed_at, updated_at) + 2592000000
       END
FROM lines;

DROP TABLE lines;
ALTER TABLE lines_new RENAME TO lines;

CREATE INDEX idx_lines_initiator ON lines (initiator_id) WHERE closed_at IS NULL;
CREATE INDEX idx_lines_recipient ON lines (recipient_id) WHERE recipient_id IS NOT NULL AND closed_at IS NULL;
CREATE INDEX idx_lines_queued ON lines (created_at) WHERE state = 'queued';
CREATE INDEX idx_lines_expires ON lines (expires_at);

-- ---------------------------------------------------------------------------
-- messages
-- ---------------------------------------------------------------------------
CREATE TABLE messages_new (
  id                TEXT PRIMARY KEY,
  line_id           TEXT NOT NULL,
  sender_id         TEXT NOT NULL,
  to_id             TEXT,                -- 收件人；线路还在 queued 时为 NULL，配对时补上
  kind              TEXT NOT NULL CHECK (kind IN ('text', 'image')),
  text              TEXT,                -- 收件人确认后置 NULL
  image_id          TEXT,                -- 对应 images.id；images 里没有这一行 = 图片已删除
  width             INTEGER,
  height            INTEGER,
  sent_at           INTEGER NOT NULL,
  acked_at          INTEGER,
  image_expires_at  INTEGER              -- 确认时间 + 24 小时；删除图片后置 NULL
) WITHOUT ROWID;

INSERT INTO messages_new (id, line_id, sender_id, to_id, kind, text, image_id, width, height,
                          sent_at, acked_at, image_expires_at)
SELECT m.id, m.line_id, m.sender_id,
       (SELECT CASE WHEN l.initiator_id = m.sender_id THEN l.recipient_id ELSE l.initiator_id END
          FROM lines l WHERE l.id = m.line_id),
       m.kind, m.text, m.image_id, m.width, m.height, m.sent_at, m.acked_at,
       CASE WHEN m.image_deleted = 1 THEN NULL ELSE m.image_expires_at END
FROM messages m;

DROP TABLE messages;
ALTER TABLE messages_new RENAME TO messages;

CREATE INDEX idx_messages_line ON messages (line_id, sent_at);
CREATE INDEX idx_messages_pending ON messages (to_id) WHERE acked_at IS NULL AND to_id IS NOT NULL;
CREATE UNIQUE INDEX idx_messages_image ON messages (image_id) WHERE image_id IS NOT NULL;
CREATE INDEX idx_messages_image_expires ON messages (image_expires_at) WHERE image_expires_at IS NOT NULL;

-- ---------------------------------------------------------------------------
-- images：图片本体。只做插入和删除，不更新，避免每次更新都重写 BLOB。
-- ---------------------------------------------------------------------------
CREATE TABLE images (
  id    TEXT PRIMARY KEY,
  data  BLOB NOT NULL
);
