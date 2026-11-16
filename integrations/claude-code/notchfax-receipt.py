#!/usr/bin/env python3
"""Claude Code SessionEnd hook: when a session ends, Notchfax prints what it cost as a receipt.

Follows the shared rules in ../README.md. Checked against Claude Code 2.1.325; the transcript
format is internal to Claude Code and can change between releases.

Install: put this file somewhere stable and add to ~/.claude/settings.json (hooks run with a
thin PATH, so give python3 by its full path)

    "hooks": {
      "SessionEnd": [
        {"hooks": [{"type": "command", "command": "/usr/bin/python3 /path/to/notchfax-receipt.py", "timeout": 5}]}
      ]
    }

The hook reads the SessionEnd input, forks a detached child and returns at once (Claude Code
gives SessionEnd hooks 1.5 seconds by default). The child waits a beat for the transcript to
catch up, adds up the session and prints. Errors go to ~/Library/Logs/Notchfax/claude-receipt.log.

Turn it off: remove the entry from settings.json, or start Claude Code with NOTCHFAX_RECEIPT=0.

By hand, for any session, ended or not (does not touch the books):

    notchfax-receipt.py --session <session id>             # 对账单, printed now
    notchfax-receipt.py --session <session id> --sample    # the same, labelled 样票
    notchfax-receipt.py --session <session id> --dry-run   # only show it in the terminal

Settings (environment variables):

    NOTCHFAX_RECEIPT              0 turns the hook off
    NOTCHFAX_RECEIPT_ENTRYPOINTS  which sessions get a receipt, by Claude Code entrypoint;
                                  comma-separated, "*" for all. Default: the interactive ones
                                  (cli, claude-desktop, claude-vscode, claude-jetbrains), so
                                  `claude -p` (sdk-cli) and SDK runs (sdk-ts, sdk-py) stay quiet.
    NOTCHFAX_RECEIPT_MIN_USD      skip receipts below this amount (default 0.01)
    NOTCHFAX_RECEIPT_CNY_RATE     also show the total in yuan at this rate, e.g. 7.1
    NOTCHFAX_BIN                  the Notchfax command (default: inside /Applications/Notchfax.app)

What gets counted: only what the session transcript records. Every assistant response with a
usage block, in the main transcript and in its subagents' transcripts, priced at Anthropic's
list API prices. A resumed session bills only what came after its last receipt. Entries a
forked session copied from its parent are left out. A model or mode with no list price is
listed with its tokens but no amount and is left out of the total.
"""

import argparse
import datetime as dt
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import time
import traceback

# Anthropic list prices in USD per million tokens: (input, output, cache read).
# Checked against https://platform.claude.com/docs/en/about-claude/pricing on 2026-11-16.
# Cache writes cost 1.25x input for the 5-minute cache and 2x input for the 1-hour cache.
# A model id must match exactly (after dropping a date suffix); nothing is inferred.
PRICES = {
    "claude-fable-5-2": (8.00, 40.00, 0.20),
    "claude-mythos-5-2": (8.00, 40.00, 0.20),
    "claude-fable-5-1": (10.00, 50.00, 0.25),
    "claude-mythos-5-1": (10.00, 50.00, 0.25),
    "claude-fable-5": (10.00, 50.00, 1.00),
    "claude-mythos-5": (10.00, 50.00, 1.00),
    "claude-opus-5-5": (4.00, 20.00, 0.20),
    "claude-opus-5": (5.00, 25.00, 0.50),
    "claude-opus-4-8": (5.00, 25.00, 0.50),
    "claude-opus-4-7": (5.00, 25.00, 0.50),
    "claude-opus-4-6": (5.00, 25.00, 0.50),
    "claude-opus-4-5": (5.00, 25.00, 0.50),
    "claude-opus-4-1": (15.00, 75.00, 1.50),
    "claude-opus-4": (15.00, 75.00, 1.50),
    "claude-sonnet-5-5": (2.00, 10.00, 0.10),
    "claude-sonnet-5": (2.00, 10.00, 0.20),
    "claude-sonnet-4-6": (3.00, 15.00, 0.30),
    "claude-sonnet-4-5": (3.00, 15.00, 0.30),
    "claude-sonnet-4": (3.00, 15.00, 0.30),
    "claude-haiku-5-5": (0.10, 0.50, 0.01),
    "claude-haiku-4-5": (1.00, 5.00, 0.10),
}
# Haiku 5.5 costs more once a request's prompt (input + cache reads + cache writes) passes 100K.
LONG_PROMPT = {"claude-haiku-5-5": (100_000, (0.50, 2.50, 0.05))}
# Fast mode list prices are 2x standard on the models that have it; cache multipliers stack.
FAST_MULTIPLIER = {
    "claude-fable-5-2": 2.0,
    "claude-mythos-5-2": 2.0,
    "claude-opus-5-5": 2.0,
    "claude-opus-5": 2.0,
    "claude-opus-4-8": 2.0,
}
# US-only inference (usage.inference_geo "us") costs 1.1x on every token category.
US_GEO_MULTIPLIER = 1.1
WEB_SEARCH_PER_REQUEST = 10.00 / 1000

