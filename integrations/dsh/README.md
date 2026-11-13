# Notchfax receipts for DeepSeek Harness

When a DeepSeek Harness **desktop** session ends, Notchfax prints a receipt from the screen notch: project directory, start/end time, duration, model, input/output tokens, cost at DeepSeek's list price, and the total on the last line.

"Ends" covers both ways a conversation really stops here:

1. **Archive session** — the user marks the conversation done (receipt prints immediately).
2. **Quit the app** — every live session tears down, one receipt each.

Archiving bills the segment up to the archive; the session can still be unarchived and resumed, and its next end bills only what was appended after the previous receipt.

## Install

1. Copy this directory to `~/.dsh/plugins/dsh-notchfax-receipt/`.
2. Append the row in [`cordis.patch.yml`](cordis.patch.yml) to `~/.dsh/profiles/desktop/cordis.patch.yml`, with `name` set to the absolute path of `index.js` (back the file up first).
3. `dsh-hmr` picks the row up while the app runs; restarting the app works too. The log shows `mounted` and `archive watcher on`.
4. Try it without printing: `python3 ~/.dsh/plugins/dsh-notchfax-receipt/receipt.py --session <session-id> --dry-run --no-state`.

The receipt is printed by `/Applications/Notchfax.app/Contents/MacOS/Notchfax` (override with `NOTCHFAX_BIN`). `.zstd` session logs need the `zstd` command (`brew install zstd`).

## Where it lives

| What | Path |
|---|---|
| Plugin + receipt script | `~/.dsh/plugins/dsh-notchfax-receipt/` (`index.js`, `receipt.py`, `package.json`) |
| Profile patch row | `~/.dsh/profiles/desktop/cordis.patch.yml`, entry `id: notchfax-receipt` (`name` = absolute path to `index.js`) |
| Receipt log | `~/Library/Logs/Notchfax/dsh-receipt.log` |
| Billing watermark | `~/Library/Application Support/Notchfax/dsh-receipts.json` |

## How each trigger is detected

This DSH build has no SessionEnd hook seam (the Claude/Codex hooks bridge does not map `SessionEnd`, and the bridge package is not in the app bundle).

**Quit — agent teardown.** From `agent/created` the plugin registers an async `ctx.effect` disposer on the agent's scoped context. Cordis awaits it during teardown, after the loop is quiescent and before the session leaves the store, so the log can still be flushed there. On app quit the whole fiber tree is disposed (5 s cap); the disposer flushes (bounded at 2 s), spawns the helper detached, and returns.

**Archive — polling the durable archive set.** Archiving does *not* dispose the agent, and the Host exposes no archive event: `workspace/session-stop` only fires when the UI also has to stop running work, so it misses archiving an idle conversation. The registry's `archivedSessionIds` set is the durable fact, so the plugin polls it every 1.5 s, diffs it against the set at mount, and on a newly archived id: flushes the live session (if any) and spawns the helper. Unarchiving drops the id again, so a later re-archive bills again. The first successful read only seeds the baseline (this machine already had 38 archived sessions at install time, and none of them printed); `spawned receipt` / `printed` lines in the log show real events.

Both paths share one process-wide arm table keyed by session id, so a session that was billed at archive time produces no second receipt at quit; only genuinely new events would.

### Which sessions print

Only root, human-started sessions in the Desktop host:

- skipped: subagent and forked sessions (`origin: 'subagent'`, `parentSession`, `delegationDepth > 0`);
- skipped: sessions whose cwd is a bot workspace (`~/Bots`, `~/.dsh/Bots`, `~/.dsh/bots`);
- skipped: other host processes. The plugin refuses to arm unless it runs inside the Desktop app (`process.versions.electron`, logged);
- nothing new in the log (no model usage since the last receipt) → no receipt.

## What a receipt shows, and from where

Everything comes from the durable session log (`~/.dsh/sessions/<workspace>/<session-id>/session.v4.jsonl.zstd`):

- project = basename of the session `cwd`; start/end = first/last event times of the billed segment; duration = their difference;
- model = `request/context` / `request/header` route, rendered with its display name;
- input = `usage.inputTokens` (uncached), output = `usage.outputTokens`, cache read = `usage.cacheReadTokens`, summed over `assistant/message` and `assistant/attempt` events after the watermark;
- cost = those token counts at DeepSeek's published list price ([api-docs.deepseek.com](https://api-docs.deepseek.com/quick_start/pricing/)), split per request into peak (01:00–04:00 and 06:00–10:00 UTC, Mon–Fri) and off-peak (half price); a small flat-rate table covers Claude routes. Chinese public holidays are not tracked, so a holiday request is priced as a normal weekday;
- a model outside the price table omits the cost lines and total instead of estimating.

The state file remembers the last billed `seq` per session, so resumes and re-archives only settle new events.

## Turn it off

Any one of these works; the first two are hot (no restart):

1. In `~/.dsh/profiles/desktop/cordis.patch.yml`, set the row's (`id: notchfax-receipt`) `config.enabled: false`. The plugin unloads and agents armed earlier refuse to print because the helper re-reads this file at firing time.
2. Delete the `- insert:` row for `notchfax-receipt` (same effect).
3. Delete `~/.dsh/plugins/dsh-notchfax-receipt/` after removing the row.

To turn it back on, restore `config.enabled: true`.

## Manual use

```sh
# show a receipt without printing or touching the watermark
/usr/bin/python3 ~/.dsh/plugins/dsh-notchfax-receipt/receipt.py \
  --session <session-id> --dry-run --no-state

# print it for real (still no watermark change)
/usr/bin/python3 ~/.dsh/plugins/dsh-notchfax-receipt/receipt.py \
  --session <session-id> --no-state
```

`--sample` adds a "样票 · 演示" marker; `--archive` labels an archive-driven run; `--bots-dir` adds a bot workspace to skip. `--hook` (what the plugin passes) keeps every failure in the log instead of stderr and exits 0.

## Updating the code

`dsh-hmr` watches `cordis.patch.yml` and hot-remounts the row, but Node caches the imported module per row: after editing the entry file, deploy the change under a new filename **and a new row id**, or restart the app. (For example `index.v2.js` under `id: notchfax-receipt-v2`; the plugin finds its row by the `notchfax-receipt` prefix.) A restart is always safe; the row is re-read from the patch file.
