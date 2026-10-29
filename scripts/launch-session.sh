#!/usr/bin/env bash
# launch-session.sh — open a new Claude Code session from inside another one, on macOS,
# Linux, or Windows (WSL or Git Bash), WITHOUT stealing keyboard focus from whatever
# the user is doing. One file; the OS branch is picked at run time.
#
# Usage:
#   launch-session.sh [options] <project-dir> [initial-prompt...]
#
#   <project-dir>        directory to start the session in (~ and relative paths OK)
#   [initial-prompt]     a message for the new session: everything after the directory, joined
#                        with spaces, becomes claude's first prompt (see INITIAL PROMPT below)
#   -b, --background     headless: `claude -p "<prompt>"` in this process; needs a prompt
#   -s, --screen, --detached
#                        start detached in GNU screen (or tmux when screen is absent) and
#                        return at once; attach later with `screen -r <name>` / `tmux attach
#                        -t <name>`. Automatic whenever a terminal tab cannot be opened.
#   -a, --agent NAME     a name for this session: used for the detached session name and
#                        exported to the session as LAUNCH_AGENT. A hook (below) can map it
#                        onto whatever identity system your agents use.
#   -t, --terminal NAME  force a terminal: macOS iterm|terminal; Linux tmux|kitty|wezterm|
#                        gnome-terminal|konsole|xfce4-terminal|alacritty|x-terminal-emulator;
#                        Windows wt. Default: the terminal you are sitting in, else the first
#                        one installed.
#   -n, --dry-run        print the decision and the exact command; launch nothing
#   -h, --help           this text
#
# INITIAL PROMPT (the message to the new session): any words after <project-dir> are joined
# and handed to claude as its first user message, so the session starts working immediately
# instead of waiting at an empty prompt. Quote it as one argument to keep punctuation intact:
#     launch-session.sh ~/code/api "Read AI.md, then fix issue 42 and run the tests"
# Without it the session opens idle at its prompt. The text travels inside the generated runner
# file, never through the terminal's own command line, so spaces, quotes, semicolons and
# newlines survive on every platform. The first 160 characters are logged in the detached
# registry. --background REQUIRES a prompt (a headless `claude -p` has nothing else to act on).
# For a long brief, point the prompt at a file: "Read ~/handoffs/brief.md in full, then start".
#
# Modes, in order of preference:
#   1. terminal tab   — a new tab in the terminal you are already using. Focus stays on your
#                       current tab/window wherever the platform allows it (see FOCUS below).
#   2. detached       — screen/tmux session, when the console is locked, there is no GUI,
#                       the terminal step fails, or you asked for it with --screen.
#   3. background     — `claude -p`, only when you ask for it.
#
# FOCUS (why this script exists): a plain "open a tab and run claude" grabs the keyboard, so
# anything the user was typing lands in the new session. Per platform:
#   macOS/iTerm2      no `activate`; the previous tab is re-selected right after the new one
#                     is seeded. Verified.
#   macOS/Terminal    the frontmost app is remembered and re-activated after `do script`.
#   Linux/tmux        `new-window -d` never takes focus.
#   Linux/kitty       `launch --type=tab --keep-focus` (needs allow_remote_control yes).
#   Linux/WezTerm     spawn, then `activate-pane` back to the caller's pane.
#   Linux/other       the terminal focuses its new tab; when xdotool is present the previously
#                     active X11 window is re-activated. Wayland cannot do that: use tmux.
#   Windows/wt        the previous foreground window is restored with SetForegroundWindow.
#                     If you were inside Windows Terminal itself the new tab becomes active;
#                     wt has no "open tab in background". UNTESTED on real hardware so far.
#
# CONSOLE STATE: before opening a tab the script checks whether the desktop is locked or absent
# (macOS: IOConsoleUsers; Linux: loginctl LockedHint + DISPLAY/WAYLAND_DISPLAY; Windows: the
# LogonUI process). Locked or no GUI => detached mode automatically.
#
# The session is started through a small generated runner script (one per launch, mode 600,
# deletes itself as it starts) so no quoting has to survive AppleScript, wt.exe or tmux.
#
# HOOK: if $LAUNCH_SESSION_HOOK (default ~/.claude/launch-session.hook.sh) exists it is sourced.
# It may define `launch_session_env`, which is called with DIR, AGENT, PROMPT, MODE and DRY_RUN set and
# prints NAME=VALUE lines; each becomes an environment variable of the new session. Use it for
# identity tokens, per-machine defaults, anything local that does not belong in this file.
# Values of variables whose names contain TOKEN, SECRET, KEY or PASS are masked in output.
#
# Workspace trust: a directory no session has accepted before stops at "Yes, I trust this
# folder" and, detached, nobody can answer. The per-project flag is pre-set in ~/.claude.json
# (backed up first) so the session starts straight away.
#
# Every launch scrubs the inherited CLAUDE* variables (except CLAUDE_CONFIG_DIR): a session
# spawned from inside another Claude Code session otherwise inherits its child-session marker
# and stops saving its transcript. This also covers a terminal app that this process had to
# start. Each detached launch is appended to ~/.claude/logs/screen-sessions.tsv
# (time, name, dir, agent, prompt, multiplexer).
#
# Env overrides: CLAUDE_FLAGS (default "--remote-control --dangerously-skip-permissions"),
# CLAUDE_BIN (claude on PATH), LAUNCH_TERMINAL (same as --terminal), LAUNCH_MUX (screen|tmux),
# LAUNCH_DRY_RUN=1, LAUNCH_OS (macos|linux|wsl|gitbash; testing only), LAUNCH_OSA_TIMEOUT
# (seconds to wait on AppleScript, default 25), LAUNCH_AGENT (default for --agent).
#
# Requires: bash 3.2+ (macOS system bash is fine), python3 (or python) for the trust pre-set and the macOS lock probe.
# Windows: run from WSL or Git Bash; Windows Terminal (wt.exe) for tab mode; screen or tmux
# inside WSL for detached mode. A pure-PowerShell host is out of scope.
#
# License: MIT.

