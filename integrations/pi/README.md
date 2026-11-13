# Notchfax receipts for Pi

When an interactive [Pi](https://github.com/earendil-works/pi) session ends, Notchfax prints a receipt: project, start/end time, duration, one section per model with input/output/cache tokens and their cost, and the total.

## Install

```sh
mkdir -p ~/.pi/agent/extensions/notchfax-receipt
cp index.ts receipt.mjs worker.mjs sample.mjs ~/.pi/agent/extensions/notchfax-receipt/
```

Pi auto-discovers `~/.pi/agent/extensions/*/index.ts`; run `/reload` in a running session, or start a new one.

Try it on a session file without printing:

```sh
node ~/.pi/agent/extensions/notchfax-receipt/sample.mjs ~/.pi/agent/sessions/<dir>/<file>.jsonl --dry-run
```

Run it with the same `node` that runs pi; if pi is installed elsewhere, set `PI_PKG` to the `@earendil-works/pi-coding-agent` package directory. Drop `--dry-run` to print a 样票.

## How it works

| File | Role |
|---|---|
| `index.ts` | The extension. `session_start` remembers where this run of the session began; `session_shutdown` (quit / new / resume / fork, not reload) bills the entries since then. |
| `receipt.mjs` | Accounting and layout, no Pi imports. Prices come from Pi's own model catalog (`calculateCost` from `pi-ai`), matched against official vendors only, so a proxy's model id like `auto/claude-…` is priced at the vendor's list price. A model with no official price is listed without a cost. |
| `worker.mjs` | Detached process that calls `notchfax print`, so the hook returns at once. |
| `sample.mjs` | Manual receipt for a session file. |

Only hand-started interactive sessions print: `ctx.mode === "tui"`, a TTY on both ends, no `CI`, not a subagent (`PI_SUBAGENT_ID` / `PI_SUBAGENT_SESSION`). A resumed session bills only what was added in this run; entries a fork copied from its parent are never billed.

Failures go to `~/Library/Logs/Notchfax/pi-receipt.log`. The receipt is printed by `/Applications/Notchfax.app/Contents/MacOS/Notchfax` (override with `NOTCHFAX_BIN`).

## Turn it off

Set `PI_NOTCHFAX_RECEIPT=0`, or remove `~/.pi/agent/extensions/notchfax-receipt/` and `/reload`.
