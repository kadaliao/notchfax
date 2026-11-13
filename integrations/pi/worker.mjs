// Background half of the Notchfax receipt: runs detached from Pi.
// argv[2] = job file (JSON: { text, name }). Never throws; errors go to the log.

import { readFileSync, rmSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { NOTCHFAX_BIN, log } from "./receipt.mjs";

const jobPath = process.argv[2];
try {
	const job = JSON.parse(readFileSync(jobPath, "utf8"));
	const r = spawnSync(NOTCHFAX_BIN, ["print", "--quiet", "--name", job.name], {
		input: job.text, encoding: "utf8", timeout: 60_000,
	});
	if (r.error || r.status !== 0)
		log(`notchfax print failed (${r.error ? r.error.message : `exit ${r.status}`}): ${(r.stderr || "").trim()}`);
} catch (err) {
	log(`worker error: ${err?.stack || err}`);
} finally {
	try { rmSync(jobPath, { force: true }); } catch {}
}
