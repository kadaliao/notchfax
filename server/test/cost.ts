import { env } from "cloudflare:workers";
import worker from "../src/index";
import type { AppEnv } from "../src/types";

/** 每次请求的 D1 用量：查询次数、读/写行数（写行数包含索引写入，与 D1 计费口径一致）。 */
export interface Cost {
  queries: number;
  read: number;
  written: number;
}

class Meter {
  cost: Cost = { queries: 0, read: 0, written: 0 };
  /** 每条查询的读/写行数（调试用）。 */
  trace: Array<{ sql: string; read: number; written: number }> = [];
  record(meta: { rows_read?: number; rows_written?: number }, sql = "") {
    this.trace.push({ sql: sql.replace(/\s+/g, " ").slice(0, 90), read: meta.rows_read ?? 0, written: meta.rows_written ?? 0 });
    this.cost.queries++;
    this.cost.read += meta.rows_read ?? 0;
    this.cost.written += meta.rows_written ?? 0;
  }
}

function wrapStatement(stmt: D1PreparedStatement, meter: Meter, sql = ""): D1PreparedStatement {
  return new Proxy(stmt, {
    get(target, prop) {
      if (prop === "__raw") return target;
      if (prop === "bind") return (...args: unknown[]) => wrapStatement(target.bind(...args), meter, sql);
      if (prop === "run") {
        return async () => {
          const r = await target.run();
          meter.record(r.meta, sql);
          return r;
        };
      }
      if (prop === "all") {
        return async () => {
          const r = await target.all();
          meter.record(r.meta, sql);
          return r;
        };
      }
      if (prop === "first") {
        // first() 不带 meta：用 all() 取同样的行，再取第一行
        return async (col?: string) => {
          const r = await target.all();
          meter.record(r.meta, sql);
          const row = (r.results[0] ?? null) as Record<string, unknown> | null;
          return col && row ? row[col] : row;
        };
      }
      if (prop === "raw") {
        return async (...args: unknown[]) => {
          const rows = await (target.raw as (...a: unknown[]) => Promise<unknown>)(...args);
          meter.record({});
          return rows;
        };
      }
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
}

/** 返回一个带计数的 env（只代理 D1），以及读取累计用量的函数。 */
export function meteredEnv(): { env: AppEnv; meter: Meter } {
  const meter = new Meter();
  const db = env.DB;
  const wrapped = new Proxy(db, {
    get(target, prop) {
      if (prop === "prepare") return (sql: string) => wrapStatement(target.prepare(sql), meter, sql);
      if (prop === "batch") {
        return async (stmts: D1PreparedStatement[]) => {
          // 语句来自带计数的 prepare()：单条语句 run 时已计数，批量里不会走 run()，这里按结果累计
          const raw = stmts.map((s) => (s as unknown as { __raw?: D1PreparedStatement }).__raw ?? s);
          const results = await target.batch(raw);
          meter.cost.queries++; // 一个 batch 只算一次子请求
          for (const r of results) {
            meter.cost.read += r.meta.rows_read ?? 0;
            meter.cost.written += r.meta.rows_written ?? 0;
          }
          meter.trace.push({ sql: `batch(${results.length})`, read: results.reduce((n, r) => n + (r.meta.rows_read ?? 0), 0), written: results.reduce((n, r) => n + (r.meta.rows_written ?? 0), 0) });
          return results;
        };
      }
      const value = Reflect.get(target, prop, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  const proxied = new Proxy(env as AppEnv, {
    get(target, prop, receiver) {
      if (prop === "DB") return wrapped;
      return Reflect.get(target, prop, receiver);
    },
  });
  return { env: proxied, meter };
}

/** 用带计数的 env 发一个请求，返回响应状态/JSON 和这次请求的 D1 用量。 */
export async function metered(
  path: string,
  opts: { method?: string; token?: string; body?: unknown; headers?: Record<string, string> } = {},
): Promise<{ status: number; body: any; cost: Cost; trace: Meter["trace"] }> {
  const { env: menv, meter } = meteredEnv();
  const headers: Record<string, string> = { ...opts.headers };
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;
  let body: BodyInit | undefined;
  if (opts.body !== undefined) {
    if (opts.body instanceof Uint8Array) body = opts.body as BodyInit;
    else {
      headers["content-type"] ??= "application/json";
      body = JSON.stringify(opts.body);
    }
  }
  const req = new Request(`http://notchfax.test${path}`, {
    method: opts.method ?? (opts.body !== undefined ? "POST" : "GET"),
    headers,
    body,
  });
  const ctx = { waitUntil() {}, passThroughOnException() {} } as unknown as ExecutionContext;
  const res = await worker.fetch(req as never, menv as never, ctx);
  const text = await res.text();
  let parsed: any = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = text;
  }
  return { status: res.status, body: parsed, cost: { ...meter.cost }, trace: meter.trace };
}
