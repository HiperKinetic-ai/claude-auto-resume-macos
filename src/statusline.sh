#!/usr/bin/env python3
"""
Claude Code live status-line tracker (single line).

Shows, left to right:
  🌿 git branch · 🧠 context (cur/max + %) · ⏳ session 5h (% + reset)
  · 📅 weekly 7d (% + reset) · 💰 session cost

Reset times:
  session 5h -> AM/PM clock time + countdown   e.g.  ↻ 6:58 PM (in 2h 14m)
  weekly  7d -> day + M/D date + countdown      e.g.  ↻ Wed 7/1 (in 2d 17h)

Reads the JSON session payload Claude Code pipes to stdin. Measures the
rendered width and progressively drops detail (token counts, then reset
absolutes, then reset countdowns) so the line never wraps. Rate-limit
segments are omitted when their data is absent.
See: https://code.claude.com/docs/en/statusline
"""
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

# ---- ANSI styling -----------------------------------------------------------
RESET = "\033[0m"
DIM = "\033[2m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
CYAN = "\033[36m"
BLUE = "\033[34m"
MAGENTA = "\033[35m"
SEP = f"{DIM} · {RESET}"

ANSI_RE = re.compile(r"\033\[[0-9;]*m")
WIDE_CHARS = set("🌿🧠⏳📅💰")  # render as two terminal cells


def disp_width(s):
    """Rendered width: strip ANSI, count our emojis as 2 cells each."""
    s = ANSI_RE.sub("", s)
    return sum(2 if ch in WIDE_CHARS else 1 for ch in s)


def color_for(pct):
    """Green under 70%, yellow 70-89%, red 90%+."""
    if pct >= 90:
        return RED
    if pct >= 70:
        return YELLOW
    return GREEN


def kfmt(n):
    """Compact token count: 45500 -> 45.5k, 200000 -> 200k, 1000000 -> 1M."""
    n = int(n or 0)
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M".replace(".0M", "M")
    if n >= 1000:
        return f"{n / 1000:.1f}k".replace(".0k", "k")
    return str(n)


def countdown(epoch):
    delta = float(epoch) - time.time()
    if delta <= 0:
        return "now"
    mins = int(delta // 60)
    days, rem = divmod(mins, 1440)
    hours, m = divmod(rem, 60)
    if days > 0:
        return f"{days}d {hours}h"
    if hours > 0:
        return f"{hours}h {m}m"
    return f"{m}m"


def ampm(dt):
    """6:58 PM (no leading zero, portable across libc)."""
    h = dt.hour % 12 or 12
    return f"{h}:{dt.minute:02d} {dt.strftime('%p')}"


def daydate(dt):
    """Wed 7/1 (no leading zeros)."""
    return f"{dt.strftime('%a')} {dt.month}/{dt.day}"


def reset_text(epoch, weekly, style):
    """style: 'full' (absolute + countdown), 'count' (countdown only), 'none'."""
    if not epoch or style == "none":
        return ""
    try:
        epoch = float(epoch)
    except (TypeError, ValueError):
        return ""
    cd = countdown(epoch)
    if style == "count":
        return f"in {cd}"
    dt = datetime.fromtimestamp(epoch)
    abs_s = daydate(dt) if weekly else ampm(dt)
    return f"{abs_s} (in {cd})"


def git_branch(cwd):
    try:
        out = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, timeout=1,
        )
        if out.returncode != 0:
            return None
        b = out.stdout.strip()
        if b == "HEAD":  # detached: show short sha instead
            sha = subprocess.run(
                ["git", "-C", cwd, "rev-parse", "--short", "HEAD"],
                capture_output=True, text=True, timeout=1,
            )
            return sha.stdout.strip() or None
        return b or None
    except Exception:
        return None


def build_line(branch, ctx_pct, current, size, rl, cost, include_tokens, reset_style):
    segs = []

    if branch:
        segs.append(f"{GREEN}🌿 {branch}{RESET}")

    ctx = f"🧠 {color_for(ctx_pct)}{ctx_pct:.0f}%{RESET}"
    if include_tokens:
        ctx += f" {DIM}{kfmt(current)}/{kfmt(size)}{RESET}"
    segs.append(ctx)

    for glyph, color, label, info, weekly in (
        ("⏳", MAGENTA, "5h", rl.get("five_hour") or {}, False),
        ("📅", BLUE, "7d", rl.get("seven_day") or {}, True),
    ):
        p = info.get("used_percentage")
        if p is None:
            continue
        p = float(p)
        seg = f"{color}{glyph} {label}{RESET} {color_for(p)}{p:.0f}%{RESET}"
        rtxt = reset_text(info.get("resets_at"), weekly, reset_style)
        if rtxt:
            seg += f" {DIM}↻ {rtxt}{RESET}"
        segs.append(seg)

    if cost is not None:
        segs.append(f"💰 {CYAN}${float(cost):.2f}{RESET}")

    return SEP.join(segs)


def main():
    try:
        data = json.load(sys.stdin)
    except Exception:
        print(f"{DIM}statusline: no/invalid input{RESET}")
        return

    try:
        cols = int(os.environ.get("COLUMNS") or 120)
    except (TypeError, ValueError):
        cols = 120

    cwd = (data.get("workspace") or {}).get("current_dir") or data.get("cwd") or os.getcwd()
    branch = git_branch(cwd)

    cw = data.get("context_window") or {}
    size = cw.get("context_window_size") or 200000
    used_pct = cw.get("used_percentage")
    cu = cw.get("current_usage") or {}
    if cu:
        current = (
            (cu.get("input_tokens") or 0)
            + (cu.get("cache_creation_input_tokens") or 0)
            + (cu.get("cache_read_input_tokens") or 0)
        )
    else:
        current = cw.get("total_input_tokens") or 0
    if used_pct is None:
        used_pct = (current / size * 100.0) if size else 0.0

    rl = data.get("rate_limits") or {}
    cost = (data.get("cost") or {}).get("total_cost_usd")

    # Richest layout that fits the terminal width; drop detail in priority order.
    line = None
    for include_tokens, reset_style in (
        (True, "full"),
        (False, "full"),
        (False, "count"),
        (False, "none"),
    ):
        line = build_line(branch, used_pct, current, size, rl, cost, include_tokens, reset_style)
        if disp_width(line) <= cols - 1:
            break
    print(line)


if __name__ == "__main__":
    main()
