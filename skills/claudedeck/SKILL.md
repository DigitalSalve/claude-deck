---
name: claudedeck
description: Use the ClaudeDeck control surface (the `claudedeck` CLI) to see live Claude Code sessions, spawn a new session, compact or clear this session, and read token usage history. Use when the user says "/claudedeck", "what sessions are running", "list sessions", "is ClaudeDeck running", "spawn a session in <dir>", "compact yourself", "clear yourself", "how many tokens have we used", "usage this week", or before a large fan-out of agents or workflows. Every request is attributed by the app and logged.
user-invocable: true
allowed-tools: Bash
---

ClaudeDeck is a macOS menu-bar app that watches `~/.claude`. Its CLI, `claudedeck`, talks to the
running app over a user-only Unix socket (`~/.claude/claudedeck.sock`). The app identifies the
caller from kernel-reported process ancestry, accepts named verbs only (never free text), and
appends every request, allowed or denied, to `~/.claude/claudedeck-commands.log`.

Prefer `claudedeck` over typing into a terminal by hand (osascript, System Events) or calling
`self-console.sh` / `launch-session.sh` directly: it is the one attributed, audited path.

## Check it is there

The CLI is `~/.claude/bin/claudedeck`. That directory is often not on PATH, so call it by
its full path (in this skill, `claudedeck` means `~/.claude/bin/claudedeck`):

```bash
~/.claude/bin/claudedeck ping
```

Never run anything inside `/Applications/ClaudeDeck.app/Contents/MacOS/`. On a
case-insensitive disk `.../MacOS/claudedeck` is the app binary itself, not the CLI: it
starts a second app and never returns (1.0.3 and later refuse instead).

- Not installed: ClaudeDeck lives at github.com/DigitalSalve/claude-deck. Install the prebuilt
  release (`install.sh` in the zip) or build with `./build-app.sh`. Tell the user; do not
  install it unasked.
- Installed but `ping` says not running: `open /Applications/ClaudeDeck.app`, wait a few
  seconds, ping again. Self-targeted commands still work without the app (see Fallbacks).

## Verbs

| Goal | Command |
|---|---|
| Is the app up; which session am I | `claudedeck ping` |
| Live sessions | `claudedeck sessions` (`*` marks the caller) or `claudedeck sessions --json` |
| Start a session | `claudedeck spawn <dir> [--agent NAME] [--prompt TEXT] [--screen\|--background] [--terminal NAME] [--dry-run]` |
| Compact this session | `claudedeck compact [--wake TEXT \| --no-wake]` |
| Clear this session | `claudedeck clear` |
| Token history | `claudedeck usage [--days N] [--json]` (reads the ledger, no app needed) |

`sessions --json` returns `{"sessions":[{id, name, status, cwd, tty, pid, entrypoint, isCaller}]}`.
`status` is passed through from Claude Code's session registry (seen: `busy`, `idle`,
`waiting`); treat unknown values as "not idle".

## How to use each one

**See what is running.** Run `claudedeck sessions` before starting work in a repo another
session may already hold, and when asked what is running. A `waiting` session is blocked on
the user (a permission prompt or question); report it, do not act on it.

**Spawn.** `claudedeck spawn` runs `~/.claude/scripts/launch-session.sh`, so the launch itself
(env scrub, workspace trust, new tab without stealing focus, locked-console fallback to a
detached screen session) is the launcher's. Never start a session by hand through osascript,
a multiplexer or `nohup claude` instead.

1. **Resolve the directory.** A path is used as given (`~` is expanded). A bare repo name
   resolves under the usual code directory (e.g. `~/GitHub/<name>`): check it exists first,
   and if it does not, list close matches and ask which one was meant. No directory at all
   means `~`.
2. **Write the prompt.** Everything the new session should start on goes in `--prompt`
   (or after the directory). It starts with none of this context: put role, scope and the
   first task in it. For a long brief, write it to a file and make the prompt
   `Read <path> in full, then start`. Without a prompt the session opens idle.
