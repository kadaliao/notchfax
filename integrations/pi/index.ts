/**
 * Notchfax receipt — when an interactive Pi session ends, Notchfax prints its bill from the notch.
 *
 * Hook: `session_shutdown` (quit / new / resume / fork; not reload).
 * Only for hand-started interactive sessions: ctx.mode === "tui", a TTY, no CI, not a subagent.
 * The handler only reads the in-memory session, writes a job file and spawns a detached
 * worker (worker.mjs) that calls Notchfax; failures go to ~/Library/Logs/Notchfax/pi-receipt.log.
 *
 * Turn off: set PI_NOTCHFAX_RECEIPT=0, or delete/move this directory (then /reload).
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { calculateCost } from "@earendil-works/pi-ai";
import { getBuiltinModels } from "@earendil-works/pi-ai/providers/all";
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { log, makePricer, newEntries, render, summarize } from "./receipt.mjs";

// Where this run of the session began: the last entry that already existed when it was opened
// (null for a brand-new session). Kept on globalThis so /reload doesn't move it.
type Mark = { boundaryId: string | null };
const MARKS: Map<string, Mark> = ((globalThis as any).__notchfaxReceiptMarks ??= new Map());

const HERE = dirname(fileURLToPath(import.meta.url));
// When this Pi process started. On a /reload that first loads this extension, entries written
// since then belong to this run even though they already exist.
const PROCESS_START = Date.now() - process.uptime() * 1000;

function interactive(ctx: any): boolean {
	const off = (process.env.PI_NOTCHFAX_RECEIPT || "").toLowerCase();
	if (["0", "off", "false", "no"].includes(off)) return false;
	if (ctx.mode !== "tui" || !process.stdin.isTTY || !process.stdout.isTTY) return false;
	if (process.env.CI || process.env.PI_SUBAGENT_ID || process.env.PI_SUBAGENT_SESSION) return false;
	return true;
}

export default function (pi: ExtensionAPI) {
	pi.on("session_start", (event, ctx) => {
		try {
			const sm = ctx.sessionManager;
			const id = sm.getSessionId();
			if (!id || (event.reason === "reload" && MARKS.has(id))) return;
			// Boundary = last entry already written by an earlier run of this session. Entries older
			// than the header were copied in by a fork and are filtered out by timestamp instead.
			const born = Date.parse(sm.getHeader()?.timestamp ?? "");
			const entries = sm.getEntries();
			const lateLoad = event.reason === "reload";
			let boundaryId: string | null = null, billedBefore = false;
			for (const e of entries as any[]) {
				const t = Date.parse(e.timestamp);
				if (Number.isFinite(born) && Number.isFinite(t) && t < born) continue;
				if (lateLoad && Number.isFinite(t) && t >= PROCESS_START) break;
				boundaryId = e.id;
				if ((e.type === "message" && e.message?.usage) || e.usage) billedBefore = true;
			}
			MARKS.set(id, { boundaryId: billedBefore ? boundaryId : null });
		} catch (err: any) {
			log(`session_start error: ${err?.stack || err}`);
		}
	});

	pi.on("session_shutdown", (event, ctx) => {
		try {
			if (event.reason === "reload" || !interactive(ctx)) return;
			const sm = ctx.sessionManager;
			const header = sm.getHeader();
			const entries = sm.getEntries();
			const sessionId = sm.getSessionId();
			const mark = sessionId ? MARKS.get(sessionId) : undefined;
			if (sessionId) MARKS.delete(sessionId);
			const boundaryId = mark?.boundaryId ?? null;
			const resumed = !!boundaryId;
			const fresh = newEntries(header, entries, boundaryId);
			// A fresh session starts at its header (in the record); a resumed run at its first new entry.
			const headerAt = Date.parse(header?.timestamp ?? "");
			const startAt = !resumed && Number.isFinite(headerAt) ? headerAt : null;

			const builtin = new Map<string, any[]>();
			const find = (provider: string, id: string) => {
				const m = ctx.modelRegistry.find(provider, id);
				if (m) return m;
				if (!builtin.has(provider)) {
					try { builtin.set(provider, getBuiltinModels(provider as any) as any[]); } catch { builtin.set(provider, []); }
				}
				return builtin.get(provider)!.find((x) => x.id === id);
			};
			const summary = summarize(fresh, makePricer(find), calculateCost, startAt);
			const text = render({ summary, sessionId, cwd: header?.cwd || ctx.cwd, resumed, sample: false });
			if (!text) return;

			const job = join(tmpdir(), `notchfax-pi-${process.pid}-${Date.now()}.json`);
			mkdirSync(dirname(job), { recursive: true });
			writeFileSync(job, JSON.stringify({
				text,
				name: `Pi 小票 ${String(sessionId).slice(0, 8)}`,
			}));
			const child = spawn(process.execPath, [join(HERE, "worker.mjs"), job], {
				detached: true, stdio: "ignore", env: { ...process.env, ELECTRON_RUN_AS_NODE: "1" },
			});
			child.on("error", (err) => log(`spawn worker failed: ${err.message}`));
			child.unref();
		} catch (err: any) {
			log(`hook error: ${err?.stack || err}`);
		}
	});
}