DEFAULT_ENTRYPOINTS = "cli,claude-desktop,claude-vscode,claude-jetbrains"
DEFAULT_NOTCHFAX = "/Applications/Notchfax.app/Contents/MacOS/Notchfax"
STATE_PATH = os.path.expanduser("~/Library/Application Support/Notchfax/claude-receipts.json")
LOCK_PATH = STATE_PATH + ".lock"
LOG_PATH = os.path.expanduser("~/Library/Logs/Notchfax/claude-receipt.log")


# ---------------------------------------------------------------- reading the transcript

def normalize_model(model):
    """claude-sonnet-4-5-20250929, us.anthropic.claude-opus-4-8-v1:0, claude-opus-5-5[1m] -> bare id."""
    model = (model or "").lower()
    model = re.sub(r"\[.*?\]$", "", model)
    model = re.sub(r"^([a-z]+\.)*anthropic\.", "", model)
    model = re.sub(r"-v\d+(:\d+)?$", "", model)
    model = re.sub(r"[-@]\d{8}$", "", model)
    return model


def display_name(model):
    m = re.match(r"claude-([a-z]+)-(\d+)(?:-(\d))?$", model)
    if m:
        family, major, minor = m.groups()
        return "%s %s%s" % (family.capitalize(), major, "." + minor if minor else "")
    m = re.match(r"claude-(\d)(?:-(\d))?-([a-z]+)$", model)
    if m:
        major, minor, family = m.groups()
        return "%s %s%s" % (family.capitalize(), major, "." + minor if minor else "")
    return model or "未知模型"


