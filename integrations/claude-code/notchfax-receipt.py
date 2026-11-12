#!/usr/bin/env python3
"""Claude Code SessionEnd hook: when a session ends, Notchfax prints what it cost as a receipt.

Install: copy this file somewhere stable and add to ~/.claude/settings.json

    "hooks": {
      "SessionEnd": [
        {"hooks": [{"type": "command", "command": "python3 /path/to/notchfax-receipt.py", "timeout": 5}]}
      ]
    }

It needs the `notchfax` command (Notchfax menu: 安装命令行工具…). The hook returns at once
and does the work in a detached process, because Claude Code gives SessionEnd hooks only a
moment and the transcript can lag behind by a beat.

Try it by hand on any transcript:

    notchfax-receipt.py --transcript ~/.claude/projects/<project>/<session>.jsonl --dry-run

Settings (environment variables):

    NOTCHFAX_RECEIPT_ENTRYPOINTS  which sessions get a receipt, by Claude Code entrypoint;
                                  comma-separated, "*" for all. Default: interactive ones
                                  (cli, claude-desktop, claude-vscode, claude-jetbrains),
                                  so `claude -p` and SDK-driven automation stay quiet.
    NOTCHFAX_RECEIPT_MIN_USD      skip receipts below this amount (default 0.01)
    NOTCHFAX_RECEIPT_CNY_RATE     also show the total in yuan at this rate, e.g. 7.1
    NOTCHFAX_BIN                  path to the notchfax command, if it is not on PATH

Costs are estimated from the token counts in the transcript at Anthropic's list API prices
(what the same tokens would cost on the API; a subscription is billed differently).
"""

import argparse
import datetime as dt
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
import traceback

# USD per million tokens: (input, output, cache read). Cache writes cost 1.25x input for
# the 5-minute cache and 2x input for the 1-hour cache. Longest prefix wins.
PRICES = [
    ("claude-fable-5-2", (8.00, 40.00, 0.20)),
    ("claude-mythos-5-2", (8.00, 40.00, 0.20)),
    ("claude-fable-5-1", (10.00, 50.00, 0.25)),
    ("claude-mythos-5-1", (10.00, 50.00, 0.25)),
    ("claude-fable-5", (10.00, 50.00, 1.00)),
    ("claude-mythos-5", (10.00, 50.00, 1.00)),
    ("claude-mythos-preview", (10.00, 50.00, 1.00)),
    ("claude-opus-5-5", (4.00, 20.00, 0.20)),
    ("claude-opus-5", (5.00, 25.00, 0.50)),
    ("claude-opus-4-8", (5.00, 25.00, 0.50)),
    ("claude-opus-4-7", (5.00, 25.00, 0.50)),
    ("claude-opus-4-6", (5.00, 25.00, 0.50)),
    ("claude-opus-4-5", (5.00, 25.00, 0.50)),
    ("claude-opus-4-1", (15.00, 75.00, 1.50)),
    ("claude-opus-4", (15.00, 75.00, 1.50)),
    ("claude-3-opus", (15.00, 75.00, 1.50)),
    ("claude-sonnet-5-5", (2.00, 10.00, 0.10)),
    ("claude-sonnet-5", (2.00, 10.00, 0.20)),
    ("claude-sonnet-4", (3.00, 15.00, 0.30)),
    ("claude-3-7-sonnet", (3.00, 15.00, 0.30)),
    ("claude-3-5-sonnet", (3.00, 15.00, 0.30)),
    # Haiku 5.5's cache-read rate is assumed to be the usual 0.1x of input.
    ("claude-haiku-5-5", (0.10, 0.50, 0.01)),
    ("claude-haiku-4-5", (1.00, 5.00, 0.10)),
    ("claude-3-5-haiku", (0.80, 4.00, 0.08)),
    ("claude-3-haiku", (0.25, 1.25, 0.03)),
]
# Haiku 5.5 costs more once a prompt passes 100K tokens.
LONG_PROMPT = {"claude-haiku-5-5": (100_000, (0.50, 2.50, 0.05))}
# Fast mode multiplies every rate.
FAST_MULTIPLIER = {"claude-opus-4-6": 6.0}
DEFAULT_FAST_MULTIPLIER = 2.0
WEB_SEARCH_PER_REQUEST = 10.00 / 1000

