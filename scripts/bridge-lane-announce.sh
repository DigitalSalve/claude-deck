#!/bin/bash
# SessionStart: a session launched as a lane (BRIDGE_AGENT set by launch-session.hook.sh)
# registers ITSELF on the agent message bridge. This hook only tells the model to do it; it
# never calls the bridge or touches a token. Fires on startup, resume, clear and compact, so
# the session re-announces after a context reset (bridge_announce is idempotent per name).
lane="${BRIDGE_AGENT:-}"
[[ -n "$lane" ]] || exit 0
# Lane names are validated by the launcher; refuse anything else rather than echo it into context.
[[ "$lane" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || exit 0
python3 - "$lane" "$PWD" <<'PY'
import json, sys
lane, cwd = sys.argv[1], sys.argv[2]
msg = (f"This session was launched as bridge lane '{lane}'. Before any other bridge call, register "
       f"yourself: call bridge_announce with agent='{lane}', a one-line description of your job, and "
       f"meta {{\"cwd\": \"{cwd}\", \"lane\": \"{lane}\"}}. Keep the agent_id it returns (ag_...) and pass "
       f"agent_id=<that id> on EVERY later bridge call: this client opens a new connection per call, and "
       f"a call without it is treated as the machine's default agent. Use that name for all bridge mail, "
       f"claims and tasks. If the name is refused (bound elsewhere), tell the user instead of picking another.")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": msg}}))
PY
