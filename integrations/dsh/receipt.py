#!/usr/bin/env python3
"""DeepSeek Harness session-end receipt printed through Notchfax.

Part of the dsh-notchfax-receipt plugin (index.js next to this file): the plugin
spawns this script detached when a session is archived or torn down at quit, so
the hook returns at once and the receipt is printed in the background.

Data comes only from the durable DSH session log
(~/.dsh/sessions/<cwd-slug>/<session-id>/session*.jsonl[.zstd]):
project directory, first/last event time, model, and provider-reported token
usage. Money is token usage priced at DeepSeek's published list prices
(https://api-docs.deepseek.com/quick_start/pricing/), split by peak/off-peak
because those rates differ. The price tables below are a snapshot; check them
against the vendor's page when models or prices change. Nothing is estimated:
a line with no data in the log is omitted.

A session that is resumed and ends again is billed once for the first segment
(the state file remembers the last billed sequence number), then only for the
events appended after it.

Exit status is always 0 in hook mode; failures go to
~/Library/Logs/Notchfax/dsh-receipt.log.
"""

import argparse
import datetime as dt
import glob
import json
import os
import subprocess
import sys
import time
import traceback

# Full path on purpose: the hook runs with a thin PATH. NOTCHFAX_BIN overrides it.
NOTCHFAX = os.environ.get("NOTCHFAX_BIN") or "/Applications/Notchfax.app/Contents/MacOS/Notchfax"
HOME = os.path.expanduser("~")
STATE_PATH = os.path.join(HOME, "Library", "Application Support", "Notchfax", "dsh-receipts.json")
LOG_PATH = os.path.join(HOME, "Library", "Logs", "Notchfax", "dsh-receipt.log")
LOCK_PATH = os.path.join(HOME, "Library", "Application Support", "Notchfax", "dsh-receipts.lock")
SESSIONS_ROOT = os.path.join(HOME, ".dsh", "sessions")
ZSTD_CANDIDATES = ("/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd")

# USD per 1M tokens. DeepSeek publishes a peak and an off-peak rate:
# peak = 01:00-04:00 and 06:00-10:00 UTC, Monday-Friday, excluding Chinese
# public holidays; everything else is off-peak (half of peak).
# https://api-docs.deepseek.com/quick_start/pricing/
DEEPSEEK_RATES = {
    "deepseek-flash": {"cache_read": (0.003, 0.006), "input": (0.15, 0.30), "output": (0.60, 1.20)},
    "deepseek-v4-pro": {"cache_read": (0.022, 0.044), "input": (0.66, 1.32), "output": (1.98, 3.96)},
}
# Flat list prices (input, output, cache read) per 1M tokens, used when the
# session ran on a non-DeepSeek route through the same gateway.
FLAT_RATES = {
    "claude-opus-5-5": (4.00, 20.00, 0.20),
    "claude-fable-5-2": (8.00, 40.00, 0.20),
    "claude-fable-5-1": (10.00, 50.00, 0.25),
    "claude-mythos-5-2": (8.00, 40.00, 0.20),
    "claude-sonnet-5-5": (2.00, 10.00, 0.10),
    "claude-sonnet-5": (2.00, 10.00, 0.20),
    "claude-sonnet-4": (3.00, 15.00, 0.30),
    "claude-haiku-5-5": (0.10, 0.50, 0.01),
    "claude-haiku-4-5": (1.00, 5.00, 0.10),
}
MODEL_DISPLAY = {
    "deepseek-flash": "DeepSeek-V4.1-Flash",
    "deepseek-v4-flash": "DeepSeek-V4.1-Flash",
    "deepseek-v4-pro": "DeepSeek-V4-Pro",
    "claude-opus-5-5": "Claude Opus 5.5",
    "claude-fable-5-2": "Claude Fable 5.2",
    "claude-fable-5-1": "Claude Fable 5.1",
    "claude-mythos-5-2": "Claude Mythos 5.2",
    "claude-sonnet-5-5": "Claude Sonnet 5.5",
    "claude-sonnet-5": "Claude Sonnet 5",
    "claude-sonnet-4": "Claude Sonnet 4",
    "claude-haiku-5-5": "Claude Haiku 5.5",
    "claude-haiku-4-5": "Claude Haiku 4.5",
}


# ---------------------------------------------------------------- logging

def log(message):
    try:
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write("%s %s\n" % (dt.datetime.now().isoformat(timespec="seconds"), message))
    except OSError:
        pass


# ---------------------------------------------------------------- state

def load_state():
    try:
        with open(STATE_PATH, encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state):
    if len(state) > 500:
        keep = sorted(state.items(), key=lambda item: item[1].get("at", 0))[-400:]
        state = dict(keep)
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    temp = STATE_PATH + ".tmp"
    with open(temp, "w", encoding="utf-8") as handle:
        json.dump(state, handle, ensure_ascii=False, indent=1)
    os.replace(temp, STATE_PATH)


