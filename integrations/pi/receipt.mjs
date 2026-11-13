// Notchfax receipt: pure accounting + layout, shared by the Pi extension (index.ts)
// and the manual tool (sample.mjs). No Pi imports here; price lookup is injected.
// Layout follows the shared receipt format in ../README.md.

import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";

// Full path on purpose: hooks may run with a thin PATH. NOTCHFAX_BIN overrides (testing only).
export const NOTCHFAX_BIN = process.env.NOTCHFAX_BIN || "/Applications/Notchfax.app/Contents/MacOS/Notchfax";
export const LOG_PATH = join(homedir(), "Library/Logs/Notchfax/pi-receipt.log");

// Vendors whose catalog prices are the vendor's own list prices (not resellers/aggregators).
export const OFFICIAL_PROVIDERS = [
	"anthropic", "openai", "google", "deepseek", "xai", "zai", "moonshotai",
	"minimax", "mistral", "xiaomi", "meta", "ant-ling",
];

export function log(message) {
	try {
		mkdirSync(dirname(LOG_PATH), { recursive: true });
		appendFileSync(LOG_PATH, `${new Date().toISOString()} ${message}\n`);
	} catch {}
}

/**
 * Build a price finder. `find(provider, id)` returns a Model (with .cost, .name) or undefined.
 * The model id is matched against official vendor catalogs only; a proxy prefix such as
 * "auto/" or "openai/" is dropped. Unknown models return null (no price is printed).
 */
export function makePricer(find) {
	const cache = new Map();
	return (provider, modelId) => {
		const key = `${provider}\u0000${modelId}`;
		if (cache.has(key)) return cache.get(key);
		const bare = String(modelId || "").split("/").pop();
		const order = OFFICIAL_PROVIDERS.includes(provider)
			? [provider, ...OFFICIAL_PROVIDERS.filter((p) => p !== provider)]
			: OFFICIAL_PROVIDERS;
		let hit = null;
		for (const id of [modelId, bare]) {
			for (const p of order) {
				const m = find(p, id);
				if (m && m.cost) { hit = m; break; }
			}
			if (hit) break;
		}
		cache.set(key, hit);
		return hit;
	};
}

const ts = (e) => {
	const t = Date.parse(e?.timestamp);
	return Number.isFinite(t) ? t : null;
};

/** Usage-bearing records in an entry: [{ provider, model, usage }]. */
function usagesOf(entry) {
	if (entry.type === "message") {
		const m = entry.message || {};
		if (m.role === "assistant" && m.usage) return [{ provider: m.provider, model: m.model, usage: m.usage }];
		if (m.role === "toolResult" && m.usage) return [{ provider: null, model: null, usage: m.usage, label: "工具内模型调用" }];
		return [];
	}
	if (entry.type === "usage" && entry.usage) return [{ provider: entry.provider, model: entry.model, usage: entry.usage }];
	if ((entry.type === "compaction" || entry.type === "branch_summary") && entry.usage)
		return [{ provider: null, model: null, usage: entry.usage, label: entry.type === "compaction" ? "压缩摘要" : "分支摘要" }];
	return [];
}

/**
 * Entries of this run only: after `boundaryId` (the last entry that existed when the session was
 * opened, for a resumed session), and never older than the session header (a fork copies its
 * parent's entries). `boundaryId` null = fresh session, bill everything since the header.
 */
export function newEntries(header, entries, boundaryId) {
	let start = 0;
	if (boundaryId) {
		const i = entries.findIndex((e) => e.id === boundaryId);
		if (i >= 0) start = i + 1;
	}
	const born = ts(header);
	return entries.slice(start).filter((e) => born === null || ts(e) === null || ts(e) >= born);
}

/**
 * Sum the given entries. `price(provider, model)` -> catalog Model or null.
 * `calculateCost(model, usage)` -> cost object (pi-ai's own formula, tiers and 1h cache included).
 */