DEFAULT_ENTRYPOINTS = "cli,claude-desktop,claude-vscode,claude-jetbrains"
STATE_PATH = os.path.expanduser("~/Library/Application Support/Notchfax/claude-receipts.json")
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


def price_for(model):
    for prefix, rates in PRICES:
        if model == prefix or model.startswith(prefix + "-"):
            return prefix, rates
    return None, None


def display_name(model):
    m = re.match(r"claude-([a-z]+)-(\d+)(?:-(\d))?(?:-|$)", model)
    if m:
        family, major, minor = m.groups()
        return "%s %s%s" % (family.capitalize(), major, "." + minor if minor else "")
    m = re.match(r"claude-(\d)(?:-(\d))?-([a-z]+)", model)
    if m:
        major, minor, family = m.groups()
        return "%s %s%s" % (family.capitalize(), major, "." + minor if minor else "")
    return model or "未知模型"


class Bucket(object):
    def __init__(self):
        self.input = 0
        self.output = 0
        self.cache_read = 0
        self.cache_write_5m = 0
        self.cache_write_1h = 0
        self.web_searches = 0
        self.cost = {"input": 0.0, "output": 0.0, "cache_read": 0.0, "cache_write": 0.0, "web_search": 0.0}
        self.priced = True

    @property
    def total(self):
        return sum(self.cost.values())

    def add(self, model, usage):
        def n(key, source=usage):
            value = source.get(key) if isinstance(source, dict) else None
            return int(value) if isinstance(value, (int, float)) else 0

        uncached = n("input_tokens")
        output = n("output_tokens")
        read = n("cache_read_input_tokens")
        creation = usage.get("cache_creation") if isinstance(usage.get("cache_creation"), dict) else {}
        write_5m = n("ephemeral_5m_input_tokens", creation)
        write_1h = n("ephemeral_1h_input_tokens", creation)
        if not creation:
            write_5m = n("cache_creation_input_tokens")
        searches = n("web_search_requests", usage.get("server_tool_use") or {})

        self.input += uncached
        self.output += output
        self.cache_read += read
        self.cache_write_5m += write_5m
        self.cache_write_1h += write_1h
        self.web_searches += searches

        prefix, rates = price_for(model)
        if prefix is None or rates is None:
            self.priced = False
            return
        if prefix in LONG_PROMPT:
            threshold, long_rates = LONG_PROMPT[prefix]
            if uncached + read + write_5m + write_1h > threshold:
                rates = long_rates
        factor = 1.0
        if usage.get("speed") == "fast":
            factor = FAST_MULTIPLIER.get(prefix, DEFAULT_FAST_MULTIPLIER)
        rate_in, rate_out, rate_read = (r * factor / 1_000_000 for r in rates)
        self.cost["input"] += uncached * rate_in
        self.cost["output"] += output * rate_out
        self.cost["cache_read"] += read * rate_read
        self.cost["cache_write"] += write_5m * rate_in * 1.25 + write_1h * rate_in * 2.0
        self.cost["web_search"] += searches * WEB_SEARCH_PER_REQUEST


class Summary(object):
    def __init__(self):
        self.models = {}  # display name -> Bucket
        self.requests = 0
        self.prompts = 0
        self.tool_calls = 0
        self.subagents = 0
        self.first = None
        self.last = None
        self.title = None
        self.entrypoint = None
        self.cwd = None

    @property
    def total(self):
        return sum(b.total for b in self.models.values())


def parse_time(value):
    if not isinstance(value, str):
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


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


