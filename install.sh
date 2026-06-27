#!/bin/bash
# install.sh — installer for "Claude Auto Resume (MacOS)".
#
# Installs the 5-hour auto-resume feature into your user account (~/.claude):
#   • copies the scripts, wires the status-line capture wrapper (the ONLY
#     settings.json change), and adds the `auto-resume` shell alias.
# Everything is user-scoped — NO sudo, NO system files, fully reversible with
# ./uninstall.sh (or `auto-resume --uninstall`). See SECURITY.md.
#
# Two ways to run:
#   1. (recommended) clone the repo, read the code, then:  ./install.sh
#   2. one-liner:  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/HiperKinetic-ai/claude-auto-resume-macos/main/install.sh)"
#      (downloads this file, which then git-clones the repo and re-runs itself)
#
# Flags:
#   --no-alias   don't add the `auto-resume` shell alias
#   --ref <ref>  git ref (branch/tag) to bootstrap from (default: main)
#   --repo <url> git repo URL to bootstrap from (override REPO_URL)
#   -h|--help    show this header

set -u

# ---- Config (override with --repo/--ref or CAR_REPO_URL/CAR_REF env vars) -----
REPO_URL="${CAR_REPO_URL:-https://github.com/HiperKinetic-ai/claude-auto-resume-macos.git}"
REF="${CAR_REF:-main}"

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
TRACKER_MARKER="$CLAUDE_DIR/.resume-pkg-tracker"
PY=/usr/bin/python3
CORE_SCRIPTS="statusline-capture.sh resume-at-reset.sh claude-resume-run.sh"

INSTALL_ALIAS=1

err()  { printf 'install: error: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
note() { printf '%s\n' "$*"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

# ---- Parse args --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --no-alias) INSTALL_ALIAS=0 ;;
    --ref) shift; REF="${1:-main}" ;;
    --repo) shift; REPO_URL="${1:-$REPO_URL}" ;;
    -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]:-$0}" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

# ---- Locate ourselves / bootstrap when piped via curl ------------------------
SELF_SRC="${BASH_SOURCE[0]:-$0}"
if [ -f "$SELF_SRC" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$SELF_SRC")" && pwd)"
else
  SCRIPT_DIR=""
fi

bootstrap() {
  command -v git >/dev/null 2>&1 || die "this one-liner needs 'git'. Install Xcode Command Line Tools (xcode-select --install) or clone the repo and run ./install.sh."
  case "$REPO_URL" in
    *REPLACE_ME*) die "REPO_URL is not set. Either run from a clone (./install.sh) or pass --repo <url> (publisher: edit REPO_URL in install.sh)." ;;
  esac
  local tmp
  tmp="$(mktemp -d)" || die "could not create temp dir"
  note "Fetching $REPO_URL ($REF) ..."
  if ! git clone --depth 1 --branch "$REF" "$REPO_URL" "$tmp/repo" >/dev/null 2>&1; then
    git clone --depth 1 "$REPO_URL" "$tmp/repo" >/dev/null 2>&1 || die "git clone failed ($REPO_URL)"
  fi
  [ -f "$tmp/repo/install.sh" ] || die "cloned repo has no install.sh at its root"
  local pass=""
  [ "$INSTALL_ALIAS" = "0" ] && pass="--no-alias"
  exec /bin/bash "$tmp/repo/install.sh" $pass
}

if [ -z "$SCRIPT_DIR" ] || [ ! -f "$SCRIPT_DIR/src/statusline-capture.sh" ]; then
  note "No local src/ found — bootstrapping from GitHub."
  bootstrap
fi
SRC="$SCRIPT_DIR/src"

# ---- Preflight ---------------------------------------------------------------
hr; note "Claude Auto Resume — installer"; hr
[ "$(uname -s)" = "Darwin" ] || die "this tool is macOS-only (uses launchd, caffeinate, osascript)."
[ -x "$PY" ] || die "python3 not found at $PY (expected on macOS)."
command -v perl >/dev/null 2>&1 || die "perl not found (expected on macOS; used for the bounded probe)."

