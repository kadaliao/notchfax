#!/usr/bin/env python3
"""OpenCode session-end receipt for Notchfax.

Reads a session from OpenCode's own database (the same numbers the TUI shows),
bills only the part after the last settled receipt, and asks Notchfax to print it.

Modes:
  --sessions <file>   sessions recorded by the plugin; settle them (used at session end)
  --session <id>      a statement (对账单) of the whole session so far; settles nothing
  --session <id> --settle   bill it like a session end: only what is new, then settle
  --dry-run           print the receipt to stdout/log instead of sending it

Environment:
  NOTCHFAX_BIN                   override the Notchfax CLI path
  NOTCHFAX_RECEIPT_DRY_RUN=1     same as --dry-run
  NOTCHFAX_RECEIPT_DISABLED=1    do nothing at all
"""

import argparse
import datetime as dt
import fcntl
import json
import os
import sqlite3
import subprocess
import sys
import time
import traceback

HOME = os.path.expanduser("~")
DB_PATH = os.path.join(HOME, ".local/share/opencode/opencode.db")
STATE_DIR = os.path.join(HOME, "Library", "Application Support", "Notchfax")
STATE_PATH = os.path.join(STATE_DIR, "opencode-receipts.json")
LOCK_PATH = os.path.join(STATE_DIR, "opencode-receipts.lock")
LOG_DIR = os.path.join(HOME, "Library", "Logs", "Notchfax")
LOG_PATH = os.path.join(LOG_DIR, "opencode-receipt.log")
DEFAULT_NOTCHFAX = "/Applications/Notchfax.app/Contents/MacOS/Notchfax"
STATE_KEEP_DAYS = 90


def ensure_dirs():
    os.makedirs(STATE_DIR, exist_ok=True)
    os.makedirs(LOG_DIR, exist_ok=True)


def log(message):
    try:
        ensure_dirs()
        stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write("[%s] %s\n" % (stamp, message.rstrip()))
    except Exception:
        pass


def read_state():
    try:
        with open(STATE_PATH, encoding="utf-8") as handle:
            data = json.load(handle)
        if not isinstance(data, dict):
            raise ValueError("state is not an object")
        data.setdefault("sessions", {})
        return data
    except FileNotFoundError:
        return {"sessions": {}}
    except Exception as error:
        log("state read failed: %s" % error)
        return {"sessions": {}}


def write_state(state):
    cutoff = time.time() - STATE_KEEP_DAYS * 86400
    sessions = state.get("sessions", {})
    for key in list(sessions):
        if float(sessions[key].get("at", 0) or 0) < cutoff:
            del sessions[key]
    ensure_dirs()
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp, STATE_PATH)


class StateLock:
    def __enter__(self):
        ensure_dirs()
        self.handle = open(LOCK_PATH, "a+")
        fcntl.flock(self.handle, fcntl.LOCK_EX)
        return self.handle

    def __exit__(self, *exc):
        fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()
        return False


def connect_db():
    uri = "file:%s?mode=ro" % DB_PATH.replace("?", "%3f")
    connection = sqlite3.connect(uri, uri=True, timeout=10)
    connection.row_factory = sqlite3.Row
    return connection


# ---------------------------------------------------------------- layout
# Shared receipt format: see ../README.md.

def fmt_tokens(count):
    count = int(max(0, count))
    if count < 10_000:
        return "{:,}".format(count)
    if count < 100_000_000:
        text = "%.1f" % (count / 10_000.0)
        return (text[:-2] if text.endswith(".0") else text) + "万"
    text = "%.2f" % (count / 100_000_000.0)
    return text.rstrip("0").rstrip(".") + "亿"


def fmt_money(value):
    value = float(value or 0)
    if 0 < value < 0.005:
        return "<$0.01"
    return "$%.2f" % value


def fmt_duration(seconds):
    seconds = int(max(0, seconds))
    if seconds < 60:
        return "%d 秒" % seconds
    minutes = seconds // 60
    if minutes < 60:
        return "%d 分" % minutes
    hours, minutes = divmod(minutes, 60)
    return "%d 小时 %d 分" % (hours, minutes) if minutes else "%d 小时" % hours


def fmt_time(ms):
    return dt.datetime.fromtimestamp(float(ms) / 1000.0).strftime("%m-%d %H:%M")


def clip(text, limit):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def model_name(provider, model):
    provider = (provider or "").strip()
    model = (model or "").strip()
    if provider and model:
        return "%s/%s" % (provider, model)
    return model or provider or "未知模型"