def read_transcript(path, summary, seen, main):
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
            kind = entry.get("type")
            if main:
                when = parse_time(entry.get("timestamp"))
                if when:
                    summary.first = min(summary.first, when) if summary.first else when
                    summary.last = max(summary.last, when) if summary.last else when
                if kind == "custom-title" and entry.get("customTitle"):
                    summary.title = entry["customTitle"]
                elif kind == "agent-name" and entry.get("agentName") and not summary.title:
                    summary.title = entry["agentName"]
                elif kind == "summary" and entry.get("summary") and not summary.title:
                    summary.title = entry["summary"]
                if entry.get("entrypoint"):
                    summary.entrypoint = entry["entrypoint"]
                if entry.get("cwd"):
                    summary.cwd = entry["cwd"]
                if kind == "user" and is_prompt(entry):
                    summary.prompts += 1
            if kind != "assistant":
                continue
            message = entry.get("message") or {}
            for block in message.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    summary.tool_calls += 1
            usage = message.get("usage")
            model = normalize_model(message.get("model"))
            if not isinstance(usage, dict) or not model or model == "<synthetic>":
                continue
            # One API response is written as several entries that repeat its usage.
            key = (message.get("id") or entry.get("uuid"), entry.get("requestId"))
            if key in seen:
                continue
            seen.add(key)
            summary.requests += 1
            summary.models.setdefault(display_name(model), Bucket()).add(model, usage)


def summarize(transcript):
    summary = Summary()
    seen = set()
    read_transcript(transcript, summary, seen, main=True)
    subagents = sorted(glob.glob(os.path.join(os.path.splitext(transcript)[0], "subagents", "*.jsonl")))
    summary.subagents = len(subagents)
    for path in subagents:
        read_transcript(path, summary, seen, main=False)
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


def render(summary, session_id, cwd, already_paid):
    local = lambda t: t.astimezone().strftime("%m-%d %H:%M")
    lines = ["# CLAUDE CODE", "^ > 会话小票 No.%s" % (session_id or "")[:8].upper(), "---"]
    project = os.path.basename((cwd or summary.cwd or "").rstrip("/"))
    if project:
        lines.append("项目\t%s" % clip(project, 18))
    if summary.title:
        lines.append("标题\t%s" % clip(summary.title, 24))
    if summary.first and summary.last:
        lines.append("开始\t%s" % local(summary.first))
        lines.append("结束\t%s" % local(summary.last))
        lines.append("用时\t%s" % duration((summary.last - summary.first).total_seconds()))
    lines.append("对话\t%d 问 · %d 次调用" % (summary.prompts, summary.requests))
    if summary.tool_calls:
        lines.append("工具\t%d 次" % summary.tool_calls)
    if summary.subagents:
        lines.append("子代理\t%d 个" % summary.subagents)
    lines.append("---")

    unpriced = []
    for name, bucket in sorted(summary.models.items(), key=lambda item: -item[1].total):
        if not bucket.priced:
            unpriced.append(name)
            lines.append("## %s\t未知价格" % name)
            lines.append("> 输入 %s · 输出 %s" % (tokens(bucket.input), tokens(bucket.output)))
            continue
        lines.append("## %s\t%s" % (name, money(bucket.total)))
        if bucket.total < 0.10:
            # Itemising cents only adds lines of <$0.01.
            all_tokens = bucket.input + bucket.output + bucket.cache_read + bucket.cache_write_5m + bucket.cache_write_1h
            lines.append("> 共 %s tokens" % tokens(all_tokens))
            continue
        rows = [
            ("输入", bucket.input, bucket.cost["input"]),
            ("输出", bucket.output, bucket.cost["output"]),
            ("缓存写", bucket.cache_write_5m + bucket.cache_write_1h, bucket.cost["cache_write"]),
            ("缓存读", bucket.cache_read, bucket.cost["cache_read"]),
        ]
        for label, count, cost in rows:
            if count:
                lines.append("> %s %s\t%s" % (label, tokens(count), money(cost)))
        if bucket.web_searches:
            lines.append("> 网络搜索 %d 次\t%s" % (bucket.web_searches, money(bucket.cost["web_search"])))
    lines.append("---")

    total = summary.total
    due = total - already_paid
    if already_paid > 0:
        lines.append("累计\t%s" % money(total))
        lines.append("此前已结\t-%s" % money(already_paid))
        lines.append("# 本次\t%s" % money(due))
    else:
        lines.append("# 合计\t%s" % money(total))
    rate = os.environ.get("NOTCHFAX_RECEIPT_CNY_RATE")
    if rate:
        try:
            lines.append("^ > 约合 ¥%.2f" % (due * float(rate)))
        except ValueError:
            pass
    lines.append("^ > 按 API 标价估算")
    if unpriced:
        lines.append("^ > %s 不在价目表上，未计入" % "、".join(unpriced))
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


