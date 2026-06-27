# Security

This document explains exactly what Claude Auto Resume does to your machine, why it's safe, and what
to check if you want to verify that for yourself. The short version: it is small, plain‑text, runs
**entirely in your own user account**, makes **no network calls of its own**, collects **no data**,
and is **fully reversible**.

## TL;DR

| Concern | This tool |
| --- | --- |
| Elevated privileges | **None.** No `sudo`, no root, no system files. Everything lives in `~/.claude` and `~/Library/LaunchAgents`. |
| Network / telemetry | **None from this tool.** The only thing that talks to Anthropic is your own `claude` CLI — exactly as it already does. No analytics, no phone‑home, no third‑party servers. |
| Permissions when it resumes | `--permission-mode auto` (research preview, with background safety checks). **Never** `bypassPermissions`. |
| Remote Control / push | **OFF by default.** Opt in per‑arm with `--rc`. |
| Data stored | Local only, `chmod 600`, pruned after 24h: session id, working dir, reset timestamps. **Never conversation content.** |
| Reversibility | One command (`./uninstall.sh` / `auto-resume --uninstall`) restores your status line and removes everything. |
| Auditability | ~4 short shell/Python files, no obfuscation, no compiled binaries, no `curl \| bash` inside the scripts. |

## What it changes on your system

1. **Files in `~/.claude/`:** `statusline-capture.sh`, `resume-at-reset.sh`, `claude-resume-run.sh`
   (and, only if you had no status line, a bundled `statusline.sh`). Plus runtime dirs
   `resume-state/`, `resume-jobs/`, `resume-logs/` and a small `resume-install.json` snapshot.
2. **Exactly one `settings.json` key:** `statusLine.command` is repointed to the capture wrapper.
   The prior value is snapshotted and restored on uninstall. No other key is touched.
3. **One line in `~/.zshrc`** (only if you let it add the `auto-resume` alias), inside clearly marked
   `# >>> claude-auto-resume alias >>>` … `# <<< … <<<` markers, and only if the name was free.
4. **A one‑shot LaunchAgent** in `~/Library/LaunchAgents/` *only while a resume is armed.* It is
   user‑scoped (`gui/<uid>` domain), runs once at the reset time, and **removes itself** after firing.

That's the complete footprint. There are no kernel extensions, no daemons running as root, no login
items beyond the transient one‑shot agent, and no changes outside your home directory.

## Why each component is safe

- **The status‑line wrapper (`statusline-capture.sh`)** reads the JSON that Claude Code already pipes
  to your status line, writes a tiny local state file best‑effort (all errors swallowed), then runs
  your *real* status‑line command with the exact same bytes and passes its output/exit code through
  unchanged. It cannot break or alter your status bar, and it sends nothing anywhere.
- **The probe** is a single, time‑bounded `claude -p` call (`--no-session-persistence`) that just asks
  the model to reply "ok" so we can tell whether the limit actually reset. It's the same CLI you
  already use; it persists nothing.
- **`caffeinate`** only asserts "don't idle‑sleep" for the lifetime of the resumed process. It grants
  no permissions and changes no settings.
- **`osascript`** is used solely to open **Terminal** and run the resume launcher, and only after you
  grant the standard one‑time macOS Automation consent. It controls nothing else.
- **`launchd`** schedules the one‑shot resume at the reset time; the job self‑removes after it runs.

## Data & privacy

The only data written is `~/.claude/resume-state/<session_id>.json` and a per‑job snapshot, containing
the **session id, working directory, and 5‑hour/weekly reset timestamps** — never message content.
All such files are `chmod 600` (owner‑only) and pruned after 24 hours. Nothing is uploaded; nothing
leaves your machine because of this tool.

## Install methods & the `curl | bash` trade‑off

The **recommended** install is to clone the repo, read `install.sh` (it's short, plain bash), and run
it. A one‑liner that pipes `curl | bash` is provided for convenience, but it runs code you haven't
read at that moment. If you use it:

- **Read `install.sh` first** (e.g. open it on GitHub), and
- **Pin a tag/commit** instead of `main` so you get a fixed, reviewed version.

The installer itself uses `git clone` to fetch a pinned ref — it does not pipe anything into a shell.

## What to review before trusting it

- `src/statusline-capture.sh` — confirm it only side‑writes local state and passes your status line
  through unchanged.
- `src/claude-resume-run.sh` — confirm the resume command is `--permission-mode auto` (not
  `bypassPermissions`), that Remote Control flags appear **only** when you armed `--rc`, and that the
  probe is bounded.
- `src/resume-at-reset.sh` — confirm the only `settings.json` change is `statusLine.command`, the
  `~/.zshrc` edit is marker‑wrapped and opt‑in, and `--uninstall` restores everything.
- `install.sh` / `uninstall.sh` — no `sudo`, user‑scoped paths only.

## Reporting issues

This is a personal utility shared as‑is. If you find a security problem, please open an issue (or a
private report if your platform supports it) describing the impact and a reproduction.
