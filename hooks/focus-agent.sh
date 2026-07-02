#!/bin/bash
# claudebar — focus the WezTerm tab + tmux pane for a given session.
# Usage: focus-agent.sh <session_id>
#
# No-op (exits cleanly) if the session isn't running under WezTerm + tmux, so
# it's safe to wire up regardless of your terminal.

session_id="$1"
[ -z "$session_id" ] && exit 1

state_file="$HOME/.claude/state/agents/$session_id.json"
[ -f "$state_file" ] || exit 1

wezterm_pane=$(jq -r '.wezterm_pane // ""' "$state_file")
tmux_socket=$(jq  -r '.tmux_socket  // ""' "$state_file")
tmux_sess=$(jq    -r '.tmux_sess    // ""' "$state_file")
tmux_win_id=$(jq  -r '.tmux_win_id  // ""' "$state_file")
tmux_pane_id=$(jq -r '.tmux_pane_id // ""' "$state_file")

WEZTERM_BIN=$(command -v wezterm)
TMUX_BIN=$(command -v tmux)

/usr/bin/osascript -e 'tell application "WezTerm" to activate' 2>/dev/null

if [ -n "$wezterm_pane" ] && [ -n "$WEZTERM_BIN" ]; then
  "$WEZTERM_BIN" cli activate-pane --pane-id "$wezterm_pane" 2>/dev/null
fi

if [ -n "$tmux_pane_id" ] && [ -n "$tmux_socket" ] && [ -n "$TMUX_BIN" ]; then
  # Find the tmux client living in the activated WezTerm pane (matching tty),
  # so switch-client moves the right client rather than an arbitrary one.
  wezterm_tty=""
  if [ -n "$wezterm_pane" ] && [ -n "$WEZTERM_BIN" ]; then
    wezterm_tty=$("$WEZTERM_BIN" cli list --format json 2>/dev/null \
      | jq -r ".[] | select(.pane_id == $wezterm_pane) | .tty_name" 2>/dev/null)
  fi
  if [ -n "$wezterm_tty" ]; then
    "$TMUX_BIN" -S "$tmux_socket" switch-client -c "$wezterm_tty" \
      -t "$tmux_sess:$tmux_win_id.$tmux_pane_id" 2>/dev/null
  else
    "$TMUX_BIN" -S "$tmux_socket" switch-client \
      -t "$tmux_sess:$tmux_win_id.$tmux_pane_id" 2>/dev/null
  fi
  "$TMUX_BIN" -S "$tmux_socket" select-window -t "$tmux_win_id"  2>/dev/null
  "$TMUX_BIN" -S "$tmux_socket" select-pane   -t "$tmux_pane_id" 2>/dev/null
fi

exit 0
