#!/bin/bash
# claudebar — sets how the account-wide 5-hour usage stat is shown, from the
# SwiftBar dropdown's Settings submenu. $1 is one of: full | compact | hidden.

mode="${1:-full}"
printf '%s' "$mode" > "$HOME/.claude/state/claudebar-fiveh-display"