set -euo pipefail
VERSION="3.0.1"

usage() { sed -n '2,/^# License/p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# OS detection
# ---------------------------------------------------------------------------
detect_os() {
  if [[ -n "${LAUNCH_OS:-}" ]]; then printf '%s' "$LAUNCH_OS"; return; fi
  case "$(uname -s)" in
    Darwin) printf macos ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then printf wsl; else printf linux; fi ;;
    MINGW*|MSYS*|CYGWIN*) printf gitbash ;;
    *) printf unknown ;;
  esac
}
OS="$(detect_os)"
case "$OS" in
  macos) OS_LABEL="macOS" ;;
  linux) OS_LABEL="Linux" ;;
  wsl) OS_LABEL="Windows (WSL)" ;;
  gitbash) OS_LABEL="Windows (Git Bash)" ;;
  *) echo "Error: unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
MODE="terminal"
AGENT="${LAUNCH_AGENT:-}"
TERMINAL="${LAUNCH_TERMINAL:-}"
DRY_RUN="${LAUNCH_DRY_RUN:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--background) MODE="background"; shift ;;
    -s|--screen|--detached) MODE="detached"; shift ;;
    -a|--agent)
      [[ $# -ge 2 ]] || { echo "Error: $1 needs a name" >&2; exit 1; }
      AGENT="$2"; shift 2 ;;
    --agent=*) AGENT="${1#--agent=}"; shift ;;
    -t|--terminal)
      [[ $# -ge 2 ]] || { echo "Error: $1 needs a name" >&2; exit 1; }
      TERMINAL="$2"; shift 2 ;;
    --terminal=*) TERMINAL="${1#--terminal=}"; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "launch-session $VERSION"; exit 0 ;;
    --) shift; break ;;
    -*) echo "Error: unknown option: $1" >&2; exit 1 ;;
    *) break ;;
  esac
