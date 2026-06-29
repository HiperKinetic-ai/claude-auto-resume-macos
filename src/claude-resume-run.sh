#!/bin/bash
# claude-resume-run.sh — launchd payload for the 5-hour auto-resume feature.
#
# Reads ONLY an immutable per-job snapshot (argv[1]) produced by resume-at-reset.sh.
# Flow:  bounded JSON probe -> classify (5h backoff / weekly stop / auth-network stop)
#        -> resume the intended session with caffeinate wrapping the actual claude
#           process launched in Terminal (interactive) or headless (unattended)
#        -> notify (osascript) -> self-cleanup (bootout + delete plist/job files).
#
# auto mode only (never bypassPermissions). Remote Control + push only when armed
# with --rc (the snapshot carries rc/rc_name/require_rc + a per-run settings file).
#
# bash 3.2 compatible. Uses python3 for JSON + safe file generation, and a SIGKILL
# watchdog to hard-bound the probe (macOS has no timeout(1)); perl alarm bounds the
# osascript Terminal-open.

set -u

JOB_JSON="${1:-}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

fail_hard() {
  log "FATAL: $*"
  exit 1
}

[ -n "$JOB_JSON" ] && [ -f "$JOB_JSON" ] || fail_hard "missing job snapshot: '$JOB_JSON'"

# ---- Load snapshot fields into the environment (safe quoting via python) -------
EVAL_SRC="$(/usr/bin/python3 - "$JOB_JSON" <<'PY'
import json, shlex, sys
with open(sys.argv[1]) as f:
    j = json.load(f)
def g(k, d=""):
    v = j.get(k, d)
    if v is None:
        v = d
    return v
fields = {
    "LABEL": g("label"),
    "CLAUDE_BIN": g("claude_bin"),
    "CAFFEINATE_BIN": g("caffeinate_bin", "/usr/bin/caffeinate"),
    "OSASCRIPT_BIN": g("osascript_bin", "/usr/bin/osascript"),
    "SESSION_ID": g("session_id"),
    "SESSION_NAME": g("session_name"),
    "CWD": g("cwd"),
    "MODE": g("mode", "interactive"),
    "PROMPT": g("prompt"),
    "RC": "1" if j.get("rc") else "0",
    "RC_NAME": g("rc_name"),
    "REQUIRE_RC": "1" if j.get("require_rc") else "0",
    "SETTINGS_FILE": g("settings_file"),
    "LOG_FILE": g("log_file"),
    "PLIST_PATH": g("plist_path"),
    "JOBS_DIR": g("jobs_dir"),
    "LAUNCH_SCRIPT": g("launch_script"),
    "DOMAIN": g("domain"),
}
probe = j.get("probe") or {}
fields["PROBE_TIMEOUT_S"] = str(probe.get("timeout_s", 60))
fields["FIVEHR_INTERVAL_S"] = str(probe.get("fivehr_interval_s", 300))
fields["FIVEHR_MAX_S"] = str(probe.get("fivehr_max_s", 1800))
fields["NET_RETRIES"] = str(probe.get("net_retries", 3))
fields["NET_INTERVAL_S"] = str(probe.get("net_interval_s", 20))
for k, v in fields.items():
    # export so child pythons (write_launcher) can read them via os.environ
    print("export %s=%s" % (k, shlex.quote(str(v))))
PY
)" || fail_hard "could not parse job snapshot"
eval "$EVAL_SRC"

notify() {
  # $1 = message. Best-effort GUI notification.
  local msg="$1"
  "$OSASCRIPT_BIN" -e "display notification \"$msg\" with title \"Claude auto-resume\"" >/dev/null 2>&1 || true
  log "NOTIFY: $msg"
}

KEEP_LAUNCHER=0

cleanup_and_exit() {
  # $1 = exit code. Removes all transient artifacts, keeps the log, then boots the
  # job out of launchd last (booting out may terminate us, so files go first).
  # The launcher is kept when an interactive launch failed, so a late TCC grant /
  # manual run can still resume (and so we never auto-spawn a second resume).
  local code="${1:-0}"
  log "cleanup: removing transient job files"
  [ -n "${JOB_JSON:-}" ] && rm -f "$JOB_JSON" 2>/dev/null || true
  [ -n "${SETTINGS_FILE:-}" ] && rm -f "$SETTINGS_FILE" 2>/dev/null || true
  if [ "${KEEP_LAUNCHER:-0}" != "1" ] && [ -n "${LAUNCH_SCRIPT:-}" ]; then
    rm -f "$LAUNCH_SCRIPT" 2>/dev/null || true
  fi
  [ -n "${PLIST_PATH:-}" ] && rm -f "$PLIST_PATH" 2>/dev/null || true
  if [ -n "${DOMAIN:-}" ] && [ -n "${LABEL:-}" ]; then
    /bin/launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  fi
  exit "$code"
}

