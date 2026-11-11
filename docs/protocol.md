# Notchfax 传真协议 v1

客户端（`Packages/NotchfaxKit/Sources/FaxKit`）与服务器（`server/`）的唯一约定。改动必须两边同步。

所有 HTTP 请求与响应体为 JSON（图片上传/下载除外）。时间为 Unix 毫秒整数。错误响应统一为：

```json
{ "error": { "code": "line_not_connected", "message": "..." } }
```

## 1. 身份与会话

- 客户端首次启动生成 Ed25519 密钥对（CryptoKit `Curve25519.Signing`），私钥存钥匙串。
- `deviceId` = base64url(SHA-256(公钥原始 32 字节)) 的前 22 个字符。由服务器计算，客户端可自行算出相同值。
- 没有账号、昵称、邮箱。服务器不记录 IP。

### POST /v1/session

```json
{ "publicKey": "<base64url 32 字节>", "timestamp": 1794400000000, "signature": "<base64url 64 字节>" }
```

- 签名内容为 UTF-8 字符串 `notchfax-session:<timestamp>`。
- `timestamp` 与服务器时间相差超过 5 分钟 → `401 stale_timestamp`。
- 签名无效 → `401 bad_signature`。

响应 `200`：

```json
{ "token": "<不透明字符串>", "expiresAt": 1794486400000, "deviceId": "..." }
```

之后所有请求带 `Authorization: Bearer <token>`。令牌有效 24 小时，过期返回 `401 token_expired`，客户端重新建立会话。

## 2. 线路（line）

一条线路是两台设备之间的一次匿名对话。

| 状态 | 含义 |
|---|---|
| `queued` | 已发出第一封，尚未找到收件人 |
| `delivered` | 已配对给收件人，对方尚未回复 |
| `connected` | 收件人已回复，双方可以继续发文字和图片 |
| `closed` | 任一方撕掉，或超时 |

- 每条线路里双方各有一个 `alias`：4 位大写十六进制（如 `A3F2`），由服务器随机生成，只在该线路内有效。不同线路之间无法关联同一个人。
- `delivered` 状态下只有收件人能发消息（即回复）；发起人不能追发。
- `queued` 超过 72 小时、`delivered` 超过 7 天无回复、`connected` 超过 30 天无消息 → 自动 `closed`。

## 3. 接口

### GET /v1/me

```json
{
  "deviceId": "...",
  "quota": { "newFaxesLeft": 3, "newFaxesPerDay": 3, "resetsAt": 1794441600000 },
  "suspendedUntil": null
}
```

### POST /v1/faxes — 发一封新传真给随机陌生人

```json
{ "text": "你好，陌生人" }
```

- `text`：去掉首尾空白后 1–500 个字符（按 Unicode 标量计）。否则 `400 invalid_text`。
- 额度用完 → `429 quota_exceeded`。被暂停 → `403 suspended`。

响应 `202`：

```json
{ "line": { "id": "...", "state": "delivered", "role": "initiator", "myAlias": "A3F2", "peerAlias": "9C01", "createdAt": 0, "updatedAt": 0 },
  "message": { "id": "...", "lineId": "...", "from": "me", "kind": "text", "text": "...", "sentAt": 0 } }
```

找不到合适的收件人时 `state` 为 `queued`，`peerAlias` 为 `null`；之后有设备上线时再配对。

**配对规则**：从最近 7 天活跃过的设备里随机抽一个，优先当前在线的。排除：发件人自己、与发件人互相撕掉并举报过的设备、今天新线路已收满的设备（默认每天最多收 5 条新线路）、被暂停的设备。

### POST /v1/lines/:lineId/messages — 回复或继续发文字

```json
{ "text": "..." }
```

- `delivered` 状态且调用者是收件人：允许，线路变为 `connected`，发起人的每日额度上限 +1（最高 10）。
- `delivered` 状态且调用者是发起人 → `403 awaiting_reply`。
- `connected`：双方都允许。
- `closed` / `queued` → `409 line_closed` / `409 line_not_ready`。
- 不是该线路的参与者 → `404 not_found`。

响应 `201`：`{ "line": {...}, "message": {...} }`。

### POST /v1/lines/:lineId/images — 发图

- 请求体是 PNG 原始字节，`Content-Type: image/png`。
- **线路必须是 `connected`，否则 `403 line_not_connected`。这条规则只在服务器判断。**
- 图片约束（服务器解析 PNG 的 IHDR 校验）：灰度（color type 0）、位深 1、宽 ≤ 384、高 ≤ 768、文件 ≤ 64 KB。否则 `400 invalid_image`。
  客户端负责把任意图片缩放并做 1-bit 抖动后再上传。
- 每条线路每人每天最多 10 张 → `429 quota_exceeded`。

响应 `201`：

```json
{ "line": {...}, "message": { "id": "...", "lineId": "...", "from": "me", "kind": "image", "imageId": "...", "width": 384, "height": 512, "sentAt": 0 } }
```

### GET /v1/images/:imageId

仅线路参与者可取，返回 `image/png`。其他人 `404 not_found`。图片在收件人确认后保留 24 小时，然后删除。

### POST /v1/lines/:lineId/tear — 撕掉

```json
{ "report": false }
```

- 线路变为 `closed`。对方会收到 `line.closed` 事件（不说明原因）。
- `report: true`：记一次举报。同一设备 7 天内被 3 个不同设备举报 → 暂停发送 7 天，且双方以后不再配对。
- 响应 `200`：`{ "line": {...} }`。

### GET /v1/lines

返回调用者参与的、未关闭的线路：`{ "lines": [ {...} ] }`。

### GET /v1/inbox

返回尚未确认的消息（离线补投）：`{ "messages": [ {...} ], "lines": [ {...} ] }`。`lines` 是这些消息涉及的线路。

### POST /v1/messages/:messageId/ack

收件人确认已打印。服务器删除文字内容（保留元数据用于计数），图片进入 24 小时倒计时。响应 `204`。

## 4. 实时通道

`GET /v1/socket?token=<token>`，升级为 WebSocket。同一设备新连接会顶掉旧连接。

服务器 → 客户端，每帧一个 JSON：

```json
{ "type": "fax", "line": {...}, "message": {...} }
{ "type": "line.updated", "line": {...} }
{ "type": "ping" }
```

- `fax`：有新消息（新线路的第一封、回复、图片）。`message.from` 为 `"peer"`。
- `line.updated`：状态变化（`queued` → `delivered`、→ `connected`、→ `closed`）。
- 客户端 → 服务器只有 `{ "type": "pong" }`。其余操作都走 HTTP。
- 连接建立后客户端应调一次 `GET /v1/inbox` 补齐离线期间的消息；消息以 `message.id` 去重。

## 5. 数据对象

```ts
type Line = {
  id: string
  state: "queued" | "delivered" | "connected" | "closed"
  role: "initiator" | "recipient"
  myAlias: string
  peerAlias: string | null
  createdAt: number
  updatedAt: number
}

type Message = {
  id: string
  lineId: string
  from: "me" | "peer"
  kind: "text" | "image"
  text?: string        // kind = text
  imageId?: string     // kind = image
  width?: number
  height?: number
  sentAt: number
}
```

## 6. 错误码一览

`stale_timestamp` `bad_signature` `token_expired` `unauthorized` `invalid_text` `invalid_image` `quota_exceeded` `suspended` `awaiting_reply` `line_not_connected` `line_not_ready` `line_closed` `not_found` `internal`