done
if [[ -n "$AGENT" && ! "$AGENT" =~ ^[a-zA-Z0-9._-]{1,64}$ ]]; then
  echo "Error: invalid agent name: $AGENT (letters, digits, . _ -; max 64)" >&2
  exit 1
fi
if [[ $# -lt 1 ]]; then
  echo "Usage: launch-session.sh [-b|--background] [-s|--screen] [-a|--agent NAME] [-t|--terminal NAME] [-n|--dry-run] <project-dir> [initial-prompt...]" >&2
  exit 1
fi

RAW_DIR="$1"; shift
PROMPT="${*:-}"
# shellcheck disable=SC2088
case "$RAW_DIR" in
  "~") DIR="$HOME" ;;
  "~/"*) DIR="$HOME/${RAW_DIR#\~/}" ;;
  *) DIR="$RAW_DIR" ;;
esac
[[ -d "$DIR" ]] || { echo "Error: directory does not exist: $DIR" >&2; exit 1; }
# Physical path: on a case-insensitive filesystem `cd ~/GitHub/x && pwd` keeps the typed case,
# but claude records getcwd()'s on-disk case (~/Github/x), and trust is keyed by exact string.
# /bin/pwd calls getcwd(); the bash builtin `pwd -P` resolves symlinks but keeps the typed case.
if [[ -x /bin/pwd ]]; then DIR="$(cd "$DIR" && /bin/pwd -P)"; else DIR="$(cd "$DIR" && pwd -P)"; fi

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
[[ -n "$CLAUDE_BIN" ]] || { echo "Error: claude not found on PATH (set CLAUDE_BIN)" >&2; exit 1; }
CLAUDE_FLAGS="${CLAUDE_FLAGS:---remote-control --dangerously-skip-permissions}"
PY="$(command -v python3 || command -v python || true)"
LOG_DIR="$HOME/.claude/logs"
RUN_DIR="$HOME/.claude/launch-session/run"
REGISTRY="$LOG_DIR/screen-sessions.tsv"

# ---------------------------------------------------------------------------
# Hook: extra environment for the session (identity tokens etc.), kept out of this file.
# ---------------------------------------------------------------------------
EXTRA_ENV=()
if [[ -n "$AGENT" ]]; then EXTRA_ENV+=("LAUNCH_AGENT=$AGENT"); fi
HOOK="${LAUNCH_SESSION_HOOK:-$HOME/.claude/launch-session.hook.sh}"
if [[ -f "$HOOK" ]]; then
  # shellcheck disable=SC1090
  source "$HOOK"
  if declare -F launch_session_env >/dev/null; then
    while IFS= read -r line; do
      [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && EXTRA_ENV+=("$line")
    done < <(DIR="$DIR" AGENT="$AGENT" PROMPT="$PROMPT" MODE="$MODE" DRY_RUN="$DRY_RUN" launch_session_env || true)
  fi
fi
mask_env() {  # print NAME=VALUE with secret-looking values hidden
  local kv name
  for kv in "$@"; do
    name="${kv%%=*}"
    if [[ "$name" =~ (TOKEN|SECRET|KEY|PASS) ]]; then printf '%s=<hidden> ' "$name"; else printf '%s ' "$kv"; fi
  done
}

# ---------------------------------------------------------------------------
# Workspace trust pre-set
# ---------------------------------------------------------------------------
ensure_trust() {
  local cfg="$HOME/.claude.json"
  [[ -f "$cfg" && -n "$PY" ]] || return 0
  # Native Windows claude keys projects as C:/Users/...; Git Bash's $DIR is /c/Users/...
  local key="$DIR"
  [[ "$OS" == gitbash ]] && key="$(cygpath -m "$DIR")"
  "$PY" -I - "$cfg" "$key" <<'PYEOF' || echo "Warning: could not pre-set workspace trust in ~/.claude.json; the session may stop at the trust prompt" >&2
import json, os, shutil, sys, time
cfg, d = sys.argv[1], sys.argv[2]
with open(cfg) as f:
    data = json.load(f)
projects = data.setdefault("projects", {})
entry = projects.setdefault(d, {})
if entry.get("hasTrustDialogAccepted") is True:
    sys.exit(0)
shutil.copy2(cfg, cfg + ".bak-launch-" + time.strftime("%Y%m%d%H%M%S"))
entry["hasTrustDialogAccepted"] = True
tmp = cfg + ".tmp-launch"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, cfg)
print("  Pre-set workspace trust for " + d + " in ~/.claude.json")
PYEOF
}
[[ -n "$DRY_RUN" ]] || ensure_trust