if command -v claude >/dev/null 2>&1; then
  ver="$(claude --version 2>/dev/null | head -1)"
  note "• claude CLI: ${ver:-found}"
  "$PY" - "$ver" <<'PY' || note "  warning: could not confirm claude >= 2.1.51 (Remote Control needs it; resume works regardless)."
import sys
def parse(v):
    out=[]
    for p in v.strip().split()[0].split(".") if v.strip() else []:
        d="".join(c for c in p if c.isdigit()); out.append(int(d) if d else 0)
    return out
h=parse(sys.argv[1]) if len(sys.argv)>1 else []
m=[2,1,51]; n=max(len(h),len(m)); h+=[0]*(n-len(h)); m+=[0]*(n-len(m))
sys.exit(0 if h>=m else 1)
PY
else
  note "• claude CLI: NOT on PATH — install Claude Code first (https://claude.com/claude-code). Continuing; arming will require it."
fi

mkdir -p "$CLAUDE_DIR" || die "could not create $CLAUDE_DIR"

# ---- Copy core scripts (back up any pre-existing, different file) ------------
ts="$(date +%s)"
for f in $CORE_SCRIPTS; do
  src="$SRC/$f"; dst="$CLAUDE_DIR/$f"
  [ -f "$src" ] || die "missing packaged file: $src"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    cp "$dst" "$dst.bak-$ts" && note "• backed up existing $f -> $f.bak-$ts"
  fi
  cp "$src" "$dst" && chmod 755 "$dst"
done
note "• installed scripts into $CLAUDE_DIR"

# ---- Ensure a status line exists, then let --install wrap it -----------------
cur_cmd="$("$PY" - "$SETTINGS" <<'PY'
import json,sys
try:
    j=json.load(open(sys.argv[1])); print((j.get("statusLine") or {}).get("command","") or "")
except Exception:
    print("")
PY
)"

if [ -n "$cur_cmd" ]; then
  case "$cur_cmd" in
    *statusline-capture.sh) note "• capture wrapper already in place — refreshing scripts" ;;
    *) note "• existing status line detected — it will be wrapped (preserved): $cur_cmd" ;;
  esac
else
  note "• no status line configured — installing the bundled tracker (statusline.sh)"
  cp "$SRC/statusline.sh" "$CLAUDE_DIR/statusline.sh" && chmod 755 "$CLAUDE_DIR/statusline.sh"
  "$PY" - "$SETTINGS" <<'PY' || die "could not update settings.json"
import json,os,sys
p=sys.argv[1]
try: j=json.load(open(p))
except Exception: j={}
sl=j.get("statusLine")
if not isinstance(sl,dict): sl={"type":"command","padding":0,"refreshInterval":60}
sl["command"]="~/.claude/statusline.sh"
j["statusLine"]=sl
with open(p,"w") as f: json.dump(j,f,indent=2); f.write("\n")
PY
  : > "$TRACKER_MARKER"   # remember we installed the tracker (for clean removal)
  note "  set statusLine.command -> ~/.claude/statusline.sh"
fi

# ---- Install (snapshot prev command -> repoint to wrapper) -------------------
hr
"$CLAUDE_DIR/resume-at-reset.sh" --install || die "resume-at-reset.sh --install failed"

# ---- Shell alias -------------------------------------------------------------
if [ "$INSTALL_ALIAS" = "1" ]; then
  "$CLAUDE_DIR/resume-at-reset.sh" --install-alias || note "warning: alias install reported an issue (see above)."
fi

# ---- Next steps --------------------------------------------------------------
hr
note "Done. Next steps:"
note "  1) Open a NEW terminal (or: source ~/.zshrc) so the 'auto-resume' command loads."
note "  2) Grant the one-time macOS Automation prompt:   auto-resume --test-terminal"
note "  3) When a session hits the 5-hour limit, from that project dir run:   auto-resume"
note "     (add --rc for phone reachability via Remote Control + push; OFF by default)"
note ""
note "  Status:    auto-resume --status"
note "  Uninstall: ./uninstall.sh        (or: auto-resume --uninstall)"
hr
