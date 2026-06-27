# How it works

A walkthrough of the architecture and the runtime flow.

## Components

| File (installed to `~/.claude/`) | Role |
| --- | --- |
| `statusline-capture.sh` | Pass‑through wrapper around your status line. Records each session's reset time; runs your real status line unchanged. |
| `resume-at-reset.sh` | The controller you drive (via the `auto-resume` alias): arm / status / cancel / dry‑run / install / uninstall / install‑alias / test‑terminal. |
| `claude-resume-run.sh` | The `launchd` payload: probe → resume → notify → self‑clean. |
| `statusline.sh` | A status‑line tracker, installed **only** if you had none (the data source). |

Generated at runtime: `resume-state/<session_id>.json` (reset snapshots), `resume-jobs/<label>.json`
(immutable per‑job snapshot), `resume-logs/<label>.log`, a one‑shot `~/Library/LaunchAgents/<label>.plist`,
and `resume-install.json` (records the pre‑install `statusLine.command` for faithful uninstall).

## 1. Capture (no change to how your bar looks)

Claude Code feeds a JSON payload (session id, cwd, rate‑limit reset times, …) to your status‑line
command on every refresh. The wrapper:

1. Reads the **full** stdin payload into memory (stdin is consumed once read).
2. Best‑effort writes `resume-state/<session_id>.json` = `{session_id, session_name, cwd,
   five_hour_resets_at, five_hour_used_pct, seven_day_resets_at, updated_at}` (atomic, `chmod 600`,
   pruned after 24h). All errors are swallowed — capture never affects the bar.
3. Re‑feeds the **exact same bytes** to your *real* status‑line command (the value snapshotted at
   install; or the bundled `statusline.sh`) and passes its stdout, stderr, and exit code through
   unchanged.

Per‑session files mean that when several sessions are open, arming resolves the right one.

## 2. Arm (`auto-resume`)

From a project directory after a 5‑hour stop:

1. **Resolve** the newest `resume-state/*.json` whose `cwd` matches (or `--dir` / `--session-id`).
   No match → it fails with guidance (it never silently falls back to `--continue`).
2. **Validate** the 5‑hour reset is in the future; block a duplicate job for the same session unless
   `--force`.
3. **Preflight:** `claude` version, claude.ai login, tools resolvable, `launchd` loadable. With
   `--rc`, also checks Remote Control eligibility (fully confirmable only at run time).
4. **Snapshot** an immutable per‑job file with absolute tool paths (resolved now, so `launchd`'s
   minimal PATH doesn't matter), the session id, cwd, reset time, mode, prompt, and `--rc` settings.
   Push toggles are written to a per‑job settings file **only** when `--rc` is used.
5. **Schedule** a one‑shot LaunchAgent at *reset + margin* (default 120s) via `launchctl bootstrap`.

`--dry-run` does steps 1–3 and prints what would be armed without persisting anything.

## 3. Resume (`launchd` fires `claude-resume-run.sh`)

1. **Bounded probe** (macOS has no `timeout`, so a `perl alarm` bounds it):
   `claude -p --no-session-persistence --output-format json "Reply ok."`. The result is classified:
   - **success** → proceed.
   - **5‑hour limit still active** → back off (every 5 min, up to 30 min), then give up + notify.
   - **weekly limit** → notify and **stop** (not treated as 5‑hour).
   - **auth / network / other** → notify the specific cause and stop (network/timeouts get a few
     quick retries first).
2. **Resume**, caffeinate wrapping the actual `claude` process so idle‑sleep protection covers the
   whole session:
   - **Interactive (default):** writes a launcher and opens **Terminal** via `osascript` to run
     `caffeinate -i claude --resume <id> --permission-mode auto "<continue prompt>"`. With `--rc`,
     `--remote-control "<name>"` and `--settings <per-job push file>` are appended.
   - **Unattended (`--mode unattended`):** runs the same, headless, with `-p`, logging to the job log.
3. **Notify** (`osascript`) and **self‑clean**: delete the per‑job files and plist, `launchctl bootout`.

## Failure & safety behavior

- **Terminal automation blocked at fire time** (a `launchd`‑context macOS Automation/TCC prompt that
  isn't granted) → the `osascript` call is time‑bounded; on timeout the runner **does not** spawn an
  unattended resume (that could double‑resume the same session if macOS later honors the queued
  event). Instead it keeps the launcher and notifies you how to resume. Run `auto-resume
  --test-terminal` once to grant the prompt ahead of time.
- **`--require-remote-control`** (only valid with `--rc`) → if Remote Control can't establish, the
  job aborts loudly rather than resuming without phone reachability.
- **Mac asleep at reset** → `launchd` fires on the next wake (late, self‑heals).

## Reversibility

`resume-install.json` records the pre‑install `statusLine.command`. `--uninstall` restores exactly
that value, removes the wrapper, scripts, runtime dirs, plists, and the marker‑wrapped `~/.zshrc`
alias — leaving your status line and every other setting exactly as before.