3. **Name the lane.** When several sessions will run at once, or the session will hold bridge
   claims or tasks, pass `--agent <lane-name>`, distinct per concurrent session (letters,
   digits, `.` `_` `-`, max 64). It is handed to the session as its lane name and names its
   detached screen (`cc-<lane-name>`). The session registers itself on the bridge under that
   name as its first bridge call; neither ClaudeDeck nor the launcher registers or mints
   anything for it. Without it the session shares the machine's default agent.
4. **Pick the mode.** Default (a new tab, focus stays on the user) is almost always right; the
   launcher switches to detached screen by itself when the console is locked, so do not retry
   or try to unlock. `--screen` forces detached (must survive the terminal closing, or the user
   is busy typing). `--background` only when the user asks for headless; it needs a prompt.
   `--dry-run` prints the launcher's decision and launches nothing: use it when unsure what
   mode or terminal will be picked. `--terminal iterm|terminal` forces the terminal app.
5. **Read the exit code before you report.** With the app running, spawn waits up to 20 s for
   the new session to appear in the registry:
   - exit 0, "session started in <dir>: <name> (<id>)": confirmed running.
   - exit 2, "not confirmed running": the launcher accepted it but no session showed up.
     Do not tell the user it is running. Check `claudedeck sessions` once more, and for a
     detached session `screen -ls`; otherwise report it as not started, with the output.
     When the session is detached, the message names any startup prompt it is stuck at
     (workspace trust, bypass-permissions confirmation, login). Report that to the user; do
     not type into the session to answer it.
   - exit 1: failed; the message and launcher output say why.
   Without the app (fallback), nothing is confirmed: run `claudedeck sessions` after opening
   the app, or check for a claude process with that cwd, before reporting it running.
6. **Relay and stop.** Report directory, mode, agent and prompt (from the output). For a
   detached session, give the attach command: `screen -r <name>` (or `tmux attach -t <name>`).
   Do NOT start doing the new session's work yourself.

Spawn errors: "directory not found" means re-check the path with the user; "invalid agent
name" means fix the lane name; "launch script missing" means `launch-session.sh` is not
installed (tell the user); a non-zero launcher exit prints its output, which names the
problem (for a detached session that did not start, it prints a `Try by hand:` line to run).

**Compact / clear yourself.** The command is scheduled and lands when this session goes idle,
which is after the current turn ends. So run it as the LAST action of a turn and say so.
For compact, pass `--wake "<what to resume>"` so the post-compact session knows where it was;
the default wake is a generic continue. The wake line is typed once the compaction has
finished, so long notes are fine. Clear drops all context: only use it when the user
asked, or the work is finished and recorded somewhere durable.

**Usage.** Run `claudedeck usage --days 7` before launching a workflow or several agents, and
when the user asks about token spend. Cost is Anthropic API list price, an upper bound on a
subscription plan, not what the user pays. The live 5-hour / 7-day limit percentages are
in the app UI; `claudedeck statusline --status` says whether they are connected and when
they were last written. If they are not connected, tell the user; do not edit settings.json
or run `--install` unasked.

## Other sessions (`--session ID`)

Compact or clear on a session that is not yours requires the orchestrator role in
`~/.claude/claudedeck/orchestrator-roles.json` AND a live owner-word grant in
`~/.claude/claudedeck/injection-grant.json` (600 s, tty-matched, consumed on use). Custom
`--wake` text is refused on peers.

- Never write or edit the grant or roles file yourself. The owner issues grants.
- Never fall back to osascript, System Events, or `self-console.sh` against a peer when the
  app refuses. Report the refusal to the user and stop.
- If a peer session-orchestration agent or skill exists in this setup, that is the only
  caller that should use `--session`, and only on the owner's explicit direction.

## Fallbacks when the app is not running

- `spawn` runs `~/.claude/scripts/launch-session.sh` directly.
- Self-targeted `compact` / `clear` run `~/.claude/scripts/self-console.sh` on this session.
- `sessions` cannot list without the app; open it.
- `--session` (peer) is refused. There is no fallback, by design.

## Limits to keep in mind

This is attribution and audit, not a security boundary: any process running as the user can
still type into terminals without going through ClaudeDeck. See `docs/LOCKDOWN_PLAN.md` in
the repo. Do not describe it to the user as a lock.
