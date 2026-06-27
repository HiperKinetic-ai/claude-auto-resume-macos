#!/bin/bash
# resume-at-reset.sh — controller for the 5-hour auto-resume feature.
#
# Commands:
#   (arm is default)        arm the newest session in $PWD to resume after reset
#   --status                show install + armed-job state
#   --cancel [label|all]    cancel armed job(s) (keeps logs)
#   --dry-run               resolve/validate only; persist nothing
#   --install               install the capture wrapper (repoint statusLine.command)
#   --uninstall             full revert: restore statusLine.command + remove all residue
#   --install-alias [name]  add an 'auto-resume' pass-through shell alias to ~/.zshrc
#                           (marker-tracked; default name 'auto-resume'; collision-guarded)
#   --uninstall-alias       remove just that alias (leaves the feature installed)
#   --test-terminal         run the exact Terminal-automation path with a dummy launcher
#                           (so the one-time macOS Automation/TCC grant is in place)
#
# Flags (for arm/dry-run):
#   --mode interactive|unattended   (default interactive)
#   --dir <path>                    target project dir (default $PWD)
#   --session-id <id>               resolve a specific session
#   --remote-control [name] | --rc [name]   opt-in Remote Control + per-run push (OFF by default)
#   --require-remote-control        only meaningful with --rc; abort if RC can't establish
#   --force                         allow a second job for an already-armed session
#   --prompt <text>                 override the resume prompt
#   --claude-bin <path>             testing override for the claude binary
#
# Locked decisions: 5-hour window only, manual arm, --permission-mode auto (never
# bypass), Remote Control OFF by default. The ONLY settings.json change is
# statusLine.command. No .zshrc edits except --install-alias / --uninstall-alias.
#
# bash 3.2 compatible.

set -u

# ---- Paths -------------------------------------------------------------------
HOME_DIR="$HOME"
CLAUDE_DIR="$HOME_DIR/.claude"
STATE_DIR="$CLAUDE_DIR/resume-state"
JOBS_DIR="$CLAUDE_DIR/resume-jobs"
LOGS_DIR="$CLAUDE_DIR/resume-logs"
LA_DIR="$HOME_DIR/Library/LaunchAgents"
SETTINGS="$CLAUDE_DIR/settings.json"
WRAPPER="$CLAUDE_DIR/statusline-capture.sh"
REAL_STATUSLINE="$CLAUDE_DIR/statusline.sh"
RUNNER="$CLAUDE_DIR/claude-resume-run.sh"
SELF="$CLAUDE_DIR/resume-at-reset.sh"
INSTALL_META="$CLAUDE_DIR/resume-install.json"
SETTINGS_BAK="$CLAUDE_DIR/resume-install.settings.bak.json"
ZSHRC="$HOME_DIR/.zshrc"
ZPROFILE="$HOME_DIR/.zprofile"
DEFAULT_ALIAS_NAME="auto-resume"
ALIAS_BEGIN="# >>> claude-auto-resume alias >>>"
ALIAS_END="# <<< claude-auto-resume alias <<<"

UID_NUM="$(id -u)"
USER_NAME="$(id -un)"
DOMAIN="gui/$UID_NUM"
MIN_VERSION="2.1.51"
DEFAULT_MARGIN=120
MARGIN_SECONDS="${RESUME_MARGIN_SECONDS:-$DEFAULT_MARGIN}"

DEFAULT_PROMPT="The previous session stopped because the 5-hour limit was reached. Continue the work until the task is complete. Notify me when done or when you need a decision."

PY=/usr/bin/python3

# ---- Output helpers ----------------------------------------------------------
err()  { printf 'error: %s\n' "$*" >&2; }
note() { printf '%s\n' "$*"; }
die()  { err "$*"; exit 1; }

ensure_dirs() {
  mkdir -p "$STATE_DIR" "$JOBS_DIR" "$LOGS_DIR" "$LA_DIR" 2>/dev/null || true
  chmod 700 "$STATE_DIR" "$JOBS_DIR" "$LOGS_DIR" 2>/dev/null || true
}

sanitize() {
  # Keep only [A-Za-z0-9._-]; collapse the rest to '-'. Truncate to 60 chars.
  printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | cut -c1-60
}

abspath() {
  "$PY" -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1"
}

# ---- JSON helpers ------------------------------------------------------------
json_get() {
  # json_get <file> <key>  -> prints value ("" if absent/null)
  "$PY" - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        j = json.load(f)
    v = j.get(sys.argv[2])
    print("" if v is None else v)
except Exception:
    print("")
PY
}