transcript_dir() { printf '%s/.claude/projects/%s' "$HOME" "$(printf '%s' "$DIR" | tr '/' '-')"; }

print_header() {  # $1 mode text
  echo "Launching Claude Code session"
  echo "  OS:        $OS_LABEL"
  echo "  Directory: $DIR"
  echo "  Mode:      $1"
  echo "  Prompt:    ${PROMPT:-none}"
  echo "  Agent:     ${AGENT:-none (machine default)}"
  (( ${#EXTRA_ENV[@]} )) && echo "  Env:       $(mask_env ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"})"
  return 0
}

# ---------------------------------------------------------------------------
# Background mode
# ---------------------------------------------------------------------------
if [[ "$MODE" == "background" ]]; then
  [[ -n "$PROMPT" ]] || { echo "Error: --background mode requires an initial prompt" >&2; exit 1; }
  print_header "background (headless)"
  [[ -n "$DRY_RUN" ]] && { echo "  (dry run: nothing launched)"; exit 0; }
  cd "$DIR"
  # shellcheck disable=SC2163
  for kv in ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}; do export "$kv"; done
  exec "$CLAUDE_BIN" -p "$PROMPT"
fi

# ---------------------------------------------------------------------------
# Runner script: the one thing every terminal/multiplexer has to run.
# ---------------------------------------------------------------------------
RUNNER=""
write_runner() {
  mkdir -p "$RUN_DIR"; chmod 700 "$RUN_DIR"
  find "$RUN_DIR" -name '*.sh' -mmin +1440 -delete 2>/dev/null || true
  RUNNER="$RUN_DIR/$(date +%Y%m%d-%H%M%S)-$$.sh"
  {
    echo '#!/usr/bin/env bash'
    echo "# generated by launch-session.sh $(date -u +%FT%TZ); removes itself on start"
    echo 'rm -f -- "$0" 2>/dev/null'
    echo "cd $(printf '%q' "$DIR") || exit 1"
    # Drop every inherited CLAUDE* marker (except CLAUDE_CONFIG_DIR): a terminal app or
    # multiplexer started by this process inherits the parent session's child-session
    # marker, and the new session then stops saving its transcript.
    echo 'for v in $(env | grep -o "^CLAUDE[A-Za-z0-9_]*" | sort -u); do [[ "$v" == CLAUDE_CONFIG_DIR ]] || unset "$v"; done'
    for kv in ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}; do echo "export $(printf '%q' "$kv")"; done
    printf 'exec %q %s' "$CLAUDE_BIN" "$CLAUDE_FLAGS"
    [[ -n "$PROMPT" ]] && printf ' %q' "$PROMPT"
    echo
  } > "$RUNNER"
  chmod 600 "$RUNNER"
}
runner_shown() {  # for dry runs: the exec line with secrets masked
  local line="exec $CLAUDE_BIN $CLAUDE_FLAGS"
  [[ -n "$PROMPT" ]] && line+=" $(printf '%q' "$PROMPT")"
  printf '%s' "$line"
}

# Wall-clock cap for a command (macOS has no coreutils timeout). 124 when killed.
run_with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= secs )); then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true; return 124; fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"
}

