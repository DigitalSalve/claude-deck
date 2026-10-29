#!/bin/bash
# self-console.sh — let a Claude Code session drive its OWN terminal.
#
# Claude Code intercepts slash commands like /compact and /clear at the TUI
# prompt. The model cannot execute them by "typing" them into a tool, because
# it is not the interactive user. This script closes that gap: it finds the
# real terminal session hosting the calling Claude process and injects the
# command as genuine keyboard input, so the Claude Code TUI processes it as if
# the human had typed it.
#
# Mechanism (macOS): terminal app-scripting via osascript.
#   - iTerm2:      `write text` to the session whose tty matches — feeds input
#                  straight to the foreground program (Claude) without stealing
#                  focus. This is the primary, most reliable path.
#   - Terminal.app: `do script ... in <tab>` matched by tty.
# TIOCSTI (kernel input injection) is intentionally NOT used — modern macOS
# restricts it, so it silently fails.
#
# Because the injection must land when the prompt is idle (not mid-turn), the
# script runs the sequence in a detached background job and returns at once.
# Before each line it waits until the session's registry entry
# (~/.claude/sessions/<pid>.json, field "status") reads idle. After a /compact it
# waits for the session to go busy and back to idle (compaction done) before the
# next line. With no registry entry for the tty it falls back to fixed delays.
#
# It does not see the input box: text you are typing in that terminal when a
# line lands is submitted with it.
#
# Usage:
#   self-console.sh [options] [command ...]
#
#   command            One or more commands to send, in order. Each is sent as
#                      its own submitted line. Default: /clear
#   --delay N          Seconds to wait before sending the FIRST command
#                      (lets the current turn end). Default: 4
#   --between N        Seconds between commands, except after a /compact
#                      (that waits for the compaction to finish). Default: 45
#   --idle-timeout N   Give up if the session is not idle within N seconds.
#                      Default: 900
#   --no-wake          Suppress the auto-wake. By default, when the LAST
#                      command is /compact*, a plain-text wake message is
#                      auto-appended (after --wake-gap seconds) so the session
#                      resumes itself instead of stalling idle post-compact.
#                      Supplying your own trailing non-slash message also
#                      suppresses it.
#   --wake-gap N       Seconds to wait after a /compact when the session's
#                      status cannot be read. Default 180 (compaction takes
#                      2-2.5 min). With a readable status the wait ends when
#                      compaction finishes instead.
#   --tty DEV          Force target tty (e.g. /dev/ttys003) instead of
#                      auto-detecting from the process tree.
#   --app NAME         Force terminal app: iterm | terminal. Default: the
#                      SELF_CONSOLE_APP env var if set, else auto-detect
#                      (TERM_PROGRAM, then running processes).
#   --now              Send immediately in the foreground (no delay, no detach).
#                      Useful for testing; will land mid-turn if called by Claude.
#   --dry-run          Resolve target and print what WOULD be sent; send nothing.
#   -h, --help         Show this help.
#
# Examples:
#   self-console.sh /clear
#   self-console.sh /compact
#   self-console.sh --between 60 /compact /clear
#
# First real use triggers a one-time macOS Automation permission prompt for the
# terminal to control iTerm/Terminal. Approve it or the injection fails (-1743).

set -euo pipefail

DELAY=4
BETWEEN=45
# Auto-wake: a manually injected /compact leaves the session IDLE afterward
# (nothing starts the next turn), stranding a self-compacting agent mid-task.
# When the LAST command is /compact*, the script auto-appends a plain-text
# wake message (a non-slash line = a normal user message = starts a new turn)
# after WAKE_GAP seconds, so the session resumes itself. --no-wake suppresses
# this for the deliberate "compact and wait for the human" case.
NO_WAKE=0
AUTO_WAKE=0
WAKE_GAP=180
DEFAULT_WAKE="Continue the task in progress. Your context was just compacted; state is in the compact summary and your working files -- re-read them if anything is missing."
FORCE_TTY=""
# Terminal app override: --app flag > SELF_CONSOLE_APP env > auto-detect.
FORCE_APP="$(echo "${SELF_CONSOLE_APP:-}" | tr '[:upper:]' '[:lower:]')"
NOW=0
DRY=0
IDLE_TIMEOUT=900
LOG="/tmp/claude-self-console.log"
CMDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delay)   DELAY="${2:?}"; shift 2 ;;
    --between) BETWEEN="${2:?}"; shift 2 ;;
    --no-wake) NO_WAKE=1; shift ;;
    --wake-gap) WAKE_GAP="${2:?}"; shift 2 ;;
    --idle-timeout) IDLE_TIMEOUT="${2:?}"; shift 2 ;;
    --tty)     FORCE_TTY="${2:?}"; shift 2 ;;
    --app)     FORCE_APP="$(echo "${2:?}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
    --now)     NOW=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help)
      sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do CMDS+=("$1"); shift; done ;;
    -*) echo "self-console: unknown option: $1" >&2; exit 2 ;;
    *)  CMDS+=("$1"); shift ;;
  esac
