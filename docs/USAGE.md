# Usage reference

`auto-resume` is a pass‑through alias for `~/.claude/resume-at-reset.sh` — every command and flag
below works with either name. (If you skipped the alias, call the script directly.)

## Commands

| Command | What it does |
| --- | --- |
| `auto-resume` | **(default = arm)** Arm the newest captured session for the current directory to resume after its 5‑hour reset. |
| `auto-resume --dry-run` | Resolve + validate the target session and print what *would* be armed. Persists nothing. |
| `auto-resume --status` | Show install state (wrapper, status‑line command, alias) and any armed jobs with their fire times. |
| `auto-resume --cancel [label\|all]` | Un‑arm a specific job (by label) or all jobs. Removes only the schedule; keeps the feature installed. |
| `auto-resume --test-terminal` | Run the exact Terminal‑automation path with a harmless dummy launcher, to grant the one‑time macOS Automation (TCC) prompt. |
| `auto-resume --install` | (Re)install the capture wrapper: snapshot the current `statusLine.command` and repoint it to the wrapper. |
| `auto-resume --uninstall` | Full revert: restore `statusLine.command`, remove the wrapper, scripts, state/jobs/logs/plists, and the alias. |
| `auto-resume --install-alias [name]` | Add the pass‑through shell alias (default `auto-resume`) to `~/.zshrc`. Collision‑guarded; won't shadow an existing command. |
| `auto-resume --uninstall-alias` | Remove just the alias (leaves the feature installed). |

## Flags (for arm / `--dry-run`)

| Flag | Meaning |
| --- | --- |
| `--mode interactive\|unattended` | `interactive` (default): open a Terminal you can watch/steer. `unattended`: headless `-p`, logged to the job log; not phone‑reachable. |
| `--dir <path>` | Target project directory (default: current dir). |
| `--session-id <id>` | Arm a specific captured session instead of the newest for the directory. |
| `--remote-control [name]`, `--rc [name]` | Opt in to **Remote Control + push** on the resumed session (OFF by default). Optional display name. |
| `--require-remote-control` | Only meaningful with `--rc`: abort the resume if Remote Control can't establish (don't resume without phone reachability). |
| `--force` | Allow arming a second job for a session that's already armed. |
| `--prompt <text>` | Override the default "continue the work" prompt sent on resume. |
| `--claude-bin <path>` | Testing override for the `claude` binary (skips version/auth preflight). |

## Typical flows

**Local, watch it in a Terminal (default):**
```bash
cd ~/my/project
auto-resume                 # arm; resumes in Terminal after the 5h reset
auto-resume --status        # confirm it's scheduled
```

**Phone‑reachable (Remote Control + push):**
```bash
auto-resume --rc            # add Remote Control + push to the resumed session
# in the resumed session, ask Claude to "notify me when done"
```

**Hands‑off, no Terminal:**
```bash
auto-resume --mode unattended   # headless resume; output goes to ~/.claude/resume-logs/<label>.log
```

**Change your mind:**
```bash
auto-resume --cancel all        # un-arm everything (keeps the tool installed)
auto-resume --uninstall-alias   # remove just the command
auto-resume --uninstall         # remove the whole feature
```

## Notes

- **Run `auto-resume --test-terminal` once** after install so the first real fire can open a Terminal
  without waiting on a macOS Automation prompt.
- The default continue prompt is: *"The previous session stopped because the 5‑hour limit was reached.
  Continue the work until the task is complete. Notify me when done or when you need a decision."*
- Environment override: `RESUME_MARGIN_SECONDS` (default `120`) sets how long after the reset the job
  fires — handy for testing.