# ---------------------------------------------------------------------------
# Console state: unlocked | locked | nogui | unknown
# ---------------------------------------------------------------------------
console_state_macos() {
  local json
  json="$(ioreg -n Root -d1 -a 2>/dev/null | plutil -extract IOConsoleUsers json -o - - 2>/dev/null)" || { echo unknown; return; }
  [[ -n "$json" && -n "$PY" ]] || { echo unknown; return; }
  printf '%s' "$json" | "$PY" -I -c '
import sys, json
try:
    users = json.load(sys.stdin)
except Exception:
    print("unknown"); sys.exit()
on = [u for u in users if u.get("kCGSSessionOnConsoleKey")] or users
if not on or not on[0].get("kCGSessionLoginDoneKey"):
    print("nogui"); sys.exit()
print("locked" if on[0].get("CGSSessionScreenIsLocked") else "unlocked")
' 2>/dev/null || echo unknown
}
console_state_linux() {
  [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] || { echo nogui; return; }
  command -v loginctl >/dev/null 2>&1 || { echo unknown; return; }
  local sid="${XDG_SESSION_ID:-}"
  [[ -n "$sid" ]] || sid="$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$(id -un)" '$3==u {print $1; exit}')"
  [[ -n "$sid" ]] || { echo unknown; return; }
  case "$(loginctl show-session "$sid" -p LockedHint --value 2>/dev/null)" in
    yes) echo locked ;; no) echo unlocked ;; *) echo unknown ;;
  esac
}
console_state_windows() {
  command -v powershell.exe >/dev/null 2>&1 || { echo unknown; return; }
  local out
  out="$(powershell.exe -NoProfile -NonInteractive -Command \
    'if (Get-Process LogonUI -ErrorAction SilentlyContinue) { "locked" } else { "unlocked" }' 2>/dev/null | tr -d '\r\n')"
  case "$out" in locked|unlocked) echo "$out" ;; *) echo unknown ;; esac
}
console_state() {
  case "$OS" in
    macos) console_state_macos ;;
    linux) console_state_linux ;;
    wsl|gitbash) console_state_windows ;;
  esac
}