class StateLock(object):
    """Serialize read-modify-write of the receipts state across helper processes."""

    def __init__(self):
        self.handle = None

    def __enter__(self):
        os.makedirs(os.path.dirname(LOCK_PATH), exist_ok=True)
        self.handle = open(LOCK_PATH, "a+")
        try:
            import fcntl
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX)
        except (ImportError, OSError):
            pass
        return self

    def __exit__(self, *exc):
        try:
            import fcntl
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        except (ImportError, OSError):
            pass
        try:
            self.handle.close()
        except OSError:
            pass
        return False


# ---------------------------------------------------------------- reading the session log

def find_session_log(session_id):
    if not session_id:
        return None
    pattern = os.path.join(SESSIONS_ROOT, "*", session_id, "session*.jsonl*")
    matches = [path for path in glob.glob(pattern) if os.path.isfile(path)]
    if not matches:
        # A resumed session directory keeps its id; the glob above is the layout.
        return None
    # Prefer the highest format generation (v4 over v3 over bare).
    def rank(path):
        name = os.path.basename(path)
        version = 0
        if name.startswith("session.v") and "." in name[9:]:
            head = name[len("session.v"):].split(".")[0]
            version = int(head) if head.isdigit() else 0
        return (version, os.path.getmtime(path))
    return max(matches, key=rank)


def zstd_binary():
    for candidate in ZSTD_CANDIDATES:
        if os.path.exists(candidate):
            return candidate
    return None


def read_events(path):
    if path.endswith(".zstd"):
        binary = zstd_binary()
        if binary is None:
            raise RuntimeError("no zstd binary found")
        result = subprocess.run([binary, "-dc", path], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=120)
        if result.returncode != 0:
            raise RuntimeError("zstd failed: %s" % result.stderr.decode("utf-8", "replace").strip())
        text = result.stdout.decode("utf-8", "replace")
    else:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    events = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return events


# ---------------------------------------------------------------- pricing

def normalize_model(value):
    model = (value or "").strip().lower()
    if "/" in model:
        model = model.rsplit("/", 1)[-1]
    return model


def rate_for(model):
    """Return ('deepseek', rates) for peak-aware DeepSeek routes, ('flat', (in,out,read)) otherwise."""
    bare = normalize_model(model)
    for key, rates in DEEPSEEK_RATES.items():
        if bare == key or bare.startswith(key + "-") or bare.startswith(key + "."):
            return "deepseek", rates
    for key, rates in FLAT_RATES.items():
        if bare == key or bare.startswith(key + "-") or bare.startswith(key + "."):
            return "flat", rates
    return None, None


def is_peak(when_ms):
    """Peak = 01:00-04:00 or 06:00-10:00 UTC, Monday-Friday (holidays not tracked)."""
    utc = dt.datetime.fromtimestamp(when_ms / 1000.0, tz=dt.timezone.utc)
    if utc.weekday() >= 5:
        return False
    return 1 <= utc.hour < 4 or 6 <= utc.hour < 10


def is_child_header(header):
    return bool(
        header.get("origin") == "subagent"
        or header.get("parentSession") is not None
        or (isinstance(header.get("delegationDepth"), int) and header["delegationDepth"] > 0)
    )


def in_bot_workspace(cwd, bots_dirs):
    if not cwd:
        return False
    target = os.path.realpath(cwd)
    for directory in bots_dirs or []:
        base = os.path.realpath(os.path.expanduser(directory))
        if target == base or target.startswith(base.rstrip("/") + "/"):
            return True
    return False


def display_model(model):
    bare = normalize_model(model)
    for key, name in MODEL_DISPLAY.items():
        if bare == key or bare.startswith(key + "-") or bare.startswith(key + "."):
            return name
    return bare or "未知模型"


# ---------------------------------------------------------------- summary

class Totals(object):
    def __init__(self):
        self.input = 0
        self.output = 0
        self.cache_read = 0
        self.cost_input = 0.0
        self.cost_output = 0.0
        self.cost_cache_read = 0.0
        self.models = []
        self.unpriced = set()
        self.peak_aware = False

    @property
    def total(self):
        return self.cost_input + self.cost_output + self.cost_cache_read

    def add(self, model, time_ms, usage):
        def count(key):
            value = usage.get(key)
            return int(value) if isinstance(value, (int, float)) and value > 0 else 0

        uncached = count("inputTokens")
        output = count("outputTokens")
        cache_read = count("cacheReadTokens")
        if not (uncached or output or cache_read):
            return

        self.input += uncached
        self.output += output
        self.cache_read += cache_read

        name = display_model(model)
        if name not in self.models:
            self.models.append(name)

        kind, rates = rate_for(model)
        if kind is None:
            self.unpriced.add(name)
            return
        if kind == "deepseek":
            self.peak_aware = True
            peak = is_peak(time_ms)
            index = 1 if peak else 0
            unit_cache, unit_input, unit_output = (rates["cache_read"][index],
                                                   rates["input"][index],
                                                   rates["output"][index])
        else:
            unit_input, unit_output, unit_cache = rates
        self.cost_input += uncached * unit_input / 1_000_000.0
        self.cost_output += output * unit_output / 1_000_000.0
        self.cost_cache_read += cache_read * unit_cache / 1_000_000.0