# ---- Capture install (only settings.json change = statusLine.command) ---------
is_capture_installed() {
  [ -f "$WRAPPER" ] || return 1
  local cur
  cur="$(json_statusline_command)"
  case "$cur" in
    *statusline-capture.sh) return 0 ;;
    *) return 1 ;;
  esac
}

json_statusline_command() {
  "$PY" - "$SETTINGS" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        j = json.load(f)
    print((j.get("statusLine") or {}).get("command", ""))
except Exception:
    print("")
PY
}

cmd_install() {
  ensure_dirs
  [ -f "$WRAPPER" ] || die "wrapper missing: $WRAPPER (re-create it before installing)"
  chmod 755 "$WRAPPER" "$RUNNER" "$SELF" 2>/dev/null || true

  if is_capture_installed; then
    note "Capture wrapper already installed (statusLine.command -> statusline-capture.sh)."
    return 0
  fi

  [ -f "$SETTINGS" ] || die "settings.json not found: $SETTINGS"

  local prev
  prev="$(json_statusline_command)"
  [ -n "$prev" ] || die "settings.json has no statusLine.command to snapshot; refusing to install"

  # Full backup of settings.json (exact bytes) before our surgical edit.
  cp "$SETTINGS" "$SETTINGS_BAK" 2>/dev/null || die "could not back up settings.json"
  chmod 600 "$SETTINGS_BAK" 2>/dev/null || true

  # Repoint ONLY statusLine.command -> wrapper. All other keys preserved.
  WRAPPER_CMD="~/.claude/statusline-capture.sh" "$PY" - "$SETTINGS" <<'PY' || die "failed to update settings.json"
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    j = json.load(f)
sl = j.get("statusLine")
if not isinstance(sl, dict):
    raise SystemExit("statusLine block missing")
sl["command"] = os.environ["WRAPPER_CMD"]
with open(path, "w") as f:
    json.dump(j, f, indent=2)
    f.write("\n")
PY

  # Record install metadata for a faithful uninstall.
  PREV="$prev" "$PY" - "$INSTALL_META" <<'PY'
import json, os, sys, time
meta = {
    "installed_at": int(time.time()),
    "settings_path": os.path.expanduser("~/.claude/settings.json"),
    "statusline_command_prev": os.environ["PREV"],
    "wrapper_path": os.path.expanduser("~/.claude/statusline-capture.sh"),
    "settings_backup": os.path.expanduser("~/.claude/resume-install.settings.bak.json"),
    "alias_installed": False,
}
with open(sys.argv[1], "w") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
PY
  chmod 600 "$INSTALL_META" 2>/dev/null || true

  note "Installed capture wrapper."
  note "  statusLine.command: '$prev'  ->  '~/.claude/statusline-capture.sh'"
  note "  snapshot saved to:  $INSTALL_META"
  note "Status bar behavior is unchanged; reset state will be captured on each refresh."
}

ensure_capture_installed() {
  if ! is_capture_installed; then
    note "(capture wrapper not yet installed — installing now)"
    cmd_install
  fi
}

# ---- Version / preflight -----------------------------------------------------
version_ge() {
  # version_ge <have> <min>  -> exit 0 if have >= min
  HAVE="$1" MIN="$2" "$PY" <<'PY'
import os, sys
def parse(v):
    nums = []
    for part in v.strip().split()[0].split("."):
        try: nums.append(int(part))
        except ValueError:
            d = "".join(ch for ch in part if ch.isdigit())
            nums.append(int(d) if d else 0)
    return nums
h, m = parse(os.environ["HAVE"]), parse(os.environ["MIN"])
n = max(len(h), len(m))
h += [0]*(n-len(h)); m += [0]*(n-len(m))
sys.exit(0 if h >= m else 1)
PY
}

