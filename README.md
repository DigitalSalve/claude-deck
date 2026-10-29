# ClaudeDeck

A macOS menu-bar app and CLI for people who run several [Claude Code](https://claude.com/claude-code) sessions at once: see what every session is doing and how close you are to your plan's limits, and let sessions compact, clear or start sessions without anyone typing into a terminal by hand.

## What it does

- **Active sessions.** Every live Claude Code session with busy / idle / shell status, source (terminal, desktop, SDK), model, generated title, and first and latest prompt on hover. Kill, resume in a terminal, archive.
- **Usage windows.** The 5-hour and 7-day bars show Claude Code's own rate-limit percentages and reset times, tagged `live`. Until a session has reported them, an output-token estimate against your plan is shown, tagged `estimated`.
- **Quota.** Per-session context waste (input per turn now against the start of the session), subagent roll-ups, what rotating a session would save, thinking-token share, web tool calls and cost, for any period or date range.
- **History.** A token ledger that keeps per-day, per-model totals after Claude Code deletes old transcripts.
- **Commands.** Every control request, allowed or refused, with who asked, which session it targeted and the result. A compact or clear that is scheduled but not yet typed shows as a "queued" badge on the session.
- **Models.** Every model id seen, its family, display name and rates, with unpriced ids flagged.
- **The `claudedeck` CLI.** Named verbs over a user-only socket, so a session (or you) can ask the app to spawn, compact or clear sessions, or read usage history.

## Quick start

Requires macOS 14 or later. iTerm2 is needed for the launch buttons and for compact / clear.

**Prebuilt.** Download `ClaudeDeck-<version>-macos-universal.zip` from this repo's [Releases](../../releases) (Apple Silicon and Intel), then:

```bash
cd ~/Downloads && unzip ClaudeDeck-*-macos-universal.zip
./ClaudeDeck-*/install.sh
```

This installs `/Applications/ClaudeDeck.app`, the CLI at `~/.claude/bin/claudedeck`, the Claude Code skill at `~/.claude/skills/claudedeck`, and the two helper scripts in `~/.claude/scripts`. The build is ad-hoc signed, not notarized; `install.sh` clears the download quarantine flag so Gatekeeper does not block it.

**From source** (Swift 5.9 toolchain):

```bash
git clone <this repo> claude-deck && cd claude-deck
./build-app.sh              # release build, installs app, CLI, skill and scripts
swift run ClaudeDeckTests   # test runner, no XCTest needed
```

Then try it:

```bash
~/.claude/bin/claudedeck ping          # is the app running, and which session are you
~/.claude/bin/claudedeck sessions      # live sessions with status, tty, pid, name
~/.claude/bin/claudedeck usage --days 7
```

Both installers copy a helper script only when it is missing. If you already have your own copy they leave it and say so; copy `scripts/<name>` over it to update.

## How it works

**Watching.** The app reads what Claude Code already writes under `~/.claude`: the live session registry and the transcripts. Directory watchers catch new sessions at once; a periodic tick (every 20 s while a Quota view is open, every 5 min otherwise) picks up transcripts growing in place. Analysis is incremental and cached.

**Live usage.** Claude Code hands its status line command the account's rate limits. ClaudeDeck ships that command, `claudedeck statusline`: it saves the numbers to `~/.claude/claudedeck-usage.json` for the app and prints a compact status line (model, folder, context per turn, context waste). The installers set it up with `claudedeck statusline --install`, which edits only the `statusLine` entry of `~/.claude/settings.json` and keeps a backup. If you already have a status line, yours is kept and still shown (`--then '<your command>'`); ClaudeDeck only saves the usage. `claudedeck statusline --status`, `--install --replace` and `--uninstall` manage it.

**The control socket.** The CLI talks to the app over `~/.claude/claudedeck.sock` (mode 0600). There are only named verbs; nothing types free text.

| Command | What it does |
|---|---|
| `claudedeck ping` | Is the app running; which session the app thinks you are |
| `claudedeck sessions [--json]` | Live sessions; `*` marks the caller |
| `claudedeck spawn <dir> [--agent NAME] [--prompt TEXT] [--screen\|--background]` | Start a new session with `launch-session.sh` |
| `claudedeck compact [--session ID] [--wake TEXT \| --no-wake]` | Schedule `/compact` on a session, your own by default |
| `claudedeck clear [--session ID]` | Schedule `/clear` the same way |
| `claudedeck usage [--days N] [--json]` | Token history from the ledger; works without the app |

How a request is attributed and gated:

- The app identifies the caller from the connecting process: the kernel-reported peer pid, walked up to a live Claude Code process. Environment variables are not trusted.
- Acting on your own session is always allowed, and so is a person at a plain shell (no Claude Code session among the caller's parent processes). A session acting on another session (`--session`) needs two files you create yourself in `~/.claude/claudedeck` (make it user-only: `mkdir -p ~/.claude/claudedeck && chmod 700 ~/.claude/claudedeck`):
  - `orchestrator-roles.json` names the sessions you designate, each with your own words: `{"sessions": [{"session_id": "<uuid>", "owner_word": "<what you said>"}]}`
  - `injection-grant.json` is one grant for one action, written just before it: `{"owner_word": "<what you said>", "granted_at": <unix seconds>, "tty": "/dev/ttysNNN"}`. A grant older than 600 s or for another tty is refused; it is deleted after use and the action is logged to `injection-log.jsonl` beside it. Custom `--wake` text is refused on another session.
- Every request, allowed or refused, goes to `~/.claude/claudedeck-commands.log`.
- When the app is not running, `spawn` and compact / clear on yourself fall back to the scripts; acting on another session refuses.

This is attributable and audited, not a privilege boundary: anything running as you can still type into your terminals by other means.

**Typing compact and clear.** `scripts/self-console.sh` types the command into the target session's own terminal. It waits until the session's registry status reads idle before each line, and after `/compact` it waits for the compaction to finish before typing the wake note, so a session can schedule its own compact as the last thing it does in a turn. Text and Return are sent separately so a long wake note is submitted rather than read as a paste. It cannot see the input box: text you are typing in that tab when a line lands is sent with it.

**Starting sessions.** `scripts/launch-session.sh` opens a session in a new iTerm2 or Terminal tab without taking focus from the tab you are in, or detached in GNU screen / tmux when the screen is locked.

**Token ledger.** Claude Code deletes transcripts after `cleanupPeriodDays` (30 by default). ClaudeDeck books per-day, per-model totals (input, cache read and write, output, thinking, turns, sessions, estimated cost) into `~/.claude/claudedeck-ledger.json` as it parses transcripts, so history survives. Cost is API list price for the tokens used: an upper bound on a subscription, not what you pay.

**Models.** Any model id is resolved from a table of current ids and rates, then by family and version for ids this build has not seen (rates borrowed from the family's newest entry, and flagged). To add or correct one without a rebuild, put it in `~/.claude/claudedeck-models.json`:

```json
{ "claude-opus-6": { "family": "opus", "displayName": "Opus 6", "input": 4, "output": 20 } }
```

**The Claude Code skill.** `skills/claudedeck/SKILL.md` teaches sessions to use the CLI: listing sessions, spawning, scheduling compact / clear on themselves as the last action of a turn, checking `usage` before a large fan-out, and the rules for other sessions.

**Agent lanes (optional).** `--agent NAME` gives a new session a lane name. With the two optional hooks in `scripts/` (`launch-session.hook.example.sh` and `bridge-lane-announce.sh`), a lane registers itself under that name on an agent message bridge that has a `bridge_announce` tool. Neither ClaudeDeck nor the launcher creates identities or touches tokens. To install:

```bash
cp scripts/launch-session.hook.example.sh ~/.claude/launch-session.hook.sh
mkdir -p ~/.claude/hooks
cp scripts/bridge-lane-announce.sh ~/.claude/hooks/ && chmod +x ~/.claude/hooks/bridge-lane-announce.sh
```

then add it to the `SessionStart` hooks in `~/.claude/settings.json`:

```json
"hooks": { "SessionStart": [
  {"hooks": [{"type": "command", "command": "~/.claude/hooks/bridge-lane-announce.sh", "timeout": 5}]}
] }
```

The launcher hook passes the lane name to the session as `BRIDGE_AGENT`; at start, and after `/compact` or `/clear`, the announce hook tells the session to call `bridge_announce` with that name first and to pass the returned `agent_id` on later bridge calls. If your bridge reads a different variable or tool name, edit the two scripts.

**Files it writes.** All under `~/.claude`: `claudedeck.sock`, `claudedeck-commands.log`, `claudedeck-ledger.json`, `claudedeck-usage.json`, `claudedeck-models.json` (your overrides), `claudedeck-models-learned.json`, `claude-deck-cache.json`, `claudedeck-token-cache.json`, `claudedeck-session-numbers.json`, the `settings.json.bak-claudedeck-*` backup, and `claudedeck-debug.log` only with `CLAUDEDECK_DEBUG=1`.

**Layout.**

```
Sources/Core      models, services, control surface (testable, no @main)
Sources/App       SwiftUI menu-bar app and Quota window
Sources/CLI       the claudedeck command
Tests             custom runner: swift run ClaudeDeckTests
scripts           launch-session.sh, self-console.sh, optional lane hooks
skills/claudedeck the Claude Code skill
docs              the design paper
```

**Releases.** Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`, commit, and push a matching `v*` tag. The `Release` workflow checks the tag against `Info.plist`, runs the tests, builds the universal zip with `./package-release.sh` and attaches it to the release. Run `./package-release.sh` yourself to build into `dist/`.

## Status

Built and in daily use; current release 1.0.6, 488 tests.

- Works today: everything listed under "What it does", the CLI, the status line, installers and the release workflow.
- iTerm2 is the tested terminal. Terminal.app support exists in the scripts but is less tested.
- ClaudeDeck reads files Claude Code writes for itself (the session registry, transcripts, the status line input). Those are not a published interface and can change between Claude Code versions.
- Agent lanes are partly built: only the hooks ship, and they need a message bridge you run yourself.
- The app is ad-hoc signed, not notarized.

## The thinking behind this

[Letting Claude Code sessions control sessions safely](docs/safe-session-control.md) explains the control design: how the caller is identified, why acting on another session takes a role plus a one-shot grant, and why typing waits for idle.

## Credits

Built with Swift and SwiftUI, no third-party packages. It drives iTerm2 and Terminal through their AppleScript interfaces and reads the files [Claude Code](https://claude.com/claude-code) keeps in `~/.claude`.

## License

MIT, see [LICENSE](LICENSE).

---

Root: Agent tooling · Type: build