def summarize(events, billed_seq):
    header = events[0] if events and isinstance(events[0], dict) else {}
    header = header if header.get("type") == "session" else {}
    session_id = header.get("id") or ""
    cwd = header.get("cwd") or ""

    segment = [event for event in events if isinstance(event.get("seq"), int) and event["seq"] > billed_seq]
    if not segment:
        return None

    start_ms = header.get("createdAt") if billed_seq < 0 else segment[0].get("time")
    if not isinstance(start_ms, (int, float)):
        start_ms = segment[0].get("time")
    end_ms = None
    last_seq = billed_seq
    current_model = ""
    totals = Totals()
    requests = 0

    for event in events:
        if not isinstance(event.get("seq"), int):
            continue
        if event["seq"] <= billed_seq:
            # Still track the route that carried over from the already-billed prefix.
            current_model = route_of(event, current_model)
            continue
        last_seq = event["seq"]
        when = event.get("time")
        if isinstance(when, (int, float)):
            end_ms = when
        current_model = route_of(event, current_model)
        data = event.get("data") or {}
        usage = data.get("usage")
        if event.get("type") in ("assistant/message", "assistant/attempt") and isinstance(usage, dict):
            model = ((data.get("message") or {}).get("source") or {}).get("model") or current_model
            totals.add(model, when if isinstance(when, (int, float)) else 0, usage)
            requests += 1

    return {
        "session_id": session_id,
        "cwd": cwd,
        "start_ms": start_ms,
        "end_ms": end_ms if end_ms is not None else start_ms,
        "last_seq": last_seq,
        "requests": requests,
        "totals": totals,
    }


def route_of(event, fallback):
    """Track the effective route from request/context (or request/header.config)."""
    data = event.get("data") or {}
    if event.get("type") == "request/context" and data.get("model"):
        return data["model"]
    if event.get("type") == "request/header":
        config = (data.get("header") or {}).get("config") or {}
        if config.get("model"):
            return config["model"]
    return fallback


# ---------------------------------------------------------------- rendering

# Shared receipt format: see ../README.md.

def money(value):
    if 0 < value < 0.005:
        return "<$0.01"
    return "$%.2f" % max(0.0, value)


def tokens(count):
    count = int(max(0, count))
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
    if hours < 24:
        return "%d 小时 %d 分" % (hours, minutes) if minutes else "%d 小时" % hours
    days, hours = divmod(hours, 24)
    return "%d 天 %d 小时" % (days, hours) if hours else "%d 天" % days


def clip(text, limit):
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def local_time(ms):
    if not isinstance(ms, (int, float)):
        return None
    return dt.datetime.fromtimestamp(ms / 1000.0).strftime("%m-%d %H:%M")


def render(summary, sample=False):
    totals = summary["totals"]
    resumed = summary.get("resumed", False)
    sid = (summary["session_id"] or "").replace("session-", "")[:8].upper()
    kind = "样票 · 演示" if sample else ("会话小票 · 续" if resumed else "会话小票")
    lines = ["# DSH", "^ > %s No.%s" % (kind, sid), "---"]

    project = os.path.basename((summary["cwd"] or "").rstrip("/"))
    if project:
        lines.append("项目\t%s" % clip(project, 18))
    start = local_time(summary["start_ms"])
    end = local_time(summary["end_ms"])
    if start:
        lines.append("开始\t%s" % start)
    if end:
        lines.append("结束\t%s" % end)
    if start and end:
        lines.append("用时\t%s" % duration((summary["end_ms"] - summary["start_ms"]) / 1000.0))
    lines.append("对话\t%d 次调用" % summary["requests"])
    lines.append("---")

    # The log is summed per session, not per model, so all models share one section.
    name = clip(" / ".join(totals.models) or "未知模型", 22)
    priced = bool(totals.models) and not totals.unpriced
    rows = [
        ("输入", totals.input, totals.cost_input),
        ("输出", totals.output, totals.cost_output),
        ("缓存读", totals.cache_read, totals.cost_cache_read),
    ]
    if priced:
        lines.append("## %s\t%s" % (name, money(totals.total)))
        for label, count, cost in rows:
            if count:
                lines.append("> %s %s\t%s" % (label, tokens(count), money(cost)))
    else:
        lines.append("## %s\t未知价格" % name)
        lines.append("> 输入 %s · 输出 %s" % (tokens(totals.input + totals.cache_read), tokens(totals.output)))
    lines.append("---")

    if priced:
        lines.append("# 合计\t%s" % money(totals.total))
        if totals.peak_aware:
            lines.append("^ > 按 DeepSeek 官方标价 · 分高峰时段")
        else:
            lines.append("^ > 按官方 API 标价估算")
    else:
        lines.append("^ > %s 不在价目表上，未计入" % clip("、".join(sorted(totals.unpriced)) or name, 30))
    if resumed:
        lines.append("^ > 续接会话，只计本次新增")
    lines.extend(["===", "^ > 谢谢惠顾 · 欢迎再来"])
    return "\n".join(lines)