# ---- Session resolution ------------------------------------------------------
resolve_session_file() {
  # Args: <target_dir> <session_id-or-empty>. Prints state file path or "".
  TARGET_DIR="$1" WANT_ID="$2" STATE_DIR="$STATE_DIR" "$PY" <<'PY'
import json, os, sys
state_dir = os.environ["STATE_DIR"]
target = os.path.realpath(os.environ["TARGET_DIR"])
want = os.environ.get("WANT_ID", "")
best = None
best_mtime = -1
try:
    files = [os.path.join(state_dir, f) for f in os.listdir(state_dir) if f.endswith(".json")]
except Exception:
    files = []
for p in files:
    try:
        with open(p) as f:
            j = json.load(f)
    except Exception:
        continue
    sid = j.get("session_id")
    cwd = j.get("cwd")
    if not sid:
        continue
    if want:
        if sid == want:
            print(p); raise SystemExit
        continue
    if not cwd:
        continue
    if os.path.realpath(cwd) != target:
        continue
    m = os.path.getmtime(p)
    if m > best_mtime:
        best_mtime = m
        best = p
print(best or "")
PY
}

# ---- Duplicate detection -----------------------------------------------------
existing_job_for_session() {
  # Prints label of an existing armed job for this session id, or "".
  WANT_ID="$1" JOBS_DIR="$JOBS_DIR" "$PY" <<'PY'
import json, os
jobs_dir = os.environ["JOBS_DIR"]
want = os.environ["WANT_ID"]
try:
    files = [f for f in os.listdir(jobs_dir) if f.endswith(".json") and not f.endswith("-settings.json")]
except Exception:
    files = []
for f in files:
    try:
        with open(os.path.join(jobs_dir, f)) as fh:
            j = json.load(fh)
    except Exception:
        continue
    if j.get("session_id") == want:
        print(j.get("label", "")); break
PY
}

# ---- Plist generation + scheduling -------------------------------------------
write_plist_and_get_fire() {
  # Writes the plist; echoes the effective fire epoch (rounded to the minute).
  PLIST="$1" LABEL="$2" RUNNER="$RUNNER" JOB_JSON="$3" LOG_FILE="$4" FIRE_AT="$5" "$PY" <<'PY'
import math, os, plistlib, time
plist_path = os.environ["PLIST"]
label = os.environ["LABEL"]
runner = os.environ["RUNNER"]
job_json = os.environ["JOB_JSON"]
log_file = os.environ["LOG_FILE"]
fire = float(os.environ["FIRE_AT"])
now = time.time()
# launchd StartCalendarInterval is minute-granular; round up and avoid the
# current minute so it fires in a future, distinct minute.
fire = math.ceil(fire / 60.0) * 60
while fire <= now + 30:
    fire += 60
lt = time.localtime(fire)
plist = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", runner, job_json],
    "StartCalendarInterval": {
        "Minute": lt.tm_min, "Hour": lt.tm_hour,
        "Day": lt.tm_mday, "Month": lt.tm_mon,
    },
    "StandardOutPath": log_file,
    "StandardErrorPath": log_file,
    "ProcessType": "Interactive",
    "RunAtLoad": False,
}
with open(plist_path, "wb") as f:
    plistlib.dump(plist, f)
os.chmod(plist_path, 0o644)
print(int(fire))
PY
}

eta_text() {
  TARGET="$1" "$PY" <<'PY'
import os, time
t = float(os.environ["TARGET"]); now = time.time(); d = int(t-now)
if d < 0: d = 0
h, r = divmod(d, 3600); m, s = divmod(r, 60)
when = time.strftime("%a %Y-%m-%d %H:%M:%S", time.localtime(t))
print("%s (in %dh %dm %ds)" % (when, h, m, s))
PY
}

