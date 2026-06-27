#!/usr/bin/env python3
"""
Pass-through wrapper around your existing Claude Code status line (auto-resume capture).

This file is the ONLY status-bar change made by the auto-resume feature. It does
NOT modify your status line. It:

  1. Reads the FULL stdin payload into memory (stdin is consumed once read, so we
     must buffer it).
  2. Best-effort side-writes the 5-hour reset state for the active session to
     ~/.claude/resume-state/<session_id>.json (all errors swallowed: no added
     latency, no visible output on failure).
  3. Re-feeds the EXACT same bytes to your real status-line command — the value
     that was in settings.json `statusLine.command` before install, snapshotted in
     resume-install.json (or the bundled ~/.claude/statusline.sh tracker as a
     fallback) — and faithfully passes through its stdout, stderr, and exit code,
     so the status bar behaves byte-for-byte identically to before.

Installed/removed by resume-at-reset.sh (which repoints only settings.json
statusLine.command to this file and restores it on --uninstall).
"""
import json
import os
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
CLAUDE_DIR = os.path.join(HOME, ".claude")
FALLBACK_STATUSLINE = os.path.join(CLAUDE_DIR, "statusline.sh")
INSTALL_META = os.path.join(CLAUDE_DIR, "resume-install.json")
STATE_DIR = os.path.join(CLAUDE_DIR, "resume-state")
PRUNE_OLDER_THAN_S = 24 * 60 * 60


def _side_write(raw):
    """Extract resume state from the payload and atomically persist it. Best
    effort: every failure path is swallowed so the bar is never affected."""
    try:
        data = json.loads(raw.decode("utf-8"))
    except Exception:
        return
    if not isinstance(data, dict):
        return

    session_id = data.get("session_id")
    if not session_id or not isinstance(session_id, str):
        return
    # Guard against path traversal via a hostile session_id.
    if "/" in session_id or session_id in (".", ".."):
        return

    workspace = data.get("workspace") or {}
    cwd = workspace.get("current_dir") or data.get("cwd")
    if not cwd:
        return

    rl = data.get("rate_limits") or {}
    five = rl.get("five_hour") or {}
    seven = rl.get("seven_day") or {}

    session_name = data.get("session_name")
    if not session_name:
        session_name = os.path.basename(cwd.rstrip("/")) or session_id

    record = {
        "session_id": session_id,
        "session_name": session_name,
        "cwd": cwd,
        "five_hour_resets_at": five.get("resets_at"),
        "five_hour_used_pct": five.get("used_percentage"),
        "seven_day_resets_at": seven.get("resets_at"),
        "updated_at": int(time.time()),
    }

    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        try:
            os.chmod(STATE_DIR, 0o700)
        except Exception:
            pass
    except Exception:
        return

    # Prune stale state files (>24h) so old sessions don't linger.
    try:
        now = time.time()
        for fn in os.listdir(STATE_DIR):
            if not fn.endswith(".json"):
                continue
            p = os.path.join(STATE_DIR, fn)
            try:
                if now - os.path.getmtime(p) > PRUNE_OLDER_THAN_S:
                    os.remove(p)
            except Exception:
                pass
    except Exception:
        pass

    # Atomic write + chmod 600.
    dest = os.path.join(STATE_DIR, session_id + ".json")
    tmp = None
    try:
        fd, tmp = tempfile.mkstemp(dir=STATE_DIR, prefix=".tmp-state-")
        with os.fdopen(fd, "w") as f:
            json.dump(record, f)
        os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
    except Exception:
        if tmp is not None:
            try:
                os.remove(tmp)
            except Exception:
                pass


def _real_statusline_command():
    """The status line this wrapper sits in front of. Prefer the command snapshotted
    at install time (so we faithfully wrap WHATEVER the user already had — a script
    path or a full shell command/pipeline); fall back to the bundled tracker. Guards
    against a snapshot that points back at this wrapper (no self-recursion)."""
    try:
        with open(INSTALL_META) as f:
            prev = (json.load(f) or {}).get("statusline_command_prev")
        if isinstance(prev, str) and prev.strip() and "statusline-capture.sh" not in prev:
            return prev.strip()
    except Exception:
        pass
    return None


def main():
    raw = sys.stdin.buffer.read()

    try:
        _side_write(raw)
    except Exception:
        pass

    # Faithful pass-through: same bytes in, inherit our stdout/stderr, same exit code.
    # Run the user's real status-line command (snapshotted at install) via the shell so
    # both a bare script path and a full command/pipeline work and '~' expands. If none
    # is recorded, fall back to the bundled tracker. Never break the bar: exit 0 on error.
    cmd = _real_statusline_command()
    try:
        if cmd:
            proc = subprocess.run(cmd, shell=True, input=raw)
        else:
            proc = subprocess.run([FALLBACK_STATUSLINE], input=raw)
    except FileNotFoundError:
        sys.exit(0)
    except Exception:
        sys.exit(0)
    sys.exit(proc.returncode)


if __name__ == "__main__":
    main()
