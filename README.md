# Claude Auto Resume (macOS)

**Automatically resume a Claude Code session after the 5‑hour usage limit resets** — pick up the
exact same conversation, in a Terminal you can watch, without babysitting the clock.

Claude Code has no built‑in auto‑resume after a 5‑hour limit
([#36320](https://github.com/anthropics/claude-code/issues/36320),
[#35744](https://github.com/anthropics/claude-code/issues/35744),
[#18980](https://github.com/anthropics/claude-code/issues/18980)). This is a small, auditable,
**user‑scoped** scheduler built around the official `claude` CLI and native macOS tools
(`launchd`, `caffeinate`, `osascript`). No `sudo`, no system changes, no network calls of its own,
fully reversible. See **[SECURITY.md](SECURITY.md)**.

---

## What it does

1. A thin **pass‑through wrapper** sits in front of your Claude Code status line and quietly records
   each session's 5‑hour reset time locally (it changes *nothing* about how your status bar looks).
2. When a session stops on the 5‑hour limit, you **arm** it: `auto-resume` (from that project dir).
3. A one‑shot `launchd` job waits until the window resets, runs a tiny **probe** to confirm the
   limit actually cleared, then **resumes the exact session** in a Terminal — wrapped in
   `caffeinate` so your Mac won't idle‑sleep mid‑run — using `--permission-mode auto`
   (**never** `bypassPermissions`).
4. You get a macOS notification, and the job cleans itself up.

Optional: add `--rc` when arming to also turn on **Remote Control + push** so you can check in from
the Claude mobile app (OFF by default).

> **Scope:** arming is **per‑session and manual**. The `auto-resume` command does nothing on its own
> — it only arms the one session you run it on.

---

## Requirements

- **macOS** (uses `launchd`, `caffeinate`, `osascript`; ships `python3` + `perl`).
- **Claude Code** installed and logged in via claude.ai (`claude auth status`). Resume works on any
  recent version; **Remote Control needs `claude` ≥ 2.1.51**.
- A Claude Code **status line** is the data source. If you don't have one, the installer drops in a
  small bundled status‑line tracker for you (you can remove it on uninstall).
- For `--rc` push: the **Claude mobile app**, signed in.

---

## Install

### Recommended: clone, read the code, then install
```bash
git clone https://github.com/HiperKinetic-ai/claude-auto-resume-macos.git
cd claude-auto-resume-macos
less install.sh        # review it — it's short and plain bash
./install.sh           # add --no-alias to skip the shell alias
```

### One‑liner (convenience)
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/HiperKinetic-ai/claude-auto-resume-macos/main/install.sh)"
```
This downloads `install.sh`, which then `git clone`s `HiperKinetic-ai/claude-auto-resume-macos` and
runs itself. Piping a script from the internet into a shell runs code you haven't read — prefer the
clone‑and‑review method, and **pin a tag** (replace `main` with a release tag) so you get a fixed,
known version. See [SECURITY.md](SECURITY.md).

The installer: copies the scripts into `~/.claude/`, wraps your existing status line (or installs the
bundled one if you have none — the **only** `settings.json` change is `statusLine.command`), and adds
the `auto-resume` shell alias. It never touches system files and asks for no elevated privileges.

After installing:
```bash
# open a new terminal (so the alias loads), then once:
auto-resume --test-terminal     # grant the one-time macOS "control Terminal" prompt
```

---

## Usage

> ⚠️ **Run `auto-resume` in a terminal — not in the Claude Code prompt.** It's a shell command, not a
> Claude Code command. If you type it into Claude Code (e.g. right when you've hit the limit), it's
> just sent to Claude as a message and does nothing. Either open a separate terminal and `cd` to your
> project, **or** from inside Claude Code run `! ~/.claude/resume-at-reset.sh` — the `!` prefix runs a
> local shell command (no API call, so it works even while you're rate‑limited) in the session's own
> directory.

```bash
auto-resume                 # arm the current project's most-recent session (after a 5h stop)
auto-resume --rc            # same, but also enable Remote Control + push (phone reachable)
auto-resume --dry-run       # show what WOULD be armed; persist nothing
auto-resume --status        # what's installed / armed
auto-resume --cancel all    # un-arm scheduled resumes (removes nothing else)
auto-resume --test-terminal # exercise the Terminal-automation path (one-time TCC grant)
auto-resume --uninstall     # full revert (or ./uninstall.sh)
```

`auto-resume` is a pass‑through alias for `~/.claude/resume-at-reset.sh`, so every flag above is just
forwarded. Full reference: **[docs/USAGE.md](docs/USAGE.md)**.

---

## How it works (short version)

```
status-line wrapper records reset time  →  you `auto-resume` (arm a session)
   →  launchd waits until reset + margin  →  bounded probe confirms the limit cleared
   →  caffeinate-wrapped `claude --resume <id> --permission-mode auto` in Terminal
   →  macOS notification  →  job self-cleans
```

The probe classifies the result: 5‑hour still active → back off and retry; **weekly** limit →
notify and stop (no auto‑resume); auth/network problem → notify the specific cause and stop. Details
and the failure/fallback behavior: **[docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md)**.

---

## Uninstall

```bash
./uninstall.sh                  # restores your status line; removes all auto-resume files + the alias
./uninstall.sh --remove-tracker # also remove the bundled status line, IF this package installed it
```
Uninstall restores `settings.json` `statusLine.command` to exactly its pre‑install value and removes
everything else — **zero residue**. Your original status line is untouched.

---

## Troubleshooting

- **`auto-resume: command not found`** → open a new terminal, or `source ~/.zshrc`. The alias is
  added to `~/.zshrc` (only if the name was free; it won't shadow an existing command).
- **The scheduled resume opened no Terminal** → the first `launchd` fire may hit a one‑time macOS
  Automation prompt. Granting it once (or running `auto-resume --test-terminal`) fixes future fires.
  If it isn't granted in time, you get a notification and the ready‑to‑run launcher is kept (it never
  silently double‑runs). For fully hands‑off resumes use `auto-resume --mode unattended`.
- **Mac asleep at reset** → `launchd` fires on the next wake (a bit late; self‑heals).
- **Weekly limit hit** → not auto‑resumed by design; you're notified to resume after the weekly reset.

---

## Notes

- If you **fork** this repo, update `REPO_URL`/`REF` at the top of `install.sh` (or pass
  `--repo`/`--ref`, or set `CAR_REPO_URL`/`CAR_REF`) so the one‑liner points at your fork. Nothing
  else depends on the repo or folder name.
- Auto mode and Remote Control are Anthropic **research previews**; behavior may change.

## License

[MIT](LICENSE).