# ---- arm / dry-run -----------------------------------------------------------
do_arm() {
  local dry="$1"
  ensure_dirs
  [ "$dry" = "1" ] || ensure_capture_installed

  local target_dir="${OPT_DIR:-$PWD}"
  target_dir="$(abspath "$target_dir")"

  # 1. Resolve session.
  local state_file
  state_file="$(resolve_session_file "$target_dir" "${OPT_SESSION_ID:-}")"
  if [ -z "$state_file" ]; then
    if [ -n "${OPT_SESSION_ID:-}" ]; then
      die "no captured state for session-id '${OPT_SESSION_ID}'. Open that session so the status bar captures it, then retry."
    fi
    die "no captured session state for dir: $target_dir
  The capture wrapper records state on each status-bar refresh. Open a Claude Code
  session in that directory (let the bar refresh once), then re-run arm.
  Never silently falling back to --continue."
  fi

  local session_id session_name cwd resets_at five_pct
  session_id="$(json_get "$state_file" session_id)"
  session_name="$(json_get "$state_file" session_name)"
  cwd="$(json_get "$state_file" cwd)"
  resets_at="$(json_get "$state_file" five_hour_resets_at)"
  five_pct="$(json_get "$state_file" five_hour_used_pct)"
  [ -n "$cwd" ] || cwd="$target_dir"
  [ -n "$session_name" ] || session_name="$(basename "$cwd")"

  # 3. Validate reset is in the future.
  if [ -z "$resets_at" ]; then
    die "captured state for this session has no five_hour_resets_at (was the 5-hour window ever shown?)."
  fi
  local now fire_at
  now="$(date +%s)"
  # numeric compare via python (resets_at may be float)
  if ! FIRE_RESET="$resets_at" NOW="$now" "$PY" -c 'import os,sys; sys.exit(0 if float(os.environ["FIRE_RESET"])>float(os.environ["NOW"]) else 1)'; then
    die "five_hour_resets_at ($resets_at) is not in the future. Nothing to arm."
  fi
  fire_at="$(R="$resets_at" M="$MARGIN_SECONDS" "$PY" -c 'import os; print(int(float(os.environ["R"]))+int(os.environ["M"]))' 2>/dev/null)"

  # 2. Duplicate protection.
  local dup
  dup="$(existing_job_for_session "$session_id")"
  if [ -n "$dup" ] && [ "${OPT_FORCE:-0}" != "1" ]; then
    die "a job is already armed for this session ($dup). Use --force to arm another, or --cancel $dup."
  fi

  # 4. Preflight.
  local claude_bin
  claude_bin="${OPT_CLAUDE_BIN:-$(command -v claude || true)}"
  [ -n "$claude_bin" ] || die "claude not found on PATH; pass --claude-bin <path>."
  # Absolute path WITHOUT dereferencing symlinks, so ~/.local/bin/claude (which
  # points at the current version) keeps working across upgrades.
  claude_bin="$("$PY" -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$claude_bin")"
  [ -x "$claude_bin" ] || die "claude binary not executable: $claude_bin"
  [ -x /usr/bin/caffeinate ] || die "caffeinate not found at /usr/bin/caffeinate"
  [ -x /usr/bin/osascript ] || die "osascript not found at /usr/bin/osascript"

  local ver
  if [ -z "${OPT_CLAUDE_BIN:-}" ]; then
    ver="$("$claude_bin" --version 2>/dev/null | head -1)"
    if [ -n "$ver" ]; then
      if version_ge "$ver" "$MIN_VERSION"; then :; else
        die "claude version '$ver' < required $MIN_VERSION."
      fi
    fi
    # Auth check (claude.ai login required to resume; RC also needs claude.ai).
    local logged
    logged="$("$claude_bin" auth status 2>/dev/null | "$PY" -c 'import json,sys
try:
    j=json.load(sys.stdin); print("yes" if j.get("loggedIn") else "no", j.get("authMethod",""))
except Exception:
    print("unknown ")' )"
    case "$logged" in
      yes*) : ;;
      no*)  die "not logged in. Run: claude auth status (then log in)." ;;
      *)    note "warning: could not confirm auth status; proceeding." ;;
    esac
  else
    note "(testing override: --claude-bin set; skipping version/auth preflight)"
  fi

  # RC eligibility (only when armed --rc).
  local rc="${OPT_RC:-0}" rc_name="" require_rc="${OPT_REQUIRE_RC:-0}"
  if [ "$rc" = "1" ]; then
    rc_name="${OPT_RC_NAME:-}"
    [ -n "$rc_name" ] || rc_name="$(basename "$cwd") auto-resume"
    rc_name="$(printf '%s' "$rc_name" | LC_ALL=C tr -c 'A-Za-z0-9._ -' '-' | cut -c1-60)"
    if [ "$require_rc" = "1" ]; then
      note "Remote Control REQUIRED: full eligibility can't be confirmed until run; runner will abort if RC can't establish."
    else
      note "warning: Remote Control eligibility (claude.ai login, workspace trust, mobile push) is only fully verifiable at run time."
    fi
  else
    if [ "${OPT_REQUIRE_RC:-0}" = "1" ]; then
      die "--require-remote-control is only meaningful with --rc."
    fi
  fi

  local mode="${OPT_MODE:-interactive}"
  case "$mode" in interactive|unattended) : ;; *) die "invalid --mode: $mode" ;; esac
  local prompt="${OPT_PROMPT:-$DEFAULT_PROMPT}"

  # Build label + file paths.
  local sid_short epoch label
  sid_short="$(sanitize "$session_id" | cut -c1-8)"
  epoch="$(date +%s)"
  label="com.$(sanitize "$USER_NAME").claude-resume.$sid_short.$epoch"
  local job_json="$JOBS_DIR/$label.json"
  local settings_file=""
  [ "$rc" = "1" ] && settings_file="$JOBS_DIR/$label-settings.json"
  local launch_script="$JOBS_DIR/$label-launch.sh"
  local plist="$LA_DIR/$label.plist"
  local log_file="$LOGS_DIR/$label.log"

  # ---- dry-run stops here (1-4 done, nothing persisted) ----
  if [ "$dry" = "1" ]; then
    note "DRY RUN — resolved, validated, nothing persisted:"
    note "  session:    $session_name  ($session_id)"
    note "  state file: $state_file"
    note "  cwd:        $cwd"
    note "  5h used:    ${five_pct}%   resets_at: $resets_at"
    note "  fire_at:    ~$(eta_text "$fire_at")   (margin ${MARGIN_SECONDS}s)"
    note "  mode:       $mode    rc:$rc require_rc:$require_rc"
    [ "$rc" = "1" ] && note "  rc_name:    $rc_name"
    note "  claude_bin: $claude_bin"
    note "  would-be label: $label"
    [ -n "$dup" ] && note "  NOTE: a job already exists for this session ($dup); arm would need --force."
    return 0
  fi

  # 5. Snapshot immutable job file (chmod 600).
  RC="$rc" REQUIRE_RC="$require_rc" "$PY" - "$job_json" <<PY
