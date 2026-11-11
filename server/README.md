# Notchfax 中继服务器

Cloudflare Workers + Durable Objects + D1，实现 [`docs/protocol.md`](../docs/protocol.md) 的全部接口。
设备之间匿名收发"传真"，服务器只做配对、转发、暂存和清理。**Cloudflare 免费套餐就够用**：不需要 R2，也没有任何按设备周期运行的定时器。

| 部分 | 作用 |
|---|---|
| Worker（`src/index.ts`） | HTTP 路由、Ed25519 会话认证、HMAC 令牌 |
| D1（`migrations/`） | 设备、线路、消息、举报，以及 1-bit PNG 图片（BLOB，每张 ≤ 64 KB） |
| Durable Object `DeviceSocket` | 每台设备一个，持有它的 WebSocket（Hibernation API），新连接顶掉旧连接（关闭码 4000）。心跳由客户端发起，服务器用 auto-response 回 `pong`，不唤醒对象 |
| Cron（每 10 分钟） | 线路超时关闭、删除到期图片、清理关闭超过 30 天的线路。每次的工作量有上限 |

## 本地运行

需要 Node 20+ 和 pnpm。全程离线，用 wrangler 本地模拟的 D1 / Durable Object，不需要 Cloudflare 账号，也不要 `wrangler login`。

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
pnpm test         # vitest + @cloudflare/vitest-plugin，真实 Workers 运行时（workerd），本地 D1/DO
pnpm typecheck    # wrangler types + tsc
pnpm smoke        # 先在另一个终端 pnpm dev；对着本地服务器走一遍完整流程（含客户端心跳 ping → pong）
```

- 测试里的 `SESSION_SECRET` 是写在 `vitest.config.ts` 里的假值。
- `@cloudflare/vitest-pool-workers` 已被官方改名并弃用，后继包是 `@cloudflare/vitest-plugin`（配置是 `cloudflareTest()` 插件，不再是 pool）。本项目用后者。
- 每个测试前清空 D1；线路超时、图片过期通过直接调用 `runMaintenance(env, now)` 并传入"未来时间"来测，不依赖真实等待。
- `test/cost.test.ts` 是**免费额度成本回归测试**：先往库里灌几百台设备、几百条线路，再逐个接口量 D1 的查询次数、读行数、写行数（`meta.rows_read / rows_written`，本地与线上同口径），并断言上限。有人把某个查询改成全表扫描，或在热路径上多加一个索引，这里会直接红。
- `pnpm smoke` 每次运行会在本地库里留下两台一次性设备；配对"优先在线"所以通常不影响别的客户端，要干净环境就 `pnpm dev:reset`。

## 部署（免费套餐就够）

仓库里**没有**部署过任何东西，`wrangler.jsonc` 里的 `database_id` 是全 0 的占位符。上线时：

```sh
cd server
pnpm install
pnpm exec wrangler login                                      # 部署者自己做
pnpm exec wrangler d1 create notchfax                         # 记下输出里的 database_id
#   → 把它填进 wrangler.jsonc 的 d1_databases[0].database_id（替换全 0 的占位符）
pnpm exec wrangler d1 migrations apply DB --remote            # 建表（0001、0002）
openssl rand -base64 32 | pnpm exec wrangler secret put SESSION_SECRET
pnpm exec wrangler deploy                                     # Durable Object 迁移与 cron 触发器随部署一起生效
```

- `SESSION_SECRET` 轮换会让已签发的会话令牌失效，客户端会自动重新建立会话。
- 自定义域名、Cloudflare 边缘的速率限制规则（按需；服务器本身不按 IP 限流，因为不记录 IP）。
- 隐私相关的配置已经写在 `wrangler.jsonc`：`observability.enabled = false`，代码不读取也不记录 `CF-Connecting-IP` 等头，日志只输出错误消息。部署后不要在 Cloudflare 侧开 Logpush / Tail 之类会带请求元数据的功能。
- 免费套餐的限额是硬上限：超过后对应操作直接报错，不会扣费。用量在 Cloudflare 控制台的 Workers / D1 / Durable Objects 页面看，次日 00:00 UTC 重置。

## 免费套餐容量估算

下面的数字是**估算**，用来看哪个限额先到，不是承诺。限额：Workers 10 万请求/天、每次调用 10 ms CPU、每次调用最多 50 次 D1 查询；D1 每天 10 万行写入 / 500 万行读取、单库 500 MB；Durable Object 每天 10 万请求。

**每个操作的 D1 成本**（`test/cost.test.ts` 在 600 台设备 / 300 条线路的库上量出来的，与库大小无关）：

| 操作 | 查询 | 读行 | 写行 |
|---|---|---|---|
| 已认证的普通请求（`/v1/me` 等） | 1 | 1 | **0**（`last_seen` 最多每 6 小时刷新一次） |
| 新设备建立会话 / 重复建立会话 | 3 / 2 | 1 / 2 | 2 / 0 |
| 发新传真（配到人） | 5 | ~6 | 9 |
| 确认（ack）文字 / 图片 | 2 | 2 | 1 / 2 |
| 回复（线路接通） | 4 | 7 | 6 |
| 接通后的文字 | 3 | 6 | 4 |
| 发图 | 3 | ~16 | 7 |
| 取图 | 3 | 4 | 0 |
| 撕掉线路 | 3 | ~12 | 3 |

写入行数是 D1 先到的限额，所以：devices / lines / messages 用 `WITHOUT ROWID`，索引全是部分索引、只覆盖还在用的行，同一次请求里的多条写入合成一个 `batch`（算一次查询）。

**假设**：每个活跃设备每天建立 1 次会话、连 2 次 socket、每次连接后拉一次 `/v1/inbox` 和 `/v1/lines`；发出的传真一半会被回复，接通后平均再聊 2 条文字 + 1 张图，之后撕掉；对方 60% 的时间在线；图片平均 20 KB。一次"被回复的传真"约 47 次写入（含图片删除和 30 天后清理），"没人回的传真"约 14 次，平均 **≈ 31 次写入/封**；每个活跃设备的常驻开销（刷新、上线下线标记）≈ 14 次写入/天。

| 每个设备每天发几封 | 先到的限额 | 日活设备上限 | 对应每天传真数 |
|---|---|---|---|
| 1 | D1 写入 | ≈ 2,200 | ≈ 2,200 |
| 3（默认每日额度） | D1 写入 | ≈ 900 | ≈ 2,800 |
| 任意 | D1 写入的天花板 | — | **≈ 3,000 封/天**（≈ 1,500 次被回复的对话） |

按同样假设，Worker 请求约 16 次/设备/天（发 1 封时）→ 日活上限 ≈ 6,000；D1 读行远低于 500 万（配对每封 ~5 行，与设备总数无关）；D1 存储在 ≈ 1,500 次对话/天时约 250 MB（线路和消息元数据保留到关闭后 30 天，图片确认后 1 天删除），都排在 D1 写入之后。

**最大的不确定项是心跳**：协议要求客户端每 30 秒发一次 `ping`，服务器用 auto-response 回复，不唤醒对象。Cloudflare 文档说 auto-response 不计时长，但没说明这些入站 WebSocket 消息是否仍按"20 条算 1 个请求"计入 Durable Object 请求数。若计入：一台设备连接 8 小时 = 960 次 ping ≈ 48 个 DO 请求/天，连接 24 小时 ≈ 144 个。那么 DO 请求会和 D1 写入同时成为瓶颈：每天连 8 小时的设备日活上限 ≈ 1,900，全天在线的设备 ≈ 650。若不计入，则这一项可以忽略（每设备约 4 个 DO 请求/天：连接 2 次 + 推送）。部署后看一两天 DO 请求数就能确定；如果它先到限额，把客户端心跳从 30 秒放宽到 60 秒就减半。

## 设计要点

- **身份**：Ed25519（WebCrypto）。`deviceId = base64url(SHA-256(公钥))[0:22]`。令牌是 `base64url(JSON{d,i,e}).base64url(HMAC-SHA256)`，24 小时有效；签名对但过期返回 `token_expired`，其余无效情况返回 `unauthorized`。一次会话建立（Ed25519 验签 + SHA-256 + HMAC）的 CPU 开销按本机基准估算在 1 ms 量级，远低于 10 ms。
- **别名**：每条线路每一方各自随机 4 位十六进制，与设备无关，所以跨线路无法关联。线路、消息、图片 ID 都是随机 UUID。
- **配对不扫表**：每台设备有一个随机键 `rnd`；挑收件人时从一个随机位置起顺着索引最多看 8 个设备，取第一个合格的（在线的优先，其次最近 7 天活跃的），到头就绕回开头，一条 SQL 搞定。读行数与设备总数无关。排除：自己、有过举报关系的设备、今天已收满 5 条新线路的设备（计数在 `devices.recv_day/recv_count` 上）、被暂停的设备。7 天没活跃的设备由 cron 每小时移出配对池（`rnd = NULL`），下次它发请求时自动回来。找不到人就 `queued`，之后设备建立会话或连上 socket 时，按先来后到把排队的传真配给它。
- **额度**：按 UTC 日惰性重置（只存"已用数 + 对应日期"）。每台设备每天新线路上限默认 3，对方每回复一次 +1，最高 10；上限是设备的持久属性。
- **图片**：存在 D1 的 `images` 表（BLOB），只做插入和删除，不更新。必须 `connected`（服务器侧判断，先于读取请求体）。校验 PNG 签名、IHDR（灰度、1 位、宽 ≤ 384、高 ≤ 768）、全部数据块的长度与 CRC、至少一个 IDAT、以 IEND 结尾且无尾随数据、≤ 64 KB。每条线路每人每天 10 张，图片和消息元数据在同一个 `batch` 里按同一条件插入，并发下也不会超。图片确认 24 小时后由 cron 删除，取图接口也会拒绝已过期的图片。
- **离线补投**：消息先落库（带收件人 `to_id`），再尽力推 socket；`GET /v1/inbox` 按 `to_id` 返回所有未确认的对方消息。确认后文字置空（保留元数据用于计数）。
- **在线状态与推送**：`devices.online` 只在连接 / 断开时各写一次（不是周期写入）。推送前先看 D1 里顺带读到的在线标记，离线就不去叫醒 Durable Object。标记说在线但对象里一个存活连接都没有时，推送会把标记纠正过来。
- **心跳**：客户端每 30 秒发文本帧 `{"type":"ping"}`，Durable Object 用 `setWebSocketAutoResponse` 回 `{"type":"pong"}`，对象保持休眠。服务器没有任何周期定时器（不用 alarm），Durable Object 自己的存储从不写入。
- **定时任务有上限**：每次最多关闭 100 条超时线路、清理 25 条旧线路、删 100 张到期图片，整个运行 ≤ 10 次 D1 查询（免费套餐每次调用上限 50）；积压留给下一次。超时的线路被访问时还会惰性关闭，所以 cron 晚几个周期无关紧要。

## 已知限制

- 连接中的设备只在连接 / 断开时写在线标记；设备断网但服务器没收到关闭事件时，标记会暂时偏"在线"，直到下一次推送发现没有存活连接并纠正。后果仅是配对多选了一次这台设备，消息仍会留在它的收件箱里。
- 没有按 IP 的速率限制（设计上不记录 IP），滥用防护只有协议里的额度、举报和暂停。
- 接通线路的 30 天超时点只在偏差超过 6 小时时才重写（省一次索引写入），所以实际超时可能比"最后一条消息后 30 天"早最多 6 小时。
- 配对窗口只有 8 个设备：配对池里大部分设备都已收满时，传真可能排队，等有合格设备上线再配。
- 设备记录从不删除（每台设备一行，几十字节）。
- 图片读写要把 BLOB 在 JS 里转成数组；一张 64 KB 的图在 Workers 上大约占几 ms CPU，贴近免费套餐每次调用 10 ms 的限额（典型 10–25 KB 的图远低于）。本地没法量线上 CPU，这个数字是按本机基准推算的。