# ---------------------------------------------------------------------------
# Detached mode: GNU screen, or tmux when screen is absent (LAUNCH_MUX overrides).
# ---------------------------------------------------------------------------
pick_mux() {
  local want="${LAUNCH_MUX:-}"
  if [[ -n "$want" ]]; then command -v "$want" >/dev/null 2>&1 && { printf '%s' "$want"; return; }; return 1; fi
  if command -v screen >/dev/null 2>&1; then printf screen; return; fi
  if command -v tmux >/dev/null 2>&1; then printf tmux; return; fi
  return 1
}
mux_has() {  # $1 mux, $2 name
  case "$1" in
    screen) (screen -ls 2>/dev/null || true) | grep -q "[.]${2}[[:space:]]" ;;
    tmux) tmux has-session -t "=$2" 2>/dev/null ;;
  esac
}
session_name() {  # $1 mux
  local base
  if [[ -n "$AGENT" ]]; then base="cc-$AGENT"; else base="cc-$(basename "$DIR")-$(date +%H%M)"; fi
  base="$(printf '%s' "$base" | tr -c 'a-zA-Z0-9._-' '-' | cut -c1-60)"
  local name="$base" n=2
  while mux_has "$1" "$name"; do name="${base}-$n"; n=$((n + 1)); done
  printf '%s' "$name"
}
launch_detached() {
  local reason="${1:-requested}" mux name
  mux="$(pick_mux)" || { echo "Error: neither GNU screen nor tmux is installed; cannot run detached (install one, or use --background with a prompt)" >&2; return 1; }
  name="$(session_name "$mux")"
  print_header "detached $mux ($reason)"
  echo "  Session:   $name"
  if [[ -n "$DRY_RUN" ]]; then
    echo "  Runner:    $(runner_shown)"
    echo "  (dry run: nothing launched)"; return 0
  fi
  write_runner
  local tdir before; tdir="$(transcript_dir)"
  before="$(ls "$tdir" 2>/dev/null || true)"
  case "$mux" in
    screen) screen -dmS "$name" /usr/bin/env bash -l "$RUNNER" ;;
    tmux) tmux new-session -d -s "$name" -c "$DIR" "bash -l $(printf '%q' "$RUNNER")" ;;
  esac
  sleep 2
  if ! mux_has "$mux" "$name"; then
    echo "Error: $mux session $name did not start (or exited at once). Try by hand: bash -l $RUNNER" >&2
    return 1
  fi
  mkdir -p "$LOG_DIR"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$name" "$DIR" "${AGENT:-}" "${PROMPT:0:160}" "$mux" | tr -d '\r' >> "$REGISTRY"
  echo "Started $mux session $name."
  case "$mux" in
    screen) echo "  Attach: screen -r $name   (detach again: Ctrl-A then D)" ;;
    tmux) echo "  Attach: tmux attach -t $name   (detach again: Ctrl-B then D)" ;;
  esac
  echo "  Or from a Claude session: /resume-session $name"
  [[ "$OS" == gitbash ]] && return 0
  # A transcript file that did not exist before the launch proves the session got past startup
  # (no trust prompt, no inherited child-session marker). A warning, not a failure.
  local waited=0 found=""
  while (( waited < 20 )); do
    found="$(comm -13 <(printf '%s\n' "$before" | sort) <(ls "$tdir" 2>/dev/null | sort) | grep '\.jsonl$' | head -n1 || true)"
    [[ -n "$found" ]] && break
    sleep 2; waited=$((waited + 2))
  done
  if [[ -n "$found" ]]; then echo "  Transcript saving verified: $tdir/$found"
  else echo "Warning: no new transcript under $tdir after ${waited}s; attach and look at the session." >&2; fi
}
if [[ "$MODE" == "detached" ]]; then launch_detached "requested"; exit $?; fi

# ---------------------------------------------------------------------------
# Terminal mode, per OS. Each open_tab_* returns 0 on success.
# ---------------------------------------------------------------------------
TERMINAL_USED=""
TAB_CMD=""  # what the new tab runs: bash -l <runner>

# --- macOS: AppleScript into iTerm2 or Terminal.app --------------------------
pick_terminal_macos() {
  case "${TERMINAL:-}" in
    iterm|iterm2) printf iterm ;;
    terminal) printf terminal ;;
    "") if [[ -d /Applications/iTerm.app || -d "$HOME/Applications/iTerm.app" ]]; then printf iterm; else printf terminal; fi ;;
    *) echo "Error: unknown macOS terminal '$TERMINAL' (iterm|terminal)" >&2; return 1 ;;
  esac
}
open_tab_macos() {
  local script as_cmd
  as_cmd="${TAB_CMD//\\/\\\\}"; as_cmd="${as_cmd//\"/\\\"}"   # AppleScript string literal
  if [[ "$TERMINAL_USED" == iterm ]]; then
    read -r -d '' script <<EOS || true
tell application "iTerm"
    -- never steal focus: no activate; re-select the caller's tab after seeding the new one
    if (count of windows) > 0 then
        tell current window
            set origTab to current tab
            set newTab to (create tab with default profile)
            tell current session of newTab
                write text "$as_cmd"
            end tell
            select origTab
        end tell
    else
        set newWindow to (create window with default profile)
        tell current session of newWindow
            write text "$as_cmd"
        end tell
    end if
end tell
EOS
  else
    read -r -d '' script <<EOS || true
tell application "System Events" to set frontApp to name of first application process whose frontmost is true
tell application "Terminal" to do script "$as_cmd"
tell application frontApp to activate
EOS
  fi
  run_with_timeout "${LAUNCH_OSA_TIMEOUT:-25}" osascript -e "$script"
}

