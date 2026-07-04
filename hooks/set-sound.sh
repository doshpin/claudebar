#!/bin/bash
# claudebar — sets the notification sound preference from the SwiftBar
# dropdown's Settings submenu. $1 is a macOS sound name (see
# /System/Library/Sounds). Also plays it so clicking gives instant feedback.

sound="${1:-Glass}"
pref_file="$HOME/.claude/state/claudebar-sound"

printf '%s' "$sound" > "$pref_file"
afplay "/System/Library/Sounds/${sound}.aiff" >/dev/null 2>&1 &