def load_messages(connection, session_id, through):
    rows = connection.execute(
        "SELECT time_created, data FROM message "
        "WHERE session_id = ? AND time_created > ? ORDER BY time_created, id",
        (session_id, int(through or 0)),
    ).fetchall()
    messages = []
    for row in rows:
        try:
            data = json.loads(row["data"])
        except Exception:
            continue
        messages.append((int(row["time_created"]), data))
    return messages


class Bucket(object):
    """One model's usage. Cost is what OpenCode itself recorded on each message."""

    def __init__(self, name):
        self.name = name
        self.input = 0
        self.output = 0
        self.reasoning = 0
        self.cache_read = 0
        self.cache_write = 0
        self.cost = 0.0

    @property
    def tokens(self):
        return self.input + self.output + self.reasoning + self.cache_read + self.cache_write

    @property
    def priced(self):
        return self.cost > 0 or self.tokens == 0


def number(value):
    return value if isinstance(value, (int, float)) and value > 0 else 0


def build_bill(connection, session_id, previous, interim=False):
    """Bill the messages after the watermark in `previous`, one section per model.

    OpenCode stores a cost on every assistant message (its own price table, the same numbers
    the TUI shows); the session row is just their sum, so billing per message gives the
    same total and lets the receipt split it by model.
    """
    row = connection.execute("SELECT * FROM session WHERE id = ?", (session_id,)).fetchone()
    if row is None or row["parent_id"]:
        return None

    through = int(previous.get("through", 0) or 0)
    messages = load_messages(connection, session_id, through)
    if not messages:
        return None

    buckets = {}
    calls = 0
    prompts = 0
    completed_at = []
    for created, data in messages:
        role = data.get("role")
        if role == "user":
            prompts += 1
            continue
        if role != "assistant":
            continue
        calls += 1
        timing = data.get("time") or {}
        if timing.get("completed"):
            completed_at.append(int(timing["completed"]))
        name = model_name(data.get("providerID"), data.get("modelID"))
        bucket = buckets.setdefault(name, Bucket(name))
        tokens = data.get("tokens") or {}
        cache = tokens.get("cache") or {}
        bucket.input += int(number(tokens.get("input")))
        bucket.output += int(number(tokens.get("output")))
        bucket.reasoning += int(number(tokens.get("reasoning")))
        bucket.cache_read += int(number(cache.get("read")))
        bucket.cache_write += int(number(cache.get("write")))
        bucket.cost += float(number(data.get("cost")))

    if not calls or not any(bucket.tokens for bucket in buckets.values()):
        return None

    first_at = messages[0][0]
    last_at = messages[-1][0]
    start = int(row["time_created"] or first_at) if through == 0 else first_at
    end = max(completed_at + [last_at])
    if end < start:
        end = start

    kind = "对账单" if interim else ("会话小票 · 续" if through else "会话小票")
    lines = ["# OPENCODE", "^ > %s No.%s" % (kind, str(session_id)[-8:].upper()), "---"]
    project = os.path.basename(str(row["directory"] or "").rstrip("/"))
    if project:
        lines.append("项目\t%s" % clip(project, 18))
    if row["title"] and not str(row["title"]).startswith("New session"):
        lines.append("标题\t%s" % clip(row["title"], 24))
    lines.append("开始\t%s" % fmt_time(start))
    lines.append("%s\t%s" % ("截至" if interim else "结束", fmt_time(end)))
    lines.append("用时\t%s" % fmt_duration((end - start) / 1000.0))
    lines.append("对话\t%d 问 · %d 次调用" % (prompts, calls))
    lines.append("---")

    ordered = sorted(buckets.values(), key=lambda b: (not b.priced, -b.cost))
    unpriced = []
    for bucket in ordered:
        if not bucket.tokens:
            continue
        if not bucket.priced:
            # Tokens but no price recorded for this model. Do not guess.
            unpriced.append(bucket.name)
            lines.append("## %s\t未知价格" % clip(bucket.name, 22))
            lines.append("> 输入 %s · 输出 %s" % (
                fmt_tokens(bucket.input + bucket.cache_read + bucket.cache_write),
                fmt_tokens(bucket.output + bucket.reasoning)))
            continue
        # OpenCode records one cost per message, not per token kind, so lines carry counts only.
        lines.append("## %s\t%s" % (clip(bucket.name, 22), fmt_money(bucket.cost)))
        for label, count in (
            ("输入", bucket.input),
            ("输出", bucket.output + bucket.reasoning),
            ("缓存写", bucket.cache_write),
            ("缓存读", bucket.cache_read),
        ):
            if count:
                lines.append("> %s %s" % (label, fmt_tokens(count)))
        if bucket.reasoning:
            lines.append("> 输出里含思考 %s" % fmt_tokens(bucket.reasoning))
    lines.append("---")

    total = sum(bucket.cost for bucket in ordered if bucket.priced)
    if any(bucket.priced and bucket.tokens for bucket in ordered):
        lines.append("# 合计\t%s" % fmt_money(total))
        lines.append("^ > 按 OpenCode 记录的标价")
    if unpriced:
        lines.append("^ > %s 不在价目表上，未计入" % clip("、".join(unpriced), 30))
    if through and not interim:
        lines.append("^ > 续接会话，只计本次新增")
    lines.extend(["===", "^ > 谢谢惠顾 · 欢迎再来"])

    return {
        "session_id": session_id,
        "text": "\n".join(lines),
        "cost": float(row["cost"] or 0),
        "input": int(row["tokens_input"] or 0),
        "output": int(row["tokens_output"] or 0),
        "reasoning": int(row["tokens_reasoning"] or 0),
        "through": last_at,
    }


