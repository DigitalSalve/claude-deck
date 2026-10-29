# Letting Claude Code sessions control sessions safely

## Summary

When several Claude Code sessions work in parallel, they need to manage each other and themselves: compact a session whose context has grown, clear one that has finished, start a new one in another repo. The commands that do this (`/compact`, `/clear`) are only read from the terminal's input, so in practice the session or its owner ends up typing into terminals by hand, at the wrong moment, with nothing recording who did what. ClaudeDeck replaces that with a small local control surface: named verbs over a user-only socket, a caller identified from the operating system rather than from anything the caller claims, a rule that a session may always act on itself but needs an explicit, one-shot grant to act on another, and typing that waits until the target session is idle. Every request, allowed or refused, is logged. The result is attributable and predictable, though it is not a security boundary, and this paper says where that line is.

## The problem

A Claude Code session can run shell commands, but it cannot run its own slash commands. `/compact` and `/clear` are handled by the terminal interface, so they have to arrive as typed input. A long-running session that wants to compact itself before its context fills up has two bad options: stop and ask the person to type it, or run a script that types into its own terminal.

Typing into a terminal from a script goes wrong in predictable ways:

- **Timing.** Text typed while the session is still answering is queued or mixed into the reply, and a slash command typed mid-turn may never run.
- **Pastes.** A long line that arrives in one burst together with its newline is read as a paste: the newline stays in the input box and nothing is submitted.
- **Modal commands.** Some commands open a full-screen dialog. Typed by a script, that dialog can sit unanswered and block the session for hours.
- **Identity.** Once one session can type into another, any session can, and environment variables that say "I am the orchestrator" are trivial to set.
- **No record.** Afterwards nobody can tell which session caused which action.

## The idea

Three claims, each a plain rule:

1. **Ask a local service by name, never type free text.** Sessions request `spawn`, `compact`, `clear`, `ping`, `sessions` or `usage` from one app over a socket only their user can open. The app decides whether and how to act.
2. **Identify the caller from the kernel, not from the caller.** The app learns which process connected from the socket itself and walks up its parent processes to a live Claude Code session. What the caller says about itself does not matter.
3. **Self is free, others need the owner's word, and everything is written down.** A session may always act on itself. Acting on another session needs a role the owner assigned to that session and a single-use grant for this one action. Every request goes to an append-only log.

A fourth rule keeps the typing itself safe: **type only when the target is idle, and only commands that cannot open a dialog** (`/compact` and `/clear`).

## How it works

1. **The request.** A session runs `claudedeck compact --wake "continue with the migration"`. The CLI connects to `~/.claude/claudedeck.sock` (mode 0600) and sends a JSON request naming the verb, an optional target session, and options.
2. **Who is asking.** The app reads the peer process id from the socket (`LOCAL_PEERPID` on macOS) and walks up the process tree until it reaches a process listed in Claude Code's live session registry. That session is the caller. If no session is found, the caller is a person at a plain shell.
3. **The decision.** With no target, or the caller as the target, the request is allowed. A person at a shell is allowed. Otherwise the policy reads two files the owner creates by hand in a user-only directory:
   - `orchestrator-roles.json` lists the sessions the owner has designated, each with the owner's own words.
   - `injection-grant.json` holds one grant: the owner's words, the time it was written, and the target's terminal. A grant older than 600 seconds, or for a different terminal, is refused. A used grant is deleted, and the action is appended to `injection-log.jsonl`.

   Free-text wake notes are refused when the target is another session, so one session can never put arbitrary words into another's prompt.
4. **The record.** Allowed or refused, the request is written to `~/.claude/claudedeck-commands.log` with the time, verb, caller, target and result. The app's Commands tab shows the same list, and a scheduled compact appears as a "queued" badge on the target's row until it lands.
5. **The typing.** The app runs a small script with the target's terminal device. The script checks the session registry, where Claude Code records each session's status, and waits until the target reads idle on two polls in a row. It types the text, pauses, then sends Return as its own keystroke, so long lines are submitted rather than read as a paste. After `/compact` it waits for the session to go busy (the compaction) and back to idle before typing the wake note, so the session resumes with the note instead of stalling.
6. **Starting sessions.** `spawn` runs a launcher that opens a new terminal tab without taking focus from the one in use, passes only a validated lane name to the new session, and falls back to a detached screen session when the Mac's screen is locked and no window can open.

## Examples

**A session compacts itself.** A session that has been working for hours ends its turn with `claudedeck compact --wake "Resume step 4 of the plan in NOTES.md"`. The request is logged, the session's row shows "compact queued", the script types `/compact` once the turn has ended, waits about ten seconds while the compaction runs, and then types the note. The session wakes with a fresh context and the instruction it left itself.

**A session tries to reset a neighbour.** Another session runs `claudedeck clear --session <id>`. It holds no role, so the request is refused with a message saying so, and the refusal is logged with both session ids. Nothing is typed.

**The owner delegates one action.** The owner designates an orchestrating session in `orchestrator-roles.json`, then, for one stuck session, writes a grant naming that session's terminal. The orchestrator's `compact --session <id> --no-wake` is allowed once; the grant is deleted and the action logged. A second attempt is refused.

**Testing the timing.** In testing, `/compact` was scheduled one second after a long prompt was sent. The script waited for the five-second reply to finish, the compaction ran from 02:22:49 to 02:23:04, and the 225-character wake note, including quotes and a backslash, was submitted at 02:23:06 and answered.

## Trade-offs

- **Attributable, not enforced.** Anything running as the same user can still drive the terminal directly, write the grant file, or open the socket. The design makes the sanctioned path easy, visible and logged; it does not stop a determined process. A real boundary would need the terminal itself to check who sends input, which this project does not attempt.
- **Blind to the input box.** The script knows when the session is idle, not what is in the prompt. Text the person is typing in that terminal when a line lands is submitted with it.
- **Depends on Claude Code's own files.** The session registry and its status field are written by Claude Code for itself, not a published interface, and may change between versions. Without a readable status the script falls back to fixed delays and says so in its log.
- **One Mac, one user.** It controls sessions on the local machine only.
- **Narrow on purpose.** Only commands that cannot open a dialog are typed. That rules out useful commands, in exchange for never leaving a session stuck behind a prompt nobody sees.

## Status

Built and released in ClaudeDeck 1.0.6, with 488 tests covering the request protocol, the policy decisions and the command log. Idle-gated typing, the compaction wait and the separate Return were verified end to end against a live session; the typing script itself has no automated test. iTerm2 is the tested terminal; Terminal.app is supported in the scripts but less tested. Named lanes for an agent message bridge are partly built: only optional hooks ship.

## Credits

Built in Swift on macOS, using the kernel's socket peer credentials and the terminals' AppleScript interfaces, around the session registry and transcripts that [Claude Code](https://claude.com/claude-code) keeps in `~/.claude`.