# --- Linux: the terminal you are in, else the first installed -----------------
pick_terminal_linux() {
  local t="${TERMINAL:-}"
  if [[ -z "$t" ]]; then
    if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then t=tmux
    elif [[ -n "${KITTY_WINDOW_ID:-}" ]] && command -v kitten >/dev/null 2>&1; then t=kitty
    elif [[ -n "${WEZTERM_PANE:-}" ]] && command -v wezterm >/dev/null 2>&1; then t=wezterm
    elif [[ -n "${GNOME_TERMINAL_SCREEN:-}" ]] && command -v gnome-terminal >/dev/null 2>&1; then t=gnome-terminal
    elif [[ -n "${KONSOLE_VERSION:-}" ]] && command -v konsole >/dev/null 2>&1; then t=konsole
    else
      local c
      for c in gnome-terminal konsole xfce4-terminal kitty wezterm alacritty x-terminal-emulator; do
        command -v "$c" >/dev/null 2>&1 && { t="$c"; break; }
      done
    fi
  fi
  [[ -n "$t" ]] || { echo "No terminal emulator found (tmux, kitty, wezterm, gnome-terminal, konsole, xfce4-terminal, alacritty, x-terminal-emulator)." >&2; return 1; }
  printf '%s' "$t"
}
x11_active_window() { if [[ -n "${DISPLAY:-}" ]] && command -v xdotool >/dev/null 2>&1; then xdotool getactivewindow 2>/dev/null || true; fi; }
x11_restore_window() { if [[ -n "${1:-}" ]]; then sleep 0.8; xdotool windowactivate "$1" 2>/dev/null || true; fi; return 0; }
open_tab_linux() {
  local prev
  case "$TERMINAL_USED" in
    tmux)
      tmux new-window -d -c "$DIR" "$TAB_CMD" ;;
    kitty)
      kitten @ launch --type=tab --keep-focus --cwd "$DIR" bash -lc "$TAB_CMD" >/dev/null ;;
    wezterm)
      wezterm cli spawn --cwd "$DIR" -- bash -lc "$TAB_CMD" >/dev/null
      if [[ -n "${WEZTERM_PANE:-}" ]]; then wezterm cli activate-pane --pane-id "$WEZTERM_PANE" >/dev/null 2>&1 || true; fi ;;
    gnome-terminal)
      prev="$(x11_active_window)"
      gnome-terminal --tab --working-directory="$DIR" -- bash -lc "$TAB_CMD"
      x11_restore_window "$prev" ;;
    konsole)
      prev="$(x11_active_window)"
      konsole --new-tab --workdir "$DIR" -e bash -lc "$TAB_CMD" >/dev/null 2>&1 &
      x11_restore_window "$prev" ;;
    xfce4-terminal)
      prev="$(x11_active_window)"
      xfce4-terminal --tab --working-directory="$DIR" -x bash -lc "$TAB_CMD"
      x11_restore_window "$prev" ;;
    alacritty)
      prev="$(x11_active_window)"
      alacritty --working-directory "$DIR" -e bash -lc "$TAB_CMD" >/dev/null 2>&1 &
      x11_restore_window "$prev" ;;
    x-terminal-emulator)
      prev="$(x11_active_window)"
      x-terminal-emulator -e bash -lc "$TAB_CMD" >/dev/null 2>&1 &
      x11_restore_window "$prev" ;;
    *) echo "Error: unknown Linux terminal '$TERMINAL_USED'" >&2; return 1 ;;
  esac
}