def find_notchfax():
    explicit = os.environ.get("NOTCHFAX_BIN")
    if explicit:
        return explicit
    extra = [os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin"]
    path = os.pathsep.join([os.environ.get("PATH", "")] + extra)
    return shutil.which("notchfax", path=path)


def log(message):
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write("%s %s\n" % (dt.datetime.now().isoformat(timespec="seconds"), message))
    except OSError:
        pass


def wanted(entrypoint):
    allowed = os.environ.get("NOTCHFAX_RECEIPT_ENTRYPOINTS", DEFAULT_ENTRYPOINTS)
    names = {name.strip() for name in allowed.split(",") if name.strip()}
    return "*" in names or (entrypoint or "") in names


def run(hook, dry_run):
    transcript = hook.get("transcript_path")
    if not transcript or not os.path.exists(transcript):
        log("no transcript: %r" % transcript)
        return 0
    session_id = hook.get("session_id") or os.path.splitext(os.path.basename(transcript))[0]
    summary = summarize(transcript)
    entrypoint = os.environ.get("CLAUDE_CODE_ENTRYPOINT") or summary.entrypoint
    if not dry_run and not wanted(entrypoint):
        return 0

    state = load_state()
    paid = float((state.get(session_id) or {}).get("total", 0.0))
    due = summary.total - paid
    minimum = float(os.environ.get("NOTCHFAX_RECEIPT_MIN_USD", "0.01") or 0)
    text = render(summary, session_id, hook.get("cwd"), paid)
    if dry_run:
        print(text)
        return 0
    if summary.requests == 0 or due < minimum:
        return 0

    notchfax = find_notchfax()
    if not notchfax:
        log("notchfax command not found; install it from the Notchfax menu (安装命令行工具…)")
        return 0
    name = "Claude Code 小票 %s" % (session_id or "")[:8]
    result = subprocess.run(
        [notchfax, "print", "--quiet", "--name", name],
        input=text.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
    )
    if result.returncode != 0:
        log("notchfax print failed (%d): %s" % (result.returncode, result.stderr.decode("utf-8", "replace").strip()))
        return 0
    state[session_id] = {"total": round(summary.total, 6), "at": int(time.time())}
    save_state(state)
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
    parser = argparse.ArgumentParser(description="Print a Claude Code session's cost on Notchfax.")
    parser.add_argument("--transcript", help="a session transcript (.jsonl) instead of hook input on stdin")
    parser.add_argument("--dry-run", action="store_true", help="write the receipt to stdout instead of printing it")
    parser.add_argument("--foreground", action="store_true", help="do not detach (for debugging)")
    args = parser.parse_args()

    if args.transcript:
        hook = {"transcript_path": os.path.expanduser(args.transcript)}
    else:
        try:
            hook = json.load(sys.stdin)
        except ValueError:
            return 0
        if not isinstance(hook, dict):
            return 0

    if not args.dry_run and not args.foreground:
        detach()
        # The last turn may still be on its way to the transcript.
        time.sleep(1.5)
    try:
        return run(hook, args.dry_run)
    except Exception:
        log(traceback.format_exc().strip())
        return 0


if __name__ == "__main__":
    sys.exit(main())
