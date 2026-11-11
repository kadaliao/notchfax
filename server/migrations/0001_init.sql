-- Notchfax 初始表结构。时间一律为 Unix 毫秒；额度天数按 UTC 日（floor(ms / 86400000)）。

-- 设备：只存公钥和计数器，不存 IP、不存任何昵称。
CREATE TABLE devices (
  id                 TEXT PRIMARY KEY,                 -- deviceId = base64url(SHA-256(公钥))[0:22]
  public_key         TEXT NOT NULL,                    -- base64url，32 字节
  created_at         INTEGER NOT NULL,
  last_seen_at       INTEGER NOT NULL,                 -- 配对时用于“最近 7 天活跃”
  online             INTEGER NOT NULL DEFAULT 0,       -- 由 DeviceSocket 维护，配对时优先在线设备
  suspended_until    INTEGER,                          -- NULL 或已过期 = 未暂停
  new_faxes_per_day  INTEGER NOT NULL DEFAULT 3,       -- 每日新线路上限（对方回复可 +1，最高 10）
  quota_day          INTEGER NOT NULL DEFAULT 0,       -- new_faxes_used 对应的 UTC 日；跨日则视为 0
  new_faxes_used     INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_devices_last_seen ON devices (last_seen_at);

-- 线路：别名按线路独立随机生成，不与设备关联，跨线路无法关联同一个人。
CREATE TABLE lines (
  id               TEXT PRIMARY KEY,
  state            TEXT NOT NULL CHECK (state IN ('queued', 'delivered', 'connected', 'closed')),
  initiator_id     TEXT NOT NULL,
  recipient_id     TEXT,                               -- queued 时为 NULL
  initiator_alias  TEXT NOT NULL,
  recipient_alias  TEXT,                               -- 配对时才生成
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL,
  matched_at       INTEGER,                            -- 配对给收件人的时间（delivered 超时从这里算）
  connected_at     INTEGER,
  last_message_at  INTEGER NOT NULL,                   -- connected 超时从这里算
  closed_at        INTEGER
);
CREATE INDEX idx_lines_state_created ON lines (state, created_at);
CREATE INDEX idx_lines_initiator ON lines (initiator_id, state);
CREATE INDEX idx_lines_recipient ON lines (recipient_id, state);
CREATE INDEX idx_lines_recipient_matched ON lines (recipient_id, matched_at);
CREATE INDEX idx_lines_closed_at ON lines (closed_at);

-- 消息：收件人确认（ack）后文字置 NULL，仅留元数据用于计数；图片 ack 后 24 小时删除。
CREATE TABLE messages (
  id                TEXT PRIMARY KEY,
  line_id           TEXT NOT NULL,
  sender_id         TEXT NOT NULL,
  kind              TEXT NOT NULL CHECK (kind IN ('text', 'image')),
  text              TEXT,
  image_id          TEXT,
  width             INTEGER,
  height            INTEGER,
  sent_at           INTEGER NOT NULL,
  acked_at          INTEGER,
  image_expires_at  INTEGER,                           -- ack 时间 + 24 小时
  image_deleted     INTEGER NOT NULL DEFAULT 0
);
CREATE UNIQUE INDEX idx_messages_image ON messages (image_id) WHERE image_id IS NOT NULL;
CREATE INDEX idx_messages_line ON messages (line_id, sent_at);
CREATE INDEX idx_messages_sender_day ON messages (line_id, sender_id, kind, sent_at);
CREATE INDEX idx_messages_pending ON messages (line_id) WHERE acked_at IS NULL;
CREATE INDEX idx_messages_image_expiry ON messages (image_expires_at)
  WHERE image_expires_at IS NOT NULL AND image_deleted = 0;

-- 举报：同一线路同一举报人只记一次。reported_id 7 天内被 3 个不同 reporter 举报 → 暂停；
-- 任何一对 (reporter, reported) 之间有记录，双方此后不再互相配对。
CREATE TABLE reports (
  line_id      TEXT NOT NULL,
  reporter_id  TEXT NOT NULL,
  reported_id  TEXT NOT NULL,
  created_at   INTEGER NOT NULL,
  PRIMARY KEY (line_id, reporter_id)
);
CREATE INDEX idx_reports_reported ON reports (reported_id, created_at);
CREATE INDEX idx_reports_pair ON reports (reporter_id, reported_id);