# --- Windows (WSL / Git Bash): Windows Terminal --------------------------------
PS_FG='Add-Type -Namespace U -Name W -MemberDefinition "[DllImport(\"user32.dll\")] public static extern IntPtr GetForegroundWindow(); [DllImport(\"user32.dll\")] public static extern bool SetForegroundWindow(IntPtr h);"'
win_fg_get() { powershell.exe -NoProfile -NonInteractive -Command "$PS_FG; [U.W]::GetForegroundWindow().ToInt64()" 2>/dev/null | tr -d '\r\n' || true; }
win_fg_set() { if [[ -n "${1:-}" ]]; then sleep 1; powershell.exe -NoProfile -NonInteractive -Command "$PS_FG; [void][U.W]::SetForegroundWindow([IntPtr]$1)" >/dev/null 2>&1 || true; fi; return 0; }
open_tab_windows() {
  local prev title distro=()
  [[ "$TERMINAL_USED" == wt ]] || { echo "Error: unknown Windows terminal '$TERMINAL_USED' (wt)" >&2; return 1; }
  command -v wt.exe >/dev/null 2>&1 || { echo "Windows Terminal (wt.exe) not found on PATH." >&2; return 1; }
  title="claude: $(basename "$DIR")"
  prev="$(win_fg_get)"
  # Windows Terminal treats ';' as a command separator; the runner path never contains one.
  if [[ "$OS" == wsl ]]; then
    [[ -n "${WSL_DISTRO_NAME:-}" ]] && distro=(-d "$WSL_DISTRO_NAME")
    wt.exe -w 0 new-tab --title "$title" wsl.exe ${distro[@]+"${distro[@]}"} --cd "$DIR" -- bash -l "$RUNNER"
  else
    wt.exe -w 0 new-tab --title "$title" -d "$(cygpath -w "$DIR")" "$(cygpath -w "$(command -v bash)")" -l "$(cygpath -m "$RUNNER")"
  fi
  win_fg_set "$prev"
}

# ---------------------------------------------------------------------------
# Terminal mode driver
# ---------------------------------------------------------------------------
STATE="$(console_state)"
case "$STATE" in
  locked) echo "Console is LOCKED: a terminal tab cannot be opened. Falling back to a detached session."; launch_detached "console locked"; exit $? ;;
  nogui) echo "No GUI session: a terminal tab cannot be opened. Falling back to a detached session."; launch_detached "no GUI session"; exit $? ;;
esac

case "$OS" in
  macos) TERMINAL_USED="$(pick_terminal_macos)" || exit 1 ;;
  linux) TERMINAL_USED="$(pick_terminal_linux)" || { launch_detached "no terminal emulator"; exit $?; } ;;
  wsl|gitbash) TERMINAL_USED="${TERMINAL:-wt}" ;;
esac

if [[ -n "$DRY_RUN" ]]; then
  print_header "terminal tab ($TERMINAL_USED; console state: $STATE)"
  echo "  Runner:    $(runner_shown)"
  echo "  (dry run: nothing launched)"
  exit 0
fi

write_runner
TAB_CMD="bash -l $(printf '%q' "$RUNNER")"
set +e
case "$OS" in
  macos) open_tab_macos ;;
  linux) open_tab_linux ;;
  wsl|gitbash) open_tab_windows ;;
esac
RC=$?
set -e
if (( RC != 0 )); then
  if (( RC == 124 )); then echo "Terminal ($TERMINAL_USED) did not answer in time (console state: $STATE). Falling back to a detached session."
  else echo "Terminal ($TERMINAL_USED) step failed (exit $RC; console state: $STATE). Falling back to a detached session."; fi
  rm -f -- "$RUNNER" 2>/dev/null
  launch_detached "terminal step failed"; exit $?
fi

echo "Launched Claude Code session"
echo "  OS:        $OS_LABEL"
echo "  Directory: $DIR"
echo "  Mode:      terminal tab ($TERMINAL_USED, focus kept on your current tab)"
echo "  Prompt:    ${PROMPT:-none}"
echo "  Agent:     ${AGENT:-none (machine default)}"