export function summarize(entries, price, calculateCost, startAt = null) {
	const buckets = new Map();
	let first = startAt, last = null, calls = 0;
	for (const e of entries) {
		const t = ts(e);
		if (t !== null) { first = first === null ? t : Math.min(first, t); last = last === null ? t : Math.max(last, t); }
		for (const u of usagesOf(e)) {
			calls++;
			const official = u.model ? price(u.provider, u.model) : null;
			const name = official?.name || u.label || u.model || "未知模型";
			const key = official ? `${official.provider}/${official.id}` : `?${name}`;
			let b = buckets.get(key);
			if (!b) {
				b = { name, priced: !!official, input: 0, output: 0, cacheRead: 0, cacheWrite: 0,
					cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
				buckets.set(key, b);
			}
			const n = (v) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
			const us = u.usage;
			b.input += n(us.input); b.output += n(us.output);
			b.cacheRead += n(us.cacheRead); b.cacheWrite += n(us.cacheWrite);
			if (official) {
				const copy = { ...us, input: n(us.input), output: n(us.output), cacheRead: n(us.cacheRead),
					cacheWrite: n(us.cacheWrite), cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
				const c = calculateCost(official, copy);
				for (const k of ["input", "output", "cacheRead", "cacheWrite"]) b.cost[k] += n(c[k]);
			}
		}
	}
	const list = [...buckets.values()].map((b) => ({ ...b, total: b.cost.input + b.cost.output + b.cost.cacheRead + b.cost.cacheWrite }));
	list.sort((a, b) => (b.priced - a.priced) || (b.total - a.total));
	return { buckets: list, first, last, calls };
}

// ---------------------------------------------------------------- layout

const money = (v) => (v > 0 && v < 0.005 ? "<$0.01" : `$${v.toFixed(2)}`);
function tokens(c) {
	if (c < 10_000) return c.toLocaleString("en-US");
	if (c < 100_000_000) return `${(c / 10_000).toFixed(1).replace(/\.0$/, "")}万`;
	return `${(c / 100_000_000).toFixed(2).replace(/\.?0+$/, "")}亿`;
}
function duration(ms) {
	const s = Math.max(0, Math.floor(ms / 1000));
	if (s < 60) return `${s} 秒`;
	const m = Math.floor(s / 60);
	if (m < 60) return `${m} 分`;
	const h = Math.floor(m / 60), r = m % 60;
	return r ? `${h} 小时 ${r} 分` : `${h} 小时`;
}
const clock = (t) => {
	const d = new Date(t), p = (x) => String(x).padStart(2, "0");
	return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
};
const clip = (s, n) => { s = String(s).replace(/\s+/g, " ").trim(); return s.length <= n ? s : `${s.slice(0, n - 1)}…`; };

/** Returns the receipt text, or null when there is nothing to bill. */
export function render({ summary, sessionId, cwd, resumed, sample }) {
	if (!summary.calls) return null;
	const kind = sample ? "样票 · 会话进行中" : resumed ? "会话小票 · 续" : "会话小票";
	const L = ["# PI", `^ > ${kind} No.${String(sessionId || "").slice(0, 8).toUpperCase()}`, "---"];
	const project = basename(String(cwd || "").replace(/\/+$/, ""));
	if (project) L.push(`项目\t${clip(project, 18)}`);
	if (summary.first !== null && summary.last !== null) {
		L.push(`开始\t${clock(summary.first)}`);
		L.push(`${sample ? "截至" : "结束"}\t${clock(summary.last)}`);
		L.push(`用时\t${duration(summary.last - summary.first)}`);
	}
	L.push("---");
	const unpriced = [];
	for (const b of summary.buckets) {
		if (!b.priced) {
			unpriced.push(b.name);
			L.push(`## ${clip(b.name, 22)}\t未知价格`);
			L.push(`> 输入 ${tokens(b.input + b.cacheRead + b.cacheWrite)} · 输出 ${tokens(b.output)}`);
			continue;
		}
		L.push(`## ${clip(b.name, 22)}\t${money(b.total)}`);
		for (const [label, count, cost] of [
			["输入", b.input, b.cost.input],
			["输出", b.output, b.cost.output],
			["缓存写", b.cacheWrite, b.cost.cacheWrite],
			["缓存读", b.cacheRead, b.cost.cacheRead],
		]) if (count) L.push(`> ${label} ${tokens(count)}\t${money(cost)}`);
	}
	L.push("---");
	const priced = summary.buckets.filter((b) => b.priced);
	if (priced.length) {
		L.push(`# 合计\t${money(priced.reduce((s, b) => s + b.total, 0))}`);
		L.push("^ > 按官方 API 标价估算");
	}
	if (unpriced.length) L.push(`^ > ${clip(unpriced.join("、"), 30)} 不在价目表上，未计入`);
	if (resumed) L.push("^ > 续接会话，只计本次新增");
	L.push("===", "^ > 谢谢惠顾 · 欢迎再来");
	return L.join("\n");
}