done

if [[ ${#CMDS[@]} -eq 0 ]]; then
  CMDS=("/clear")
fi

# Auto-append the wake line when the sequence ends on a /compact and the
# caller did not already supply a trailing plain-text (non-slash) message.
if [[ $NO_WAKE -eq 0 ]]; then
  _last="${CMDS[$((${#CMDS[@]}-1))]}"
  if [[ "$_last" == /compact* ]]; then
    CMDS+=("$DEFAULT_WAKE")
    AUTO_WAKE=1
  fi
fi

log() { echo "[self-console $(date '+%H:%M:%S')] $*"; }

# --- Resolve the target tty ------------------------------------------------
# Preferred, direct signal: Claude Code exports CLAUDE_PID (the session's own
# process). Its controlling tty IS the terminal — no guessing. For an
# interactive session `ps -o tty=` returns e.g. `ttys000`; for a headless /
# bridge / sdk session (CLAUDE_CODE_ENVIRONMENT_KIND=bridge) it returns `??`,
# meaning there is genuinely no terminal to target.
# Fallback: walk up the process tree in case CLAUDE_PID is unset.
tty_of_pid() {
  local t
  t="$(ps -o tty= -p "$1" 2>/dev/null | awk '{print $1}')"
  if [[ -n "$t" && "$t" != "??" && "$t" != "?" ]]; then
    echo "/dev/$t"
    return 0
  fi
  return 1
}

detect_tty() {
  local pid tty ppid line
  # 1) Direct: the session's own process, as reported by Claude Code.
  if [[ -n "${CLAUDE_PID:-}" ]] && tty_of_pid "$CLAUDE_PID"; then
    return 0
  fi
  # 2) Fallback: climb parents until we find a process with a real tty.
  for start in "$$" "$PPID"; do
    pid="$start"
    local guard=0
    while [[ -n "$pid" && "$pid" -gt 1 && $guard -lt 40 ]]; do
      line="$(ps -o tty=,ppid= -p "$pid" 2>/dev/null || true)"
      [[ -z "$line" ]] && break
      tty="$(echo "$line" | awk '{print $1}')"
      ppid="$(echo "$line" | awk '{print $2}')"
      if [[ "$tty" != "??" && "$tty" != "?" && -n "$tty" ]]; then
        echo "/dev/$tty"
        return 0
      fi
      pid="$ppid"
      guard=$((guard + 1))
    done
  done
  return 1
}

TARGET_TTY="$FORCE_TTY"
if [[ -z "$TARGET_TTY" ]]; then
  if ! TARGET_TTY="$(detect_tty)"; then
    log "ERROR: could not determine the calling terminal's tty."
    log "The calling Claude session may have no controlling tty (headless/"
    log "remote-control). Re-run from an interactive terminal, or pass --tty."
    exit 1
  fi
fi

# --- Decide which terminal app owns it ------------------------------------
pick_app() {
  if [[ -n "$FORCE_APP" ]]; then echo "$FORCE_APP"; return; fi
  # TERM_PROGRAM is set by the hosting terminal and inherited down the process
  # tree — the most direct signal of which app actually owns this session.
  case "${TERM_PROGRAM:-}" in
    iTerm.app)      echo "iterm"; return ;;
    Apple_Terminal) echo "terminal"; return ;;
  esac
  # pgrep -x iTerm2 fails on macOS (process reports its full bundle path),
  # so match on the path instead.
  if pgrep -qf "/iTerm.app/Contents/MacOS/iTerm2"; then echo "iterm"; return; fi
  if pgrep -xq "Terminal"; then echo "terminal"; return; fi
  echo "iterm"  # default guess
}
APP="$(pick_app)"

# --- osascript payloads: inject one submitted line into the matching session
# Quote a string for an AppleScript literal.
as_quote() {
  local s="${1//\\/\\\\}"
  echo "${s//\"/\\\"}"
}

# Text and Return go separately: Claude Code reads a long line that arrives with
# its newline as a paste and keeps the newline in the box instead of submitting.
inject_iterm() {
  local dev="$1" cmd
  cmd="$(as_quote "$2")"
  osascript <<OSA 2>&1
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (tty of s) is "$dev" then
          tell s to write text "$cmd" newline no
          delay 0.5
          tell s to write text (ASCII character 13) newline no
          return "OK"
        end if
      end repeat
    end repeat
  end repeat
  return "NOMATCH"
end tell
OSA
}

inject_terminal() {
  local dev="$1" cmd
  cmd="$(as_quote "$2")"
  osascript <<OSA 2>&1
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if (tty of t) is "$dev" then
        do script "$cmd" in t
        return "OK"
      end if
    end repeat
  end repeat
  return "NOMATCH"
end tell
OSA
}

inject_one() {
  local cmd="$1" result
  if [[ "$APP" == "terminal" ]]; then
    result="$(inject_terminal "$TARGET_TTY" "$cmd")"
  else
    result="$(inject_iterm "$TARGET_TTY" "$cmd")"
  fi
  if [[ "$result" == "OK" ]]; then
    log "sent: $cmd  ->  $TARGET_TTY ($APP)"
  elif [[ "$result" == "NOMATCH" ]]; then
    log "ERROR: no $APP session found with tty $TARGET_TTY (cmd: $cmd)"
  else
    log "ERROR sending '$cmd': $result"
  fi
}

# --- Dry run ---------------------------------------------------------------
if [[ $DRY -eq 1 ]]; then
  log "DRY RUN — nothing sent."
  log "target tty : $TARGET_TTY"
  log "terminal   : $APP"
  log "delay/betw : ${DELAY}s / ${BETWEEN}s"
  log "commands   : ${CMDS[*]}"
  exit 0
fi

# --- Session status --------------------------------------------------------
# The registry file of the Claude process whose controlling tty is TARGET_TTY.
registry_file() {
  local f pid t
  for f in "$HOME"/.claude/sessions/*.json; do
    [[ -f "$f" ]] || continue
    pid="$(plutil -extract pid raw -o - "$f" 2>/dev/null)" || continue
    t="$(ps -o tty= -p "$pid" 2>/dev/null | awk '{print $1}')"
    if [[ -n "$t" && "/dev/$t" == "$TARGET_TTY" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

# busy | idle | shell | "" when unknown.
session_status() {
  local f
  f="$(registry_file)" || return 0
  plutil -extract status raw -o - "$f" 2>/dev/null || true
}

# Wait until the status reads idle on two polls in a row.
# 0 = idle, 1 = timed out, 2 = status unknown (no registry entry).
wait_idle() {
  local waited=0 seen=0 st
  st="$(session_status)"
  [[ -z "$st" ]] && return 2
  while [[ $waited -lt $IDLE_TIMEOUT ]]; do
    st="$(session_status)"
    if [[ "$st" == "idle" ]]; then
      seen=$((seen + 1))
      [[ $seen -ge 2 ]] && return 0
    else
      seen=0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# Right after a /compact is typed: wait up to 60 s for the session to start it.
# 0 = it went busy, 1 = it never did.
wait_busy() {
  local waited=0
  while [[ $waited -lt 60 ]]; do
    [[ "$(session_status)" == "busy" ]] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# --- Send ------------------------------------------------------------------
run_sequence() {
  sleep "$DELAY"
  local i=0 prev="" gate compacted=0
  for c in "${CMDS[@]}"; do
    if [[ $i -gt 0 ]]; then
      if [[ "$prev" == /compact* ]]; then
        # Compaction shows as busy; once it went busy, waiting for idle below
        # is enough. If it never showed, fall back to the fixed gap.
        if [[ $compacted -eq 0 ]]; then
          log "no busy status after $prev; waiting ${WAKE_GAP}s"
          sleep "$WAKE_GAP"
        fi
      else
        sleep "$BETWEEN"
      fi
    fi
    gate=0
    wait_idle || gate=$?
    if [[ $gate -eq 1 ]]; then
      log "ERROR: $TARGET_TTY not idle after ${IDLE_TIMEOUT}s; not sent: $c (and the rest)"
      return 1
    elif [[ $gate -eq 2 && $i -eq 0 ]]; then
      log "no registry status for $TARGET_TTY; sending on fixed delays"
    fi
    inject_one "$c"
    compacted=0
    if [[ "$c" == /compact* ]] && wait_busy; then
      compacted=1
    fi
    prev="$c"
    i=$((i+1))
  done
}

if [[ $NOW -eq 1 ]]; then
  DELAY=0
  run_sequence
  exit 0
fi

# Detach so the current Claude turn can finish; output goes to the log.
run_sequence >>"$LOG" 2>&1 &
disown 2>/dev/null || true
log "first in ${DELAY}s once $TARGET_TTY is idle; each line waits for idle. Log: $LOG"
exit 0