# ---------------------------------------------------------------- printing

def print_receipt(text, session_id):
    name = "DSH 小票 %s" % (session_id or "").replace("session-", "")[:8]
    result = subprocess.run(
        [NOTCHFAX, "print", "--quiet", "--name", name],
        input=text.encode("utf-8"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError("notchfax print failed (%d): %s" % (
            result.returncode, result.stderr.decode("utf-8", "replace").strip()))


def run(session_id, cwd, created_at, hook, dry_run, update_state, sample=False, bots_dirs=None, archive=False):
    path = find_session_log(session_id)
    if not path:
        raise RuntimeError("no session log for %s" % session_id)
    events = read_events(path)
    if not events:
        raise RuntimeError("empty session log %s" % path)

    header = events[0] if isinstance(events[0], dict) else {}
    if hook and header.get("type") == "session":
        if is_child_header(header):
            log("skip %s: child session" % session_id)
            return 0
        if in_bot_workspace(header.get("cwd"), bots_dirs):
            log("skip %s: bot workspace %s" % (session_id, header.get("cwd")))
            return 0

    def bill(billed_seq):
        summary = summarize(events, billed_seq)
        if summary is None:
            return None
        if not summary["cwd"]:
            summary["cwd"] = cwd or ""
        summary["resumed"] = billed_seq >= 0
        return summary if summary["requests"] > 0 else None

    def emit(summary):
        text = render(summary, sample=sample)
        if dry_run:
            print(text)
            return
        print_receipt(text, session_id)
        log("printed %s: requests=%d input=%d output=%d cache_read=%d total=$%.4f" % (
            session_id, summary["requests"], summary["totals"].input, summary["totals"].output,
            summary["totals"].cache_read, summary["totals"].total))

    if not update_state:
        summary = bill(-1)
        if summary is None:
            if not hook:
                print("会话 %s 没有可出票的模型用量。" % session_id)
            return 0
        emit(summary)
        return 0

    # Serialize billing for one shutdown wave: the lock is held across the read,
    # the print, and the watermark write, so a second session-end for the same
    # session waits and then finds nothing new instead of printing twice.
    with StateLock():
        entry = load_state().get(session_id) or {}
        billed_seq = int(entry.get("seq", -1)) if isinstance(entry, dict) else -1
        summary = bill(billed_seq)
        if summary is None:
            if not hook:
                print("会话 %s 没有新的模型用量，无需出票。" % session_id)
            return 0
        emit(summary)
        fresh = load_state()
        fresh[session_id] = {
            "seq": int(summary["last_seq"]),
            "total": round(summary["totals"].total, 6),
            "at": int(time.time()),
        }
        save_state(fresh)
    return 0


def main():
    parser = argparse.ArgumentParser(description="Print a DSH session receipt on Notchfax.")
    parser.add_argument("--session", help="session id (defaults to the one in the plugin payload)")
    parser.add_argument("--cwd", default="")
    parser.add_argument("--created-at", type=int, default=0)
    parser.add_argument("--hook", action="store_true", help="hook mode: never write to stderr")
    parser.add_argument("--dry-run", action="store_true", help="print the receipt text to stdout only")
    parser.add_argument("--no-state", action="store_true", help="bill the whole session; do not advance the watermark")
    parser.add_argument("--sample", action="store_true", help="mark the slip as a demo sample")
    parser.add_argument("--archive", action="store_true", help="the session just entered the archive set")
    parser.add_argument("--bots-dir", action="append", default=[], help="a bot workspace; its sessions get no receipt")
    args = parser.parse_args()

    session_id = args.session
    if not session_id:
        if args.hook:
            return 0
        parser.error("--session is required")

    hook = args.hook
    try:
        return run(session_id, args.cwd, args.created_at, hook, args.dry_run, not args.no_state, args.sample, args.bots_dir, args.archive)
    except Exception:
        detail = traceback.format_exc().strip()
        if hook:
            log(detail)
            return 0
        sys.stderr.write(detail + "\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