def num(source, key):
    value = source.get(key) if isinstance(source, dict) else None
    return int(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else 0


def cache_writes(usage):
    """(5-minute, 1-hour) cache write tokens, or None when the TTL split is not recorded."""
    total = num(usage, "cache_creation_input_tokens")
    split = usage.get("cache_creation")
    if isinstance(split, dict):
        return num(split, "ephemeral_5m_input_tokens"), num(split, "ephemeral_1h_input_tokens")
    return (0, 0) if total == 0 else None


def rates_for(model, usage):
    """USD per token (input, output, cache read) for one request, or None if it has no list price."""
    base = PRICES.get(model)
    if base is None:
        return None
    writes = cache_writes(usage)
    prompt = num(usage, "input_tokens") + num(usage, "cache_read_input_tokens") + (
        sum(writes) if writes else num(usage, "cache_creation_input_tokens"))
    if model in LONG_PROMPT and prompt > LONG_PROMPT[model][0]:
        base = LONG_PROMPT[model][1]
    factor = 1.0
    speed = usage.get("speed")
    if speed == "fast":
        if model not in FAST_MULTIPLIER:
            return None
        factor *= FAST_MULTIPLIER[model]
    elif speed not in (None, "standard"):
        return None
    geo = usage.get("inference_geo")
    if geo == "us":
        factor *= US_GEO_MULTIPLIER
    elif geo not in (None, "", "global"):
        return None
    if usage.get("fallback_credit") is not None:
        # Credit repricing after a refusal fallback: the transcript does not say what was billed.
        return None
    return tuple(rate * factor / 1_000_000 for rate in base)


def billable_parts(model, usage):
    """[(model or None, usage)]: one per billed attempt. A response whose usage.iterations holds
    more than its one message (server-side compaction, refusal fallbacks) is billed per iteration."""
    iterations = usage.get("iterations")
    if not isinstance(iterations, list) or not iterations:
        return [(model, usage)]
    if len(iterations) == 1 and isinstance(iterations[0], dict) and iterations[0].get("type") in (None, "message"):
        return [(model, usage)]
    parts = []
    for item in iterations:
        if not isinstance(item, dict):
            continue
        if item.get("model"):
            item_model = normalize_model(item["model"])
        elif item.get("type") in (None, "message", "compaction"):
            item_model = model
        else:
            item_model = None  # cannot tell which model ran it
        merged = dict(item)
        for key in ("speed", "inference_geo", "fallback_credit"):
            merged.setdefault(key, usage.get(key))
        merged["server_tool_use"] = usage.get("server_tool_use") if not parts else None
        parts.append((item_model, merged))
    return parts or [(model, usage)]


class Bucket(object):
    def __init__(self):
        self.input = 0
        self.output = 0
        self.cache_read = 0
        self.cache_write = 0
        self.web_searches = 0
        self.cost = {"input": 0.0, "output": 0.0, "cache_read": 0.0, "cache_write": 0.0, "web_search": 0.0}
        self.priced = True

    @property
    def total(self):
        return sum(self.cost.values())

    def add(self, rates, usage):
        uncached = num(usage, "input_tokens")
        output = num(usage, "output_tokens")
        read = num(usage, "cache_read_input_tokens")
        writes = cache_writes(usage)
        searches = num(usage.get("server_tool_use") or {}, "web_search_requests")
        self.input += uncached
        self.output += output
        self.cache_read += read
        self.cache_write += sum(writes) if writes else num(usage, "cache_creation_input_tokens")
        self.web_searches += searches
        if rates is None or writes is None:
            self.priced = False
            return
        rate_in, rate_out, rate_read = rates
        self.cost["input"] += uncached * rate_in
        self.cost["output"] += output * rate_out
        self.cost["cache_read"] += read * rate_read
        self.cost["cache_write"] += writes[0] * rate_in * 1.25 + writes[1] * rate_in * 2.0
        self.cost["web_search"] += searches * WEB_SEARCH_PER_REQUEST


class Summary(object):
    def __init__(self):
        self.models = {}  # bucket name -> Bucket
        self.requests = 0
        self.prompts = 0
        self.first = None  # first entry billed this time
        self.last = None
        self.latest = None  # last entry of the session seen at all
        self.entrypoint = None
        self.cwd = None

    @property
    def total(self):
        return sum(b.total for b in self.models.values() if b.priced)

    @property
    def unpriced(self):
        return [name for name, b in self.models.items() if not b.priced]


def parse_time(value):
    if not isinstance(value, str):
        return None
    try:
        when = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return when if when.tzinfo else when.replace(tzinfo=dt.timezone.utc)


def is_prompt(entry):
    """A message a person typed, as opposed to tool results and injected context."""
    if entry.get("isMeta") or entry.get("isSidechain") or entry.get("isCompactSummary"):
        return False
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return False
        text = " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    else:
        return False
    text = text.strip()
    return bool(text) and not text.startswith(("<command-", "<local-command", "Caveat:"))


def read_transcript(path, session_id, since, summary, seen, main):
    """Add the entries of one transcript file that belong to `session_id` and come after `since`."""
    try:
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with handle:
        for raw in handle:
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            # A forked session starts with a copy of its parent's history; that was billed there.
            if entry.get("forkedFrom") or entry.get("sessionId") not in (None, session_id):
                continue
            when = parse_time(entry.get("timestamp"))
            if when and (summary.latest is None or when > summary.latest):
                summary.latest = when
            fresh = since is None or (when is not None and when > since)
            kind = entry.get("type")
            if main:
                if entry.get("entrypoint"):
                    summary.entrypoint = entry["entrypoint"]
                if entry.get("cwd"):
                    summary.cwd = entry["cwd"]
                if fresh and when:
                    summary.first = min(summary.first, when) if summary.first else when
                    summary.last = max(summary.last, when) if summary.last else when
                if fresh and kind == "user" and is_prompt(entry):
                    summary.prompts += 1
            if kind != "assistant":
                continue
            message = entry.get("message") or {}
            usage = message.get("usage")
            model = normalize_model(message.get("model"))
            if not isinstance(usage, dict) or not model or model == "<synthetic>":
                continue
            # One API response is written as several entries that repeat its usage.
            key = (message.get("id") or entry.get("uuid"), entry.get("requestId"))
            if key in seen:
                continue
            seen.add(key)
            if not fresh:
                continue
            summary.requests += 1
            for part_model, part in billable_parts(model, usage):
                rates = rates_for(part_model, part) if part_model else None
                name = display_name(part_model or model)
                if part.get("speed") == "fast":
                    name += " 快速"
                summary.models.setdefault(name, Bucket()).add(rates, part)


def summarize(transcript, session_id, since):
    summary = Summary()
    seen = set()
    read_transcript(transcript, session_id, since, summary, seen, main=True)
    for path in sorted(glob.glob(os.path.join(os.path.splitext(transcript)[0], "subagents", "*.jsonl"))):
        read_transcript(path, session_id, since, summary, seen, main=False)
    return summary


# ---------------------------------------------------------------- the receipt

def money(value):
    if 0 < value < 0.005:
        return "<$0.01"
    return "$%.2f" % value


def tokens(count):
    if count < 10_000:
        return "{:,}".format(count)
    if count < 100_000_000:
        text = "%.1f" % (count / 10_000.0)
        return (text[:-2] if text.endswith(".0") else text) + "万"
    text = "%.2f" % (count / 100_000_000.0)
    return text.rstrip("0").rstrip(".") + "亿"


def duration(seconds):
    seconds = int(max(0, seconds))
    if seconds < 60:
        return "%d 秒" % seconds
    minutes = seconds // 60
    if minutes < 60:
        return "%d 分" % minutes
    hours, minutes = divmod(minutes, 60)
    return "%d 小时 %d 分" % (hours, minutes) if minutes else "%d 小时" % hours


def clip(text, limit):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def render(summary, session_id, cwd, resumed, kind):
    """`kind`: 会话小票 at the end of a session, 对账单 or 样票 for one asked for by hand."""
    local = lambda t: t.astimezone().strftime("%m-%d %H:%M")
    title = kind + (" · 续" if resumed and kind == "会话小票" else "")
    lines = ["# CLAUDE CODE", "^ > %s No.%s" % (title, (session_id or "")[:8].upper()), "---"]
    project = os.path.basename((cwd or summary.cwd or "").rstrip("/"))
    if project:
        lines.append("项目\t%s" % clip(project, 18))
    if summary.first and summary.last:
        lines.append("开始\t%s" % local(summary.first))
        lines.append("%s\t%s" % ("结束" if kind == "会话小票" else "截至", local(summary.last)))
        lines.append("用时\t%s" % duration((summary.last - summary.first).total_seconds()))
    lines.append("对话\t%d 问 · %d 次调用" % (summary.prompts, summary.requests))
    lines.append("---")

    order = sorted(summary.models.items(), key=lambda item: (not item[1].priced, -item[1].total, item[0]))
    for name, bucket in order:
        name = clip(name, 22)
        if bucket.priced:
            lines.append("## %s\t%s" % (name, money(bucket.total)))
        else:
            lines.append("## %s" % name)
        rows = [
            ("输入", bucket.input, "input", True),
            ("输出", bucket.output, "output", True),
            ("缓存写", bucket.cache_write, "cache_write", False),
            ("缓存读", bucket.cache_read, "cache_read", False),
        ]
        for label, count, cost_key, always in rows:
            if count or always:
                if bucket.priced:
                    lines.append("> %s %s\t%s" % (label, tokens(count), money(bucket.cost[cost_key])))
                else:
                    lines.append("> %s %s" % (label, tokens(count)))
        if bucket.web_searches:
            if bucket.priced:
                lines.append("> 网络搜索 %d 次\t%s" % (bucket.web_searches, money(bucket.cost["web_search"])))
            else:
                lines.append("> 网络搜索 %d 次" % bucket.web_searches)
    if summary.models:
        lines.append("---")

    total = summary.total
    lines.append("# 合计\t%s" % money(total))
    rate = os.environ.get("NOTCHFAX_RECEIPT_CNY_RATE")
    if rate:
        try:
            lines.append("^ > 约合 ¥%.2f" % (total * float(rate)))
        except ValueError:
            pass
    lines.append("^ > 按官方 API 标价估算")
    if resumed:
        lines.append("^ > 续接会话，只计本次新增")
    if summary.unpriced:
        lines.append("^ > %s 不在价目表上，未计入" % "、".join(clip(n, 22) for n in summary.unpriced))
    lines.append("===")
    lines.append("^ > 谢谢惠顾 · 欢迎再来")
    return "\n".join(lines)


# ---------------------------------------------------------------- state, sending, logging

def load_state():
    try:
        with open(STATE_PATH, encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state):
    # Keep the most recent few hundred sessions.
    if len(state) > 500:
        keep = sorted(state.items(), key=lambda item: item[1].get("at", 0))[-400:]
        state = dict(keep)
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    temp = STATE_PATH + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        json.dump(state, handle, ensure_ascii=False, indent=1)
    os.replace(temp, STATE_PATH)


def billed_up_to(state, session_id):
    return parse_time((state.get(session_id) or {}).get("upto"))


def log(message):
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > 512 * 1024:
            os.replace(LOG_PATH, LOG_PATH + ".1")
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write("%s %s\n" % (dt.datetime.now().isoformat(timespec="seconds"), message))
    except OSError:
        pass


def wanted(entrypoint):
    allowed = os.environ.get("NOTCHFAX_RECEIPT_ENTRYPOINTS", DEFAULT_ENTRYPOINTS)
    names = {name.strip() for name in allowed.split(",") if name.strip()}
    return "*" in names or (entrypoint or "") in names


def send(text, name):
    """Print on Notchfax; None on success, else what went wrong."""
    notchfax = os.environ.get("NOTCHFAX_BIN") or DEFAULT_NOTCHFAX
    if not os.access(notchfax, os.X_OK):
        return "Notchfax command not found at %s" % notchfax
    try:
        result = subprocess.run(
            [notchfax, "print", "--quiet", "--name", name],
            input=text.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as error:
        return "notchfax print could not run: %s" % error
    if result.returncode != 0:
        return "notchfax print failed (%d): %s" % (result.returncode, result.stderr.decode("utf-8", "replace").strip())
    return None


def settle(hook, dry_run=False):
    """The session ended: print what it added since its last receipt and record it as billed.
    `dry_run`: show the receipt and the decision in the terminal; print nothing, record nothing."""
    note = (lambda message: print("[hook] " + message)) if dry_run else log
    sid = hook.get("session_id") or ""
    transcript = hook.get("transcript_path")
    if os.environ.get("NOTCHFAX_RECEIPT", "1").strip().lower() in ("0", "off", "false", "no"):
        return note("%s: skipped, NOTCHFAX_RECEIPT is off" % sid[:8])
    if not transcript or not os.path.exists(transcript):
        return note("%s: no transcript at %r" % (sid[:8], transcript))
    sid = sid or os.path.splitext(os.path.basename(transcript))[0]
    os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
    with open(LOCK_PATH, "a") as lock:
        # Several sessions can end at once; the books are read, printed and written under one lock.
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load_state()
        since = billed_up_to(state, sid)
        summary = summarize(transcript, sid, since)
        entrypoint = os.environ.get("CLAUDE_CODE_ENTRYPOINT") or summary.entrypoint
        if not wanted(entrypoint):
            return note("%s: skipped, entrypoint %s is not an interactive session" % (sid[:8], entrypoint))
        minimum = float(os.environ.get("NOTCHFAX_RECEIPT_MIN_USD", "0.01") or 0)
        if summary.requests == 0 or (summary.total < minimum and not summary.unpriced):
            return note("%s: skipped, %d new requests, %s" % (sid[:8], summary.requests, money(summary.total)))
        text = render(summary, sid, hook.get("cwd"), since is not None, "会话小票")
        if dry_run:
            print(text)
            return note("%s: would print and bill up to %s" % (sid[:8], summary.latest))
        error = send(text, "Claude Code 小票 %s" % sid[:8])
        if error:
            return log("%s: %s" % (sid[:8], error))
        previous = float((state.get(sid) or {}).get("total", 0.0))
        state[sid] = {
            "upto": summary.latest.isoformat() if summary.latest else None,
            "total": round(previous + summary.total, 6),
            "at": int(time.time()),
        }
        save_state(state)
        log("%s: printed, %d requests, %s" % (sid[:8], summary.requests, money(summary.total)))


def find_transcript(session_id):
    pattern = os.path.join(os.path.expanduser("~/.claude/projects"), "*", session_id + ".jsonl")
    matches = sorted(glob.glob(pattern), key=os.path.getmtime)
    return matches[-1] if matches else None


def by_hand(args):
    transcript = os.path.expanduser(args.transcript) if args.transcript else find_transcript(args.session)
    if not transcript or not os.path.exists(transcript):
        sys.stderr.write("找不到会话 %s 的记录。\n" % (args.session or args.transcript))
        return 1
    sid = args.session or os.path.splitext(os.path.basename(transcript))[0]
    since = billed_up_to(load_state(), sid)
    summary = summarize(transcript, sid, since)
    text = render(summary, sid, None, since is not None, "样票" if args.sample else "对账单")
    print(text)
    if args.dry_run:
        return 0
    error = send(text, "Claude Code %s %s" % ("样票" if args.sample else "对账单", sid[:8]))
    if error:
        sys.stderr.write(error + "\n")
        return 1
    print("\n已送去 Notchfax 打印。")
    return 0


def detach():
    """Fork; the parent returns to Claude Code at once, the child carries on in its own session."""
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)


def main():
    parser = argparse.ArgumentParser(
        description="Print a Claude Code session's cost on Notchfax. With no arguments it reads "
        "SessionEnd hook input on stdin; with --session or --transcript it prints the bill so far, now."
    )
    parser.add_argument("--session", help="a session id; its transcript is looked up under ~/.claude/projects")
    parser.add_argument("--transcript", help="a session transcript (.jsonl)")
    parser.add_argument("--dry-run", action="store_true", help="only write the receipt to stdout")
    parser.add_argument("--sample", action="store_true", help="label a receipt asked for by hand 样票")
    parser.add_argument("--foreground", action="store_true", help="hook mode: do not detach (for debugging)")
    args = parser.parse_args()

    if args.session or args.transcript:
        return by_hand(args)
    try:
        hook = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(hook, dict):
        return 0
    if args.dry_run:
        settle(hook, dry_run=True)
        return 0
    if not args.foreground:
        detach()
        # The last turn may still be on its way to the transcript.
        time.sleep(1.5)
    try:
        settle(hook)
    except Exception:
        log(traceback.format_exc().strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