# ---- Bounded probe + classification ------------------------------------------
# Echoes one token: ok | fivehr | weekly | auth | network | other
classify_probe() {
  PROBE_OUT="$1" PROBE_RC="$2" /usr/bin/python3 <<'PY'
import json, os
raw = os.environ.get("PROBE_OUT", "")
rc = int(os.environ.get("PROBE_RC", "0") or "0")
low = raw.lower()

d = None
try:
    d = json.loads(raw)
except Exception:
    d = None

def has(*keys):
    return any(k in low for k in keys)

# Clean success.
if isinstance(d, dict) and d.get("subtype") == "success" and not d.get("is_error"):
    print("ok"); raise SystemExit

# Weekly must be checked before the generic 5-hour bucket (both say "limit").
if has("weekly", "7-day", "7 day", "seven-day", "seven day", "per week", "weekly limit"):
    print("weekly"); raise SystemExit

# 5-hour / general usage limit -> back off and retry.
if has("5-hour", "5 hour", "five hour", "five-hour", "rate limit", "rate_limit",
       "usage limit", "reached your usage", "resets at", "try again", "429",
       "too many requests", "limit reached", "reached the limit"):
    print("fivehr"); raise SystemExit

# Auth / login problems -> stop.
if has("unauthorized", "401", "403", "forbidden", "not logged in", "logged out",
       "invalid api key", "authentication", "auth error", "credit balance",
       "please run", "/login", "oauth"):
    print("auth"); raise SystemExit

# Timeout (perl alarm kills with signal -> shell rc>128) or network failure.
if rc > 128 or has("timeout", "timed out", "network", "econn", "etimedout",
                   "enotfound", "getaddrinfo", "fetch failed", "socket",
                   "dns", "could not resolve", "connection"):
    print("network"); raise SystemExit

print("other")
PY
}

run_probe_once() {
  # Bound the probe with a hard watchdog: SIGTERM at the limit, then an
  # uncatchable SIGKILL a few seconds later. macOS has no timeout(1), and a
  # slow/cold `claude` can outlive a plain SIGALRM (observed overrunning a 60s
  # bound by minutes), so we escalate to SIGKILL. Sets PROBE_OUT/PROBE_RC
  # (a killed probe yields rc>128 -> classified as timeout/network).
  local out cpid wpid
  out="$(mktemp "${TMPDIR:-/tmp}/car-probe.XXXXXX")"
  "$CLAUDE_BIN" -p --no-session-persistence --output-format json "Reply ok." >"$out" 2>&1 &
  cpid=$!
  (
    waited=0
    while kill -0 "$cpid" 2>/dev/null; do
      if [ "$waited" -ge "$PROBE_TIMEOUT_S" ]; then
        kill -TERM "$cpid" 2>/dev/null
        sleep 3
        kill -KILL "$cpid" 2>/dev/null
        break
      fi
      sleep 1
      waited=$(( waited + 1 ))
    done
  ) &
  wpid=$!
  wait "$cpid" 2>/dev/null
  PROBE_RC=$?
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  PROBE_OUT="$(cat "$out" 2>/dev/null)"
  rm -f "$out" 2>/dev/null
}

probe_until_ready() {
  local fivehr_start net_tries elapsed verdict now
  fivehr_start=""
  net_tries=0
  while : ; do
    log "probe: invoking bounded claude -p (timeout ${PROBE_TIMEOUT_S}s)"
    run_probe_once
    verdict="$(classify_probe "$PROBE_OUT" "$PROBE_RC")"
    log "probe: rc=$PROBE_RC verdict=$verdict"
    case "$verdict" in
      ok)
        return 0 ;;
      fivehr)
        now="$(date +%s)"
        [ -z "$fivehr_start" ] && fivehr_start="$now"
        elapsed=$(( now - fivehr_start ))
        if [ "$elapsed" -ge "$FIVEHR_MAX_S" ]; then
          notify "5-hour limit still active after $((FIVEHR_MAX_S/60))m for \"$SESSION_NAME\". Giving up."
          return 1
        fi
        log "probe: 5h limit still active; backing off ${FIVEHR_INTERVAL_S}s (elapsed ${elapsed}s)"
        sleep "$FIVEHR_INTERVAL_S" ;;
      weekly)
        notify "Weekly limit is active for \"$SESSION_NAME\" — not auto-resuming. Resume manually after the weekly reset."
        return 1 ;;
      auth)
        notify "Auto-resume stopped for \"$SESSION_NAME\": auth/login problem. Run 'claude auth status'."
        return 1 ;;
      network)
        net_tries=$(( net_tries + 1 ))
        if [ "$net_tries" -gt "$NET_RETRIES" ]; then
          notify "Auto-resume stopped for \"$SESSION_NAME\": network/timeout after ${NET_RETRIES} retries."
          return 1
        fi
        log "probe: network/timeout; quick retry $net_tries/$NET_RETRIES in ${NET_INTERVAL_S}s"
        sleep "$NET_INTERVAL_S" ;;
      *)
        notify "Auto-resume stopped for \"$SESSION_NAME\": unexpected probe result. See log."
        log "probe: unclassified output follows >>>"
        log "$PROBE_OUT"
        return 1 ;;
    esac
  done
}

