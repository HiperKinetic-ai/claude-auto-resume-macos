#!/bin/bash
# uninstall.sh — full revert for "Claude Auto Resume (MacOS)".
#
# Calls the controller's own --uninstall (restores settings.json statusLine.command
# to its pre-install value and removes the wrapper, scripts, state/jobs/logs/plists,
# and the `auto-resume` alias). Leaves your original status line exactly as it was.
#
# Flags:
#   --remove-tracker   if THIS package installed the bundled statusline.sh (because
#                      you had no status line), also remove it and clear
#                      statusLine.command — i.e. revert fully to "no status line".
#   -h|--help          show this header

set -u

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
TRACKER_MARKER="$CLAUDE_DIR/.resume-pkg-tracker"
CONTROLLER="$CLAUDE_DIR/resume-at-reset.sh"
PY=/usr/bin/python3

REMOVE_TRACKER=0
note() { printf '%s\n' "$*"; }
die()  { printf 'uninstall: error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --remove-tracker) REMOVE_TRACKER=1 ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

if [ -x "$CONTROLLER" ]; then
  "$CONTROLLER" --uninstall || die "controller --uninstall failed"
else
  note "controller not found at $CONTROLLER — nothing to revert (already uninstalled?)."
fi

# Optional: also remove the tracker this package installed (revert to no status line).
if [ "$REMOVE_TRACKER" = "1" ]; then
  if [ -f "$TRACKER_MARKER" ]; then
    rm -f "$CLAUDE_DIR/statusline.sh"
    [ -f "$SETTINGS" ] && "$PY" - "$SETTINGS" <<'PY'
import json,sys
p=sys.argv[1]
try: j=json.load(open(p))
except Exception: j=None
if isinstance(j,dict) and isinstance(j.get("statusLine"),dict):
    j["statusLine"].pop("command",None)
    with open(p,"w") as f: json.dump(j,f,indent=2); f.write("\n")
PY
    rm -f "$TRACKER_MARKER"
    note "Removed the bundled tracker and cleared statusLine.command (reverted to no status line)."
  else
    note "No package-installed tracker marker found — leaving your status line untouched."
  fi
fi

note "Uninstall complete."
