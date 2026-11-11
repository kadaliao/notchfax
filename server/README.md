# Notchfax 中继服务器

Cloudflare Workers + Durable Objects + D1 + R2，实现 [`docs/protocol.md`](../docs/protocol.md) 的全部接口。
设备之间匿名收发"传真"，服务器只做配对、转发、暂存和清理。

| 部分 | 作用 |
|---|---|
| Worker（`src/index.ts`） | HTTP 路由、Ed25519 会话认证、HMAC 令牌 |
| D1（`migrations/`） | 设备、线路、消息、举报 |
| R2 | 1-bit PNG 图片，收件人确认 24 小时后删除 |
| Durable Object `DeviceSocket` | 每台设备一个，持有它的 WebSocket（Hibernation API），新连接顶掉旧连接，30 秒心跳 |
| Cron（每 10 分钟） | 线路超时关闭、删除到期图片、清理关闭超过 30 天的线路 |

## 本地运行

需要 Node 20+ 和 pnpm。全程离线，用 wrangler 本地模拟的 D1 / R2 / Durable Object，不需要 Cloudflare 账号，也不要 `wrangler login`。

```sh
cd server
pnpm install
pnpm dev          # http://127.0.0.1:8787
```

`pnpm dev` 会：缺少 `.dev.vars` 时自动生成一份带随机 `SESSION_SECRET` 的（已被 gitignore；模板见 `.dev.vars.example`），对本地 D1 应用 `migrations/`，然后启动 `wrangler dev`。本地数据在 `.wrangler/state/`，用 `pnpm dev:reset` 清空。

- 健康检查：`GET /healthz`（协议之外的运维接口，无需认证）
- 本地触发定时任务：`curl "http://127.0.0.1:8787/__scheduled?cron=*/10+*+*+*+*"`

## 测试

```sh
pnpm test         # vitest + @cloudflare/vitest-plugin，真实 Workers 运行时（workerd），本地 D1/R2/DO
pnpm typecheck    # wrangler types + tsc
pnpm smoke        # 先在另一个终端 pnpm dev；对着本地服务器走一遍完整流程
```

- 测试里的 `SESSION_SECRET` 是写在 `vitest.config.ts` 里的假值。
- `@cloudflare/vitest-pool-workers` 已被官方改名并弃用，后继包是 `@cloudflare/vitest-plugin`（配置是 `cloudflareTest()` 插件，不再是 pool）。本项目用后者。
- 每个测试前清空 D1 和 R2；线路超时、图片过期通过直接调用 `runMaintenance(env, now)` 并传入"未来时间"来测，不依赖真实等待。
- `pnpm smoke` 每次运行会在本地库里留下两台一次性设备，配对"优先在线"所以通常不影响别的客户端；要干净环境就 `pnpm dev:reset`。

## 真实部署需要什么

仓库里**没有**部署过任何东西，`wrangler.jsonc` 里的 ID 都是占位符。要上线时：

1. `wrangler login`（部署者自己做）。
2. 创建 D1：`wrangler d1 create notchfax`，把返回的 `database_id` 填进 `wrangler.jsonc` 的 `d1_databases[0].database_id`（现在是全 0 的占位符）。
3. 创建 R2 桶：`wrangler r2 bucket create notchfax-images`（桶名与 `r2_buckets[0].bucket_name` 一致，或改成自己的名字）。图片不要开公开访问，只通过 Worker 读取。
4. 设置密钥：`openssl rand -base64 32 | wrangler secret put SESSION_SECRET`。轮换它会让所有已签发的会话令牌失效，客户端会自动重新建立会话。
5. 应用迁移：`wrangler d1 migrations apply DB --remote`。
6. `wrangler deploy`。Durable Object 迁移（`new_sqlite_classes`）和 cron 触发器随部署一起生效。
7. 自定义域名、Cloudflare 边缘的速率限制规则（按需，服务器本身不按 IP 限流，因为不记录 IP）。

隐私相关的配置已经写在 `wrangler.jsonc`：`observability.enabled = false`，代码不读取也不记录 `CF-Connecting-IP` 等头，日志只输出错误消息。部署后不要在 Cloudflare 侧开 Logpush / Tail 之类会带请求元数据的功能。

## 设计要点

- **身份**：Ed25519（WebCrypto）。`deviceId = base64url(SHA-256(公钥))[0:22]`。令牌是 `base64url(JSON{d,i,e}).base64url(HMAC-SHA256)`，24 小时有效；签名对但过期返回 `token_expired`，其余无效情况返回 `unauthorized`。
- **别名**：每条线路每一方各自随机 4 位十六进制，与设备无关，所以跨线路无法关联。线路、消息、图片 ID 都是随机 UUID。
- **配对**：最近 7 天活跃或当前在线的设备，优先在线、其次随机；排除自己、有过举报关系的设备、今天已收满 5 条新线路的设备、被暂停的设备。找不到人就 `queued`，之后设备建立会话（`POST /v1/session`）或连上 socket 时，按先来后到把排队的传真配给它。
- **额度**：按 UTC 日惰性重置（只存"已用数 + 对应日期"）。每台设备每天新线路上限默认 3，对方每回复一次 +1，最高 10；上限是设备的持久属性。
- **图片**：必须 `connected`（服务器侧判断，先于读取请求体）。校验 PNG 签名、IHDR（灰度、1 位、宽 ≤ 384、高 ≤ 768）、全部数据块的长度与 CRC、至少一个 IDAT、以 IEND 结尾且无尾随数据、≤ 64 KB。每条线路每人每天 10 张，计数与插入在同一条 SQL 里完成，并发下也不会超。
- **离线补投**：消息先落库，再尽力推 socket；`GET /v1/inbox` 返回所有未确认的对方消息。确认后文字置空（保留元数据用于计数），图片 24 小时后由 cron 删除，取图接口也会拒绝已过期的图片。
- **在线状态**：`DeviceSocket` 在连接/断开时写 `devices.online`；心跳 30 秒一次，100 秒没有任何客户端消息就关闭连接并标记离线；推送时发现没有存活连接也会纠正标记。

## 已知限制

- 配对用 `ORDER BY RANDOM()` 扫描最近活跃的设备，规模到几十万活跃设备以上需要换成抽样方案。
- 没有按 IP 的速率限制（设计上不记录 IP），滥用防护只有协议里的额度、举报和暂停。
- 心跳用 Durable Object alarm 每 30 秒唤醒一次，在线设备多时会产生持续的 DO 请求费用。
