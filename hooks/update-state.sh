#!/bin/bash
# claudebar — maintains a per-session state file that the SwiftBar plugin reads.
#
# Called by hooks. $1 is the event name:
#   UserPromptSubmit | Stop | Notification | PreToolUse | SessionStart | SessionEnd

event="${1:-unknown}"
state_dir="$HOME/.claude/state/agents"
mkdir -p "$state_dir"

input=$(cat 2>/dev/null)
[ -z "$input" ] && exit 0

session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$session_id" ] && exit 0

state_file="$state_dir/$session_id.json"

if [ "$event" = "SessionEnd" ]; then
  rm -f "$state_file"
  /usr/bin/open -g 'swiftbar://refreshplugin?name=claude-agents' >/dev/null 2>&1 &
  exit 0
fi

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$transcript_path" ] && [ -n "$cwd" ]; then
  sanitized=$(printf '%s' "$cwd" | sed 's|/|-|g')
  transcript_path="$HOME/.claude/projects/${sanitized}/${session_id}.jsonl"
fi

# Resolve title: custom-title > ai-title > basename(cwd) > "Claude Code".
title=""
if [ -f "$transcript_path" ]; then
  reversed=$(tail -r "$transcript_path" 2>/dev/null)
  line=$(printf '%s\n' "$reversed" | grep -m1 '"type":"custom-title"')
  [ -n "$line" ] && title=$(printf '%s' "$line" | jq -r '.customTitle // empty' 2>/dev/null)
  if [ -z "$title" ]; then
    line=$(printf '%s\n' "$reversed" | grep -m1 '"type":"ai-title"')
    [ -n "$line" ] && title=$(printf '%s' "$line" | jq -r '.aiTitle // empty' 2>/dev/null)
  fi
fi
[ -z "$title" ] && [ -n "$cwd" ] && title=$(basename "$cwd")
[ -z "$title" ] && title="Claude Code"

# bg = spawned as a background/forked session (Agent tool, fork-to-background),
# fg = a normal foreground terminal session.
kind="fg"
if [ -f "$transcript_path" ] && grep -qm1 '"sessionKind":"bg"' "$transcript_path" 2>/dev/null; then
  kind="bg"
fi

case "$event" in
  UserPromptSubmit)  status="working" ;;
  Stop)              status="idle" ;;
  Notification)      status="needs-attention" ;;
  SessionStart)      status="idle" ;;
  PreToolUse)
    # Only flip needs-attention -> working when the just-approved tool starts.
    # Skip otherwise so we don't rewrite state on every single tool call.
    if [ -f "$state_file" ]; then
      current=$(jq -r '.status // ""' "$state_file" 2>/dev/null)
      [ "$current" = "needs-attention" ] || exit 0
    else
      exit 0
    fi
    status="working"
    ;;
  *)                 status="idle" ;;
esac

# Capture the terminal location so the dashboard/notification can jump to it.
# Only valid because the hook runs inside the session's own process.
wezterm_pane="${WEZTERM_PANE:-}"
tmux_socket=""
tmux_sess=""
tmux_win_id=""
tmux_pane_id=""
if [ -n "$TMUX" ]; then
  tmux_socket=$(printf '%s' "$TMUX" | cut -d, -f1)
  env_pane="${TMUX_PANE:-}"
  display_pane=$(tmux display-message -p '#{pane_id}' 2>/dev/null)
  tmux_pane_id="${env_pane:-$display_pane}"
  if [ -n "$tmux_pane_id" ]; then
    tmux_sess=$(tmux display-message -p -t "$tmux_pane_id" '#{session_name}' 2>/dev/null)
    tmux_win_id=$(tmux display-message -p -t "$tmux_pane_id" '#{window_id}' 2>/dev/null)
  fi
fi

# Preserve previously captured pane info when this event lacks it.
if [ -f "$state_file" ]; then
  [ -z "$wezterm_pane" ]  && wezterm_pane=$(jq -r  '.wezterm_pane  // ""' "$state_file" 2>/dev/null)
  [ -z "$tmux_socket" ]   && tmux_socket=$(jq -r   '.tmux_socket   // ""' "$state_file" 2>/dev/null)
  [ -z "$tmux_sess" ]     && tmux_sess=$(jq -r     '.tmux_sess     // ""' "$state_file" 2>/dev/null)
  [ -z "$tmux_win_id" ]   && tmux_win_id=$(jq -r   '.tmux_win_id   // ""' "$state_file" 2>/dev/null)
  [ -z "$tmux_pane_id" ]  && tmux_pane_id=$(jq -r  '.tmux_pane_id  // ""' "$state_file" 2>/dev/null)
fi

ts=$(date +%s)
tmp="$state_file.tmp.$$"

jq -n \
  --arg session_id "$session_id" \
  --arg cwd "$cwd" \
  --arg transcript_path "$transcript_path" \
  --arg title "$title" \
  --arg status "$status" \
  --arg event "$event" \
  --argjson ts "$ts" \
  --arg wezterm_pane "$wezterm_pane" \
  --arg tmux_socket "$tmux_socket" \
  --arg tmux_sess "$tmux_sess" \
  --arg tmux_win_id "$tmux_win_id" \
  --arg tmux_pane_id "$tmux_pane_id" \
  --arg kind "$kind" \
  '{
    session_id: $session_id,
    cwd: $cwd,
    transcript_path: $transcript_path,
    title: $title,
    status: $status,
    last_event: $event,
    last_event_ts: $ts,
    wezterm_pane: $wezterm_pane,
    tmux_socket: $tmux_socket,
    tmux_sess: $tmux_sess,
    tmux_win_id: $tmux_win_id,
    tmux_pane_id: $tmux_pane_id,
    kind: $kind
  }' > "$tmp" && mv "$tmp" "$state_file"

# Nudge SwiftBar to refresh now (on top of its 30s polling).
/usr/bin/open -g 'swiftbar://refreshplugin?name=claude-agents' >/dev/null 2>&1 &

exit 0
