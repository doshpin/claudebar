#!/bin/bash
# claudebar — remove a session from the dashboard.
# Usage:
#   dismiss-agent.sh <session_id>   — delete one session's state file
#   dismiss-agent.sh --all          — delete every tracked session

state_dir="$HOME/.claude/state/agents"

case "$1" in
  --all)
    rm -f "$state_dir"/*.json
    ;;
  ?*)
    rm -f "$state_dir/$1.json"
    ;;
  *)
    exit 1
    ;;
esac

/usr/bin/open -g 'swiftbar://refreshplugin?name=claude-agents' >/dev/null 2>&1 &
exit 0
