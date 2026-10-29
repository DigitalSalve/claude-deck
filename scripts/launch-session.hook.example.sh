# launch-session.hook.example.sh: copy to ~/.claude/launch-session.hook.sh to enable lanes.
# Maps `launch-session.sh --agent <lane>` (and `claudedeck spawn --agent <lane>`) onto
# BRIDGE_AGENT, the lane NAME only. Nothing here mints or registers a bridge identity: the
# session registers itself on its first bridge call, prompted by bridge-lane-announce.sh.
# Rename BRIDGE_AGENT if your bridge or SessionStart hook reads another variable.
# Only NAME=VALUE lines on stdout become environment variables of the new session.
launch_session_env() {
  [[ -n "$AGENT" ]] || return 0
  echo "BRIDGE_AGENT=$AGENT"
}
