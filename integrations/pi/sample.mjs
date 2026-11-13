#!/usr/bin/env node
// Manual receipt for a session file, using the same accounting as the hook.
//   node sample.mjs <session.jsonl> [--dry-run]
// Prints a "样票" (does not mark anything billed).
// Run it with the node that runs pi. If pi is installed elsewhere, point PI_PKG at the
// @earendil-works/pi-coding-agent package directory.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { NOTCHFAX_BIN, makePricer, newEntries, render, summarize } from "./receipt.mjs";

const PKG = process.env.PI_PKG || join(dirname(process.execPath), "../lib/node_modules/@earendil-works/pi-coding-agent");
if (!existsSync(join(PKG, "package.json"))) {
	console.error(`pi not found at ${PKG}; set PI_PKG to the @earendil-works/pi-coding-agent package directory`);
	process.exit(2);
}
const AI = join(PKG, "node_modules/@earendil-works/pi-ai/dist");
const { calculateCost } = await import(pathToFileURL(join(AI, "index.js")).href);
const { getBuiltinModels } = await import(pathToFileURL(join(AI, "providers/all.js")).href);
const { ModelRuntime } = await import(pathToFileURL(join(PKG, "dist/index.js")).href);
const runtime = await ModelRuntime.create();

const file = process.argv[2];
if (!file) { console.error("usage: node sample.mjs <session.jsonl> [--dry-run]"); process.exit(2); }
const lines = readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
const header = lines.find((e) => e.type === "session");
const entries = lines.filter((e) => e.type !== "session");

const builtin = new Map();
const find = (p, id) => runtime.getModel(p, id) || (builtin.has(p) ? builtin.get(p) : (builtin.set(p, (() => { try { return getBuiltinModels(p); } catch { return []; } })()), builtin.get(p))).find((m) => m.id === id);

const born = Date.parse(header?.timestamp ?? "");
const summary = summarize(newEntries(header, entries, null), makePricer(find), calculateCost, Number.isFinite(born) ? born : null);
const text = render({ summary, sessionId: header?.id, cwd: header?.cwd, resumed: false, sample: true });
if (!text) { console.error("nothing to bill"); process.exit(1); }
console.log(text);
if (!process.argv.includes("--dry-run")) {
	const r = spawnSync(NOTCHFAX_BIN, ["print", "--quiet", "--name", `Pi 样票 ${String(header?.id).slice(0, 8)}`], { input: text, encoding: "utf8", timeout: 60_000 });
	console.log(r.status === 0 ? "\n已送去 Notchfax 打印。" : `\n打印失败 (${r.status}): ${r.stderr}`);
}
process.exit(0);