import json, os, sys
job = {
    "label": "$label",
    "claude_bin": "$claude_bin",
    "caffeinate_bin": "/usr/bin/caffeinate",
    "osascript_bin": "/usr/bin/osascript",
    "session_id": "$session_id",
    "session_name": $(printf '%s' "$session_name" | "$PY" -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
    "cwd": $(printf '%s' "$cwd" | "$PY" -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
    "resets_at": float("$resets_at"),
    "fire_at": int("$fire_at"),
    "mode": "$mode",
    "prompt": $(printf '%s' "$prompt" | "$PY" -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
    "rc": os.environ["RC"] == "1",
    "rc_name": $(printf '%s' "$rc_name" | "$PY" -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
    "require_rc": os.environ["REQUIRE_RC"] == "1",
    "settings_file": "$settings_file",
    "launch_script": "$launch_script",
    "plist_path": "$plist",
    "log_file": "$log_file",
    "jobs_dir": "$JOBS_DIR",
    "domain": "$DOMAIN",
    "armed_at": int("$epoch"),
    "probe": {"timeout_s": 60, "fivehr_interval_s": 300, "fivehr_max_s": 1800,
              "net_retries": 3, "net_interval_s": 20},
}
with open(sys.argv[1], "w") as f:
    json.dump(job, f, indent=2)
    f.write("\n")
PY
  chmod 600 "$job_json" 2>/dev/null || true

  # Per-run push settings file ONLY with --rc (push has no effect without RC).
  if [ "$rc" = "1" ]; then
    "$PY" - "$settings_file" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    json.dump({"agentPushNotifEnabled": True, "inputNeededNotifEnabled": True}, f, indent=2)
    f.write("\n")
PY
    chmod 600 "$settings_file" 2>/dev/null || true
  fi

  # 6. Schedule one-shot LaunchAgent.
  local fire_eff
  fire_eff="$(write_plist_and_get_fire "$plist" "$label" "$job_json" "$log_file" "$fire_at")" \
    || die "failed to write plist"
  # Re-write fire_at in snapshot to the effective (minute-rounded) value.
  FE="$fire_eff" "$PY" - "$job_json" <<'PY'
import json, os, sys
with open(sys.argv[1]) as f: j = json.load(f)
j["fire_at"] = int(os.environ["FE"])
with open(sys.argv[1], "w") as f:
    json.dump(j, f, indent=2); f.write("\n")
PY

  /bin/launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
  if ! /bin/launchctl bootstrap "$DOMAIN" "$plist" 2>/tmp/.resume-bootstrap.$$; then
    local berr; berr="$(cat /tmp/.resume-bootstrap.$$ 2>/dev/null)"; rm -f /tmp/.resume-bootstrap.$$
    rm -f "$plist" "$job_json" "$settings_file" 2>/dev/null
    die "launchctl bootstrap failed: $berr"
  fi
  rm -f /tmp/.resume-bootstrap.$$ 2>/dev/null || true

  # 7. Armed summary.
  note "ARMED: $session_name"
  note "  session:  $session_id"
  note "  cwd:      $cwd"
  note "  fires:    $(eta_text "$fire_eff")"
  note "  mode:     $mode    Remote Control: $( [ "$rc" = 1 ] && echo "ON ($rc_name)" || echo OFF )"
  [ "$rc" = "1" ] && note "  push:     enabled per-run via $settings_file"
  note "  label:    $label"
  note "  log:      $log_file"
  note "  cancel:   $SELF --cancel $label"
}

# ---- status ------------------------------------------------------------------
cmd_status() {
  note "== Auto-resume status =="
  if is_capture_installed; then
    note "capture wrapper: INSTALLED"
  else
    note "capture wrapper: not installed"
  fi
  note "statusLine.command: $(json_statusline_command)"
  if [ -f "$INSTALL_META" ]; then
    note "snapshotted prev command: $(json_get "$INSTALL_META" statusline_command_prev)"
    if [ "$(json_get "$INSTALL_META" alias_installed)" = "True" ]; then
      note "shell alias: $(json_get "$INSTALL_META" alias_name) (in $ZSHRC)"
    else
      note "shell alias: not installed (add with: $SELF --install-alias)"
    fi
  fi
  local n=0
  if [ -d "$STATE_DIR" ]; then n="$(ls -1 "$STATE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"; fi
  note "captured sessions (resume-state): $n"
  note ""
  note "Armed jobs:"
  local found=0 f
  if [ -d "$JOBS_DIR" ]; then
    for f in "$JOBS_DIR"/*.json; do
      case "$f" in *-settings.json) continue ;; esac
      [ -f "$f" ] || continue
      found=1
      local label fire sess cwd mode rc loaded
      label="$(json_get "$f" label)"
      fire="$(json_get "$f" fire_at)"
      sess="$(json_get "$f" session_name)"
      cwd="$(json_get "$f" cwd)"
      mode="$(json_get "$f" mode)"
      rc="$(json_get "$f" rc)"
      if /bin/launchctl print "$DOMAIN/$label" >/dev/null 2>&1; then loaded="loaded"; else loaded="NOT loaded"; fi
      note "  • $sess  [$mode rc=$rc] ($loaded)"
      note "      dir:   $cwd"
      note "      fires: $(eta_text "$fire")"
      note "      label: $label"
    done
  fi
  [ "$found" = "0" ] && note "  (none)"
}

# ---- cancel ------------------------------------------------------------------
cancel_one() {
  local label="$1"
  /bin/launchctl bootout "$DOMAIN/$label" >/dev/null 2>&1 || true
  rm -f "$LA_DIR/$label.plist" "$JOBS_DIR/$label.json" \
        "$JOBS_DIR/$label-settings.json" "$JOBS_DIR/$label-launch.sh" 2>/dev/null || true
  note "cancelled: $label (log kept at $LOGS_DIR/$label.log if any)"
}

cmd_cancel() {
  local target="${1:-all}"
  if [ "$target" = "all" ] || [ -z "$target" ]; then
    local any=0 f
    for f in "$JOBS_DIR"/*.json; do
      case "$f" in *-settings.json) continue ;; esac
      [ -f "$f" ] || continue
      any=1
      cancel_one "$(json_get "$f" label)"
    done
    [ "$any" = "0" ] && note "no armed jobs to cancel."
  else
    cancel_one "$target"
  fi
}

# ---- test-terminal -----------------------------------------------------------
cmd_test_terminal() {
  ensure_dirs
  local dummy="$JOBS_DIR/.test-terminal-launch.sh"
  cat > "$dummy" <<'EOF'
#!/bin/bash
echo "[claude auto-resume] Terminal automation test OK — you can close this window."
echo "If you saw a macOS prompt to control Terminal, click Allow/OK."
sleep 2
EOF
  chmod 700 "$dummy"
  note "Running the EXACT production Terminal-automation path with a dummy launcher."
  note "If macOS prompts to allow controlling Terminal, click Allow/OK."
  /usr/bin/osascript <<APPLESCRIPT
set p to "$dummy"
tell application "Terminal"
    do script (quoted form of p)
    activate
end tell
APPLESCRIPT
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    note "osascript succeeded (rc=0). Automation grant should now be in place."
  else
    note "osascript returned rc=$rc — if you were prompted, grant it and re-run --test-terminal."
  fi
  ( sleep 5; rm -f "$dummy" ) >/dev/null 2>&1 &
  return "$rc"
}

# ---- install-alias / uninstall-alias -----------------------------------------
update_alias_meta() {
  # $1 = installed ("true"|"false")   $2 = alias name (may be empty)
  [ -f "$INSTALL_META" ] || return 0
  AL_INSTALLED="$1" AL_NAME="$2" "$PY" - "$INSTALL_META" <<'PY'
import json, os, sys
with open(sys.argv[1]) as f: j = json.load(f)
j["alias_installed"] = (os.environ["AL_INSTALLED"] == "true")
j["alias_name"] = os.environ["AL_NAME"]
with open(sys.argv[1], "w") as f:
    json.dump(j, f, indent=2); f.write("\n")
PY
}

cmd_install_alias() {
  # $1 = optional alias name (default: auto-resume). Pass-through: the alias
  # forwards ALL args to this script, so `<name> --uninstall`, `<name> --status`,
  # etc. all work.
  local name clean
  name="${1:-$DEFAULT_ALIAS_NAME}"
  clean="$(printf '%s' "$name" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')"
  [ -n "$clean" ] || die "invalid alias name: '$name'"
  name="$clean"

  # Idempotent: our marker block already present.
  if [ -f "$ZSHRC" ] && grep -qF "$ALIAS_BEGIN" "$ZSHRC" 2>/dev/null; then
    local cur
    cur="$(json_get "$INSTALL_META" alias_name)"
    [ -n "$cur" ] || cur="(see $ZSHRC)"
    note "alias already installed ($cur) in $ZSHRC."
    note "To change it: '$SELF --uninstall-alias' then '$SELF --install-alias <name>'."
    return 0
  fi

  # Collision guard — don't shadow an existing command/alias/function.
  if [ "${OPT_FORCE:-0}" != "1" ]; then
    local clash=""
    if command -v "$name" >/dev/null 2>&1; then
      clash="an existing command/builtin on PATH"
    elif grep -qE "^[[:space:]]*(alias[[:space:]]+$name=|(function[[:space:]]+)?$name[[:space:]]*\(\))" \
            "$ZSHRC" "$ZPROFILE" 2>/dev/null; then
      clash="an existing alias/function in your shell rc files"
    fi
    if [ -n "$clash" ]; then
      die "'$name' is already $clash. Choose another (--install-alias <name>) or use --force to override."
    fi
  fi

  {
    printf '%s\n' "$ALIAS_BEGIN"
    printf 'alias %s=%s\n' "$name" "\"$SELF\""
    printf '%s\n' "$ALIAS_END"
  } >> "$ZSHRC"
  note "added '$name' alias to $ZSHRC (open a new shell or: source ~/.zshrc)"
  note "  usage:  $name   |   $name --uninstall   |   $name --status   |   $name --cancel all"
  update_alias_meta true "$name"
}

cmd_uninstall_alias() {
  if [ -f "$ZSHRC" ] && grep -qF "$ALIAS_BEGIN" "$ZSHRC" 2>/dev/null; then
    local cur
    cur="$(json_get "$INSTALL_META" alias_name)"
    remove_alias_block
    update_alias_meta false ""
    note "Removed the auto-resume shell alias${cur:+ ($cur)}; the feature itself is untouched."
    note "It stays defined in your CURRENT shell until you open a new one${cur:+ (or: unalias $cur)}."
  else
    note "no auto-resume alias block found in $ZSHRC (nothing to remove)."
  fi
}

remove_alias_block() {
  [ -f "$ZSHRC" ] || return 0
  grep -qF "$ALIAS_BEGIN" "$ZSHRC" 2>/dev/null || return 0
  BEGIN="$ALIAS_BEGIN" END="$ALIAS_END" "$PY" - "$ZSHRC" <<'PY'
import os, sys
path = sys.argv[1]
b, e = os.environ["BEGIN"], os.environ["END"]
with open(path) as f:
    lines = f.readlines()
out, skip = [], False
for ln in lines:
    if ln.strip() == b: skip = True; continue
    if ln.strip() == e: skip = False; continue
    if not skip: out.append(ln)
with open(path, "w") as f:
    f.writelines(out)
PY
  note "removed alias block from $ZSHRC"
}

# ---- uninstall ---------------------------------------------------------------
cmd_uninstall() {
  note "Uninstalling auto-resume (full revert)…"

  # Cancel/bootout all jobs.
  cmd_cancel all

  # Restore statusLine.command to the snapshotted install-time value.
  if [ -f "$INSTALL_META" ]; then
    local prev
    prev="$(json_get "$INSTALL_META" statusline_command_prev)"
    if [ -n "$prev" ] && [ -f "$SETTINGS" ]; then
      PREV="$prev" "$PY" - "$SETTINGS" <<'PY' && note "restored statusLine.command -> $prev"
import json, os, sys
path = sys.argv[1]
with open(path) as f: j = json.load(f)
sl = j.get("statusLine")
if isinstance(sl, dict):
    sl["command"] = os.environ["PREV"]
with open(path, "w") as f:
    json.dump(j, f, indent=2); f.write("\n")
PY
    fi
    if [ "$(json_get "$INSTALL_META" alias_installed)" = "True" ]; then
      remove_alias_block
    fi
  else
    note "warning: no install metadata; if the bar was repointed, restore statusLine.command manually."
  fi

  # Remove artifacts (never touch statusline.sh or other settings keys).
  # Full revert / zero residue: this also removes resume-logs/ (per §Safety).
  rm -f "$WRAPPER" 2>/dev/null || true
  rm -rf "$STATE_DIR" "$JOBS_DIR" "$LOGS_DIR" 2>/dev/null || true
  rm -f "$INSTALL_META" "$SETTINGS_BAK" 2>/dev/null || true
  # Remove any stray plists belonging to us.
  ls "$LA_DIR"/com."$(sanitize "$USER_NAME")".claude-resume.*.plist >/dev/null 2>&1 && \
    rm -f "$LA_DIR"/com."$(sanitize "$USER_NAME")".claude-resume.*.plist 2>/dev/null || true

  note "Removed: wrapper, resume-state/, resume-jobs/, resume-logs/, plists, install metadata."
  note "Kept: nothing. statusline.sh and all other settings keys untouched."
  note "Removing runner + controller (self) last…"
  rm -f "$RUNNER" 2>/dev/null || true
  rm -f "$SELF" 2>/dev/null || true
  note "Done. Auto-resume fully reverted."
}

# ---- arg parsing -------------------------------------------------------------
usage() {
  sed -n '2,40p' "$SELF" 2>/dev/null | sed 's/^# \{0,1\}//'
}

ACTION="arm"
OPT_MODE=""; OPT_DIR=""; OPT_SESSION_ID=""; OPT_RC=0; OPT_RC_NAME=""
OPT_REQUIRE_RC=0; OPT_FORCE=0; OPT_PROMPT=""; OPT_CLAUDE_BIN=""
CANCEL_TARGET=""; ALIAS_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    arm) ACTION="arm" ;;
    --status|status) ACTION="status" ;;
    --dry-run|dry-run) ACTION="dry-run" ;;
    --install|install) ACTION="install" ;;
    --uninstall|uninstall) ACTION="uninstall" ;;
    --install-alias|install-alias)
      ACTION="install-alias"
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then ALIAS_NAME="$2"; shift; fi ;;
    --uninstall-alias|uninstall-alias) ACTION="uninstall-alias" ;;
    --test-terminal|test-terminal) ACTION="test-terminal" ;;
    --cancel|cancel)
      ACTION="cancel"
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then CANCEL_TARGET="$2"; shift; fi ;;
    --mode) shift; OPT_MODE="${1:-}" ;;
    --dir) shift; OPT_DIR="${1:-}" ;;
    --session-id) shift; OPT_SESSION_ID="${1:-}" ;;
    --remote-control|--rc)
      OPT_RC=1
      if [ $# -gt 1 ] && [ "${2#-}" = "$2" ]; then OPT_RC_NAME="$2"; shift; fi ;;
    --require-remote-control) OPT_REQUIRE_RC=1 ;;
    --force) OPT_FORCE=1 ;;
    --prompt) shift; OPT_PROMPT="${1:-}" ;;
    --claude-bin) shift; OPT_CLAUDE_BIN="${1:-}" ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

case "$ACTION" in
  arm)            do_arm 0 ;;
  dry-run)        do_arm 1 ;;
  install)        cmd_install ;;
  uninstall)      cmd_uninstall ;;
  status)         cmd_status ;;
  cancel)         cmd_cancel "$CANCEL_TARGET" ;;
  install-alias)  cmd_install_alias "$ALIAS_NAME" ;;
  uninstall-alias) cmd_uninstall_alias ;;
  test-terminal)  cmd_test_terminal ;;
  *)              usage; exit 1 ;;
esac