# ---- Resume: interactive (Terminal, caffeinate wraps claude) ------------------
write_launcher() {
  # Generates LAUNCH_SCRIPT (mode 700): cd to cwd, exec caffeinate -i claude ...
  # caffeinate wraps the ACTUAL claude process so idle-sleep protection covers the
  # whole resumed session. RC flags + per-run settings added only when armed --rc.
  /usr/bin/python3 - <<PY
import os, shlex
launch = os.environ["LAUNCH_SCRIPT"]
caff = os.environ["CAFFEINATE_BIN"]
claude = os.environ["CLAUDE_BIN"]
cwd = os.environ["CWD"]
sid = os.environ["SESSION_ID"]
prompt = os.environ["PROMPT"]
rc = os.environ.get("RC") == "1"
rc_name = os.environ.get("RC_NAME", "")
settings_file = os.environ.get("SETTINGS_FILE", "")

cmd = [caff, "-i", claude, "--resume", sid, "--permission-mode", "auto"]
if rc and rc_name:
    cmd += ["--remote-control", rc_name]
    if settings_file:
        cmd += ["--settings", settings_file]
cmd += [prompt]

body = "#!/bin/bash\n"
body += "cd %s || exit 1\n" % shlex.quote(cwd)
body += "exec " + " ".join(shlex.quote(c) for c in cmd) + "\n"

with open(launch, "w") as f:
    f.write(body)
os.chmod(launch, 0o700)
print(launch)
PY
}

open_terminal_with() {
  # $1 = path to a script Terminal should run. Returns osascript's exit code.
  # Bounded by perl alarm so a fire-time TCC prompt (launchd context, no user to
  # click) can't hang the job — a timeout returns non-zero and triggers fallback.
  local target="$1"
  /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' 90 \
    "$OSASCRIPT_BIN" \
    -e "tell application \"Terminal\" to do script (quoted form of \"$target\")" \
    -e 'tell application "Terminal" to activate'
}

resume_interactive() {
  write_launcher >/dev/null || { log "could not write launcher"; return 1; }
  log "interactive: opening Terminal -> $LAUNCH_SCRIPT"
  if open_terminal_with "$LAUNCH_SCRIPT"; then
    notify "Resumed \"$SESSION_NAME\" in Terminal (auto mode$( [ "$RC" = 1 ] && echo ', Remote Control on' ))."
    # Terminal starts the launcher asynchronously; give it a moment to read/exec
    # the file before cleanup removes it (avoids a delete-mid-launch race).
    sleep 3
    return 0
  fi
  # Terminal automation failed/timed out — most often a launchd-context TCC prompt
  # that wasn't granted in time. Do NOT auto-launch an unattended resume here: if
  # macOS later honors the queued Apple event, Terminal would run the launcher and
  # we'd double-resume the same session. Keep the launcher and tell the user how to
  # resume (exactly one mechanism ever launches the session).
  KEEP_LAUNCHER=1
  log "interactive: Terminal automation FAILED (launcher kept for a late/manual run)"
  log "ready-to-run launcher: $LAUNCH_SCRIPT"
  if [ "$REQUIRE_RC" = "1" ]; then
    notify "Auto-resume ABORTED for \"$SESSION_NAME\": Terminal automation failed and --require-remote-control is set. Launcher saved (see log)."
  elif [ "$RC" = "1" ]; then
    notify "Terminal automation failed for \"$SESSION_NAME\" (phone reachability lost). Launcher saved — resume manually via the path in the log."
  else
    notify "Terminal automation failed for \"$SESSION_NAME\". Launcher saved — run the path in the log to resume, or grant Automation control of Terminal (or use --mode unattended)."
  fi
  return 1
}

# ---- Resume: unattended (headless -p) -----------------------------------------
resume_unattended() {
  log "unattended: caffeinate -i claude --resume (headless -p)"
  ( cd "$CWD" 2>/dev/null && \
    "$CAFFEINATE_BIN" -i "$CLAUDE_BIN" --resume "$SESSION_ID" \
      --permission-mode auto -p "$PROMPT" ) >>"$LOG_FILE" 2>&1
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    notify "Unattended resume of \"$SESSION_NAME\" completed (see log)."
  else
    notify "Unattended resume of \"$SESSION_NAME\" exited with code $rc (see log)."
  fi
  return "$rc"
}

# ---- Main --------------------------------------------------------------------
main() {
  log "==== auto-resume runner start: label=$LABEL session=$SESSION_ID mode=$MODE rc=$RC ===="
  log "cwd=$CWD claude_bin=$CLAUDE_BIN"

  if ! probe_until_ready; then
    log "probe did not clear; stopping"
    cleanup_and_exit 0
  fi
  log "probe OK: 5-hour window is open"

  if [ "$MODE" = "unattended" ]; then
    resume_unattended || true
  else
    resume_interactive || true
  fi

  cleanup_and_exit 0
}

# Allow sourcing for tests without running (RESUME_RUNNER_NO_MAIN=1).
if [ "${RESUME_RUNNER_NO_MAIN:-}" != "1" ]; then
  main
fi
