#!/bin/bash
# claudebar — hide a live session from the dashboard until it ends.
# Usage:
#   dismiss-agent.sh <session_id>   — hide one session
#   dismiss-agent.sh --all         — hide every currently listed session

dismissed_file="$HOME/.claude/state/claudebar-dismissed"
touch "$dismissed_file"

case "$1" in
  --all)
    claude agents --json --all 2>/dev/null | jq -r '.[].sessionId' > "$dismissed_file"
    ;;
  ?*)
    echo "$1" >> "$dismissed_file"
    sort -u -o "$dismissed_file" "$dismissed_file"
    ;;
  *)
    exit 1
    ;;
esac

/usr/bin/open -g 'swiftbar://refreshplugin?name=claude-agents' >/dev/null 2>&1 &
exit 0
