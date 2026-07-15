#!/bin/bash
# claudebar — hide a live session from the dashboard until it changes state.
# Usage:
#   dismiss-agent.sh <session_id>   — hide one session
#   dismiss-agent.sh --all         — hide every currently listed session
#   dismiss-agent.sh --restore     — un-hide everything

dismissed_file="$HOME/.claude/state/claudebar-dismissed"
touch "$dismissed_file"

case "$1" in
  --restore)
    : > "$dismissed_file"
    ;;
  --all)
    claude agents --json --all 2>/dev/null \
      | jq -r '.[] | select(.kind=="interactive") | [.sessionId, (.state // "done")] | @tsv' \
      > "$dismissed_file"
    ;;
  ?*)
    state=$(claude agents --json --all 2>/dev/null | jq -r --arg sid "$1" \
      '.[] | select(.sessionId==$sid) | (.state // "done")')
    printf '%s\t%s\n' "$1" "$state" >> "$dismissed_file"
    sort -u -o "$dismissed_file" "$dismissed_file"
    ;;
  *)
    exit 1
    ;;
esac

/usr/bin/open -g 'swiftbar://refreshplugin?name=claude-agents' >/dev/null 2>&1 &
exit 0
