#!/usr/bin/env python3
"""Wait for an OpenCode TUI process to exit, then let notchfax_receipt.py print.

Started detached by the OpenCode plugin. It polls the owning process, so it still
works when the TUI is closed with a signal and OpenCode's own dispose hook never runs.
"""

import argparse
import datetime as dt
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
LOG_DIR = os.path.join(HOME, "Library", "Logs", "Notchfax")
LOG_PATH = os.path.join(LOG_DIR, "opencode-receipt.log")
MAX_LIFETIME_SECONDS = 14 * 86400
POLL_SECONDS = 2
SETTLE_DELAY_SECONDS = 3


def log(message):
    try:
        os.makedirs(LOG_DIR, exist_ok=True)
        stamp = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write("[%s] %s\n" % (stamp, message.rstrip()))
    except Exception:
        pass


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--sessions", required=True)
    parser.add_argument("--receipt", required=True)
    args = parser.parse_args()

    deadline = time.time() + MAX_LIFETIME_SECONDS
    try:
        while alive(args.pid) and time.time() < deadline:
            if not os.path.exists(args.sessions):
                return 0
            time.sleep(POLL_SECONDS)
        if alive(args.pid):
            log("watcher for pid %d reached its lifetime limit" % args.pid)
            return 0

        # The UI is gone; give OpenCode a moment to finish its last writes.
        time.sleep(SETTLE_DELAY_SECONDS)
        if not os.path.exists(args.sessions):
            return 0
        result = subprocess.run(
            [sys.executable, args.receipt, "--sessions", args.sessions, "--quiet"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=120,
        )
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", "replace").strip()
            log("receipt helper failed (%d): %s" % (result.returncode, detail))
        return 0
    except Exception as error:
        log("watcher error: %s" % error)
        return 0
    finally:
        try:
            if os.path.exists(args.sessions):
                os.remove(args.sessions)
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