def notchfax_bin():
    return os.environ.get("NOTCHFAX_BIN") or DEFAULT_NOTCHFAX


def send_receipt(text, session_id):
    binary = notchfax_bin()
    if not os.path.exists(binary):
        raise RuntimeError("Notchfax CLI not found: %s" % binary)
    name = "OpenCode 小票 %s" % str(session_id)[-8:].upper()
    result = subprocess.run(
        [binary, "print", "--quiet", "--name", name],
        input=text.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=60,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError("notchfax print failed (%d): %s" % (result.returncode, detail))


def print_bills(session_ids, settle, dry_run, quiet):
    disabled = os.environ.get("NOTCHFAX_RECEIPT_DISABLED", "").strip().lower()
    if disabled in ("1", "true", "yes", "on"):
        return 0

    sent = 0
    with StateLock():
        state = read_state()
        connection = connect_db()
        try:
            for session_id in session_ids:
                if not session_id:
                    continue
                # Looking without settling is a statement of the whole session so far; it
                # ignores and leaves alone the watermark the end-of-session receipt uses.
                previous = (state["sessions"].get(session_id) or {}) if settle else {}
                bill = build_bill(connection, session_id, previous, interim=not settle)
                if bill is None:
                    continue
                if dry_run:
                    print(bill["text"])
                    print("")
                    log("dry-run receipt\n%s" % bill["text"])
                    sent += 1
                    continue
                try:
                    send_receipt(bill["text"], session_id)
                except Exception as error:
                    log("session %s: %s" % (session_id, error))
                    continue
                sent += 1
                if not quiet:
                    print(bill["text"])
                    print("\n已送去 Notchfax 打印。")
                if settle:
                    state["sessions"][session_id] = {
                        "cost": round(bill["cost"], 8),
                        "input": bill["input"],
                        "output": bill["output"],
                        "reasoning": bill["reasoning"],
                        "through": bill["through"],
                        "at": int(time.time()),
                    }
            if settle and sent:
                write_state(state)
        finally:
            connection.close()
    return 0


def read_session_ids(path):
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception as error:
        log("sessions file read failed (%s): %s" % (path, error))
        return []
    sessions = data.get("sessions") if isinstance(data, dict) else None
    if isinstance(sessions, dict):
        return [str(key) for key in sessions]
    if isinstance(sessions, list):
        return [str(item.get("sessionID") or item) for item in sessions if item]
    return []


def main():
    parser = argparse.ArgumentParser(description="Print an OpenCode session receipt on Notchfax.")
    parser.add_argument("--sessions", metavar="FILE", help="session file written by the OpenCode plugin")
    parser.add_argument("--session", action="append", metavar="ID", help="session id to look at (may repeat)")
    parser.add_argument("--settle", action="store_true", help="remember --session as paid up to now")
    parser.add_argument("--dry-run", action="store_true", help="render the receipt instead of printing it")
    parser.add_argument("--quiet", action="store_true", help="no stdout on success")
    args = parser.parse_args()

    dry_run = args.dry_run or os.environ.get("NOTCHFAX_RECEIPT_DRY_RUN", "").strip().lower() in (
        "1",
        "true",
        "yes",
        "on",
    )

    try:
        if args.sessions:
            ids = read_session_ids(args.sessions)
            return print_bills(ids, settle=True, dry_run=dry_run, quiet=True)
        if args.session:
            return print_bills(args.session, settle=args.settle, dry_run=dry_run, quiet=args.quiet)
        parser.error("need --sessions FILE or --session ID")
        return 2
    except Exception:
        log("fatal: %s" % traceback.format_exc())
        return 0


if __name__ == "__main__":
    sys.exit(main())
