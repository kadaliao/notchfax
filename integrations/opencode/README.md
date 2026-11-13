# Notchfax receipts for OpenCode

When an interactive [OpenCode](https://opencode.ai) TUI exits, Notchfax prints a receipt for each top-level session that ran in it: project, title, start/end time, duration, prompts and calls, one section per model with its tokens and cost, and the total.

## Install

```sh
mkdir -p ~/.config/opencode/plugins/notchfax-receipt
cp index.ts notchfax_receipt.py notchfax_watch.py ~/.config/opencode/plugins/notchfax-receipt/
```

Then add the plugin to `~/.config/opencode/opencode.json` with its absolute path:

```json
"plugin": ["/Users/<you>/.config/opencode/plugins/notchfax-receipt/index.ts"]
```

It takes effect in the next OpenCode TUI. Try it on a session without printing:

```sh
python3 ~/.config/opencode/plugins/notchfax-receipt/notchfax_receipt.py --session <ses_…> --dry-run
```

That prints a 对账单 of the whole session so far and settles nothing. Drop `--dry-run` to print it.

## How it works

| File | Role |
|---|---|
| `index.ts` | The plugin. It records the top-level sessions this TUI touched (`session.*` and assistant `message.updated` events) into `~/Library/Application Support/Notchfax/active-<pid>-….json`, and starts the watcher. |
| `notchfax_watch.py` | Detached; polls the OpenCode process and, once it is gone, runs the receipt script. Polling instead of a dispose hook means a receipt still prints when the TUI is killed by a signal. |
| `notchfax_receipt.py` | Reads the sessions from OpenCode's own database (`~/.local/share/opencode/opencode.db`, read-only) and prints. |

Costs are the ones OpenCode records on every assistant message (the same numbers its TUI shows), grouped by model; their sum equals the session's total. OpenCode stores one cost per message, not per token kind, so the token lines carry counts only. A model with tokens but no recorded cost is listed without a price.

Only interactive TUIs print: `opencode run`, `serve`, `generate` and `CI` do not; child sessions (`parent_id`) are skipped. After a receipt, `~/Library/Application Support/Notchfax/opencode-receipts.json` remembers how far each session was billed, so a resumed session bills only what is new.

Failures go to `~/Library/Logs/Notchfax/opencode-receipt.log`. The receipt is printed by `/Applications/Notchfax.app/Contents/MacOS/Notchfax` (override with `NOTCHFAX_BIN`).

## Turn it off

Set `NOTCHFAX_RECEIPT_DISABLED=1`, or remove the entry from `opencode.json`.
