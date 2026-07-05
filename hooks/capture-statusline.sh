#!/bin/bash
# claudebar — optional: feed this the same JSON your statusLine command
# receives, and the dropdown gains a per-session detail section (effort,
# context %, cost, duration, lines changed) — the exact numbers your
# terminal status line already shows, not an approximation.
#
# Not wired up automatically — statusLine is a single, personally-customized
# command per user, so we don't take it over. Add one line to your own
# statusline script instead, right after it reads stdin:
#
#   printf '%s' "$input" | "$HOME/.claude/hooks/capture-statusline.sh" &
#
# (backgrounded so it can't slow down status-line rendering.)

input=$(cat 2>/dev/null)
[ -z "$input" ] && exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$session_id" ] && exit 0

state_file="$HOME/.claude/state/agents/$session_id.json"
# Only annotate sessions update-state.sh already knows about.
[ -f "$state_file" ] || exit 0

model=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
effort=$(printf '%s' "$input" | jq -r '.effort.level // empty')
ctx_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')
tok_in=$(printf '%s' "$input" | jq -r '.context_window.total_input_tokens // empty')
tok_out=$(printf '%s' "$input" | jq -r '.context_window.total_output_tokens // empty')
cost=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty')
duration_ms=$(printf '%s' "$input" | jq -r '.cost.total_duration_ms // empty')
lines_added=$(printf '%s' "$input" | jq -r '.cost.total_lines_added // empty')
lines_removed=$(printf '%s' "$input" | jq -r '.cost.total_lines_removed // empty')

tmp="$state_file.tmp.$$"
jq \
  --arg model "$model" \
  --arg effort "$effort" \
  --arg ctx_pct "$ctx_pct" \
  --arg tok_in "$tok_in" \
  --arg tok_out "$tok_out" \
  --arg cost "$cost" \
  --arg duration_ms "$duration_ms" \
  --arg lines_added "$lines_added" \
  --arg lines_removed "$lines_removed" \
  '.model = $model | .effort = $effort | .context_pct = $ctx_pct
   | .tok_in = $tok_in | .tok_out = $tok_out | .cost_usd = $cost
   | .duration_ms = $duration_ms | .lines_added = $lines_added | .lines_removed = $lines_removed' \
  "$state_file" > "$tmp" 2>/dev/null && mv "$tmp" "$state_file"

# The 5-hour rate limit is account-wide, not per-session — same number
# regardless of which session's statusLine last reported it. Stash it
# separately so the dropdown can show it once, globally.
fiveh_pct=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
fiveh_resets=$(printf '%s' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
if [ -n "$fiveh_pct" ]; then
  fiveh_file="$HOME/.claude/state/claudebar-fiveh.json"
  tmp2="$fiveh_file.tmp.$$"
  jq -n --arg pct "$fiveh_pct" --arg resets_at "$fiveh_resets" \
    '{used_percentage: $pct, resets_at: $resets_at}' > "$tmp2" 2>/dev/null && mv "$tmp2" "$fiveh_file"
fi

exit 0
