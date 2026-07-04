#!/bin/bash
# claudebar — desktop notification for a Claude Code event.
#
# Called by a hook. Args:
#   $1  message   (e.g. "Turn complete")  — default "Event"
#   $2  sound     (macOS sound name)      — default "Glass"
#
# Notification title = the session's title (your /rename, else Claude's
# auto-generated title, else the folder name).
#
# ponytail: no click-to-focus here — macOS silently ignores click actions
# from unsigned CLI tools like terminal-notifier (confirmed empirically:
# -execute never fires), and there's no fix short of a signed/notarized
# app. Click-to-focus DOES work from the SwiftBar dropdown (see
# focus-agent.sh) since that's SwiftBar's own click handling, not
# terminal-notifier's.

input=$(cat 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)

if [ -z "$transcript_path" ] && [ -n "$cwd" ] && [ -n "$session_id" ]; then
  sanitized=$(printf '%s' "$cwd" | sed 's|/|-|g')
  transcript_path="$HOME/.claude/projects/${sanitized}/${session_id}.jsonl"
fi

# Resolve title: /rename (custom-title) > Claude's ai-title > basename(cwd).
resolved_title=""
if [ -f "$transcript_path" ]; then
  reversed=$(tail -r "$transcript_path" 2>/dev/null)
  line=$(printf '%s\n' "$reversed" | grep -m1 '"type":"custom-title"')
  [ -n "$line" ] && resolved_title=$(printf '%s' "$line" | jq -r '.customTitle // empty' 2>/dev/null)
  if [ -z "$resolved_title" ]; then
    line=$(printf '%s\n' "$reversed" | grep -m1 '"type":"ai-title"')
    [ -n "$line" ] && resolved_title=$(printf '%s' "$line" | jq -r '.aiTitle // empty' 2>/dev/null)
  fi
fi

title="${resolved_title:-}"
[ -z "$title" ] && [ -n "$cwd" ] && title=$(basename "$cwd")
[ -z "$title" ] && title="Claude Code"
title="${title//\"/}"

message="${1:-Event}"
sound="${2:-Glass}"
# User-picked override from the SwiftBar dropdown's Settings > Sound menu.
sound_pref="$HOME/.claude/state/claudebar-sound"
[ -s "$sound_pref" ] && sound=$(cat "$sound_pref")
message_safe="${message//\"/}"

if command -v terminal-notifier >/dev/null 2>&1; then
  # ponytail: -sender and -appIcon both no-op on modern macOS — terminal-
  # notifier 2.0.0 uses the deprecated NSUserNotification API, which Apple
  # (Big Sur+) stopped honoring custom icons for on unsigned CLI tools.
  # No known fix short of a signed app bundle; not worth chasing further.
  terminal-notifier -title "$title" -message "$message_safe" -sound "$sound" \
    >/dev/null 2>&1
else
  # Fallback: no click-to-focus, but you still get the notification.
  osascript -e "display notification \"$message_safe\" with title \"$title\" sound name \"$sound\"" >/dev/null 2>&1
fi
