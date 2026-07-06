#!/bin/bash
# claudebar — focus the terminal tab/pane for a given session.
# Usage: focus-agent.sh <session_id>
#
# Precise: WezTerm+tmux and iTerm2 (jumps to the exact tab/pane).
# Fallback: activates whichever app owns the session's terminal bundle id
# (Terminal, VS Code, Cursor, Warp, ...) in general, when we don't have a
# precise target — most sessions launched via iTerm's agent-view switcher,
# or a daemon-managed spawn, don't get a specific tab id through at all.
# No-op (exits cleanly) if we have neither.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

session_id="$1"
[ -z "$session_id" ] && exit 1

state_file="$HOME/.claude/state/agents/$session_id.json"

wezterm_pane=""
tmux_socket=""
tmux_sess=""
tmux_win_id=""
tmux_pane_id=""
cwd=""
if [ -f "$state_file" ]; then
  wezterm_pane=$(jq -r '.wezterm_pane // ""' "$state_file")
  tmux_socket=$(jq  -r '.tmux_socket  // ""' "$state_file")
  tmux_sess=$(jq    -r '.tmux_sess    // ""' "$state_file")
  tmux_win_id=$(jq  -r '.tmux_win_id  // ""' "$state_file")
  tmux_pane_id=$(jq -r '.tmux_pane_id // ""' "$state_file")
  cwd=$(jq -r '.cwd // ""' "$state_file")
fi

# `claude agents --json` gives the exact pid for this session id directly —
# no need to guess by matching cwd against every running claude process
# (which was ambiguous whenever two sessions shared a directory, and had to
# special-case forks/bg-pty-host to avoid false matches).
pid=$(claude agents --json --all 2>/dev/null | jq -r --arg sid "$session_id" \
  '.[] | select(.sessionId == $sid) | .pid' | head -1)

iterm_session_id=""
term_bundle_id=""
if [ -n "$pid" ]; then
  iterm_session_id=$(ps eww "$pid" 2>/dev/null | tr ' ' '\n' | grep '^ITERM_SESSION_ID=' | cut -d= -f2-)
  term_bundle_id=$(ps eww "$pid" 2>/dev/null | tr ' ' '\n' | grep '^__CFBundleIdentifier=' | cut -d= -f2-)
fi
[ -z "$term_bundle_id" ] && [ -f "$state_file" ] && term_bundle_id=$(jq -r '.term_bundle_id // ""' "$state_file")

WEZTERM_BIN=$(command -v wezterm)
TMUX_BIN=$(command -v tmux)

if [ -n "$iterm_session_id" ]; then
  /usr/bin/osascript << EOF 2>/dev/null
    tell application "iTerm2"
      activate
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if id of s is "$iterm_session_id" then
              select t
              select s
              set index of w to 1
            end if
          end repeat
        end repeat
      end repeat
    end tell
EOF
  exit 0
fi

if [ -n "$wezterm_pane" ] && [ -n "$WEZTERM_BIN" ]; then
  /usr/bin/osascript -e 'tell application "WezTerm" to activate' 2>/dev/null
  "$WEZTERM_BIN" cli activate-pane --pane-id "$wezterm_pane" 2>/dev/null
  [ -z "$tmux_pane_id" ] && exit 0
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
  exit 0
fi

# No precise target — activate the app in general rather than doing nothing.
if [ -n "$term_bundle_id" ]; then
  /usr/bin/open -b "$term_bundle_id" 2>/dev/null
  exit 0
fi

# Background/forked sessions are headless (no tty of their own — see the
# comment above the pid lookup), so there's never a precise tab to jump to
# for them. Their only interface is the Claude Code agent-view overlay,
# which lives in iTerm2 — confirmed by ITERM_PROFILE showing up in their
# env even with no ITERM_SESSION_ID/__CFBundleIdentifier. Best we can
# honestly do is bring iTerm2 forward so you can open that overlay.
/usr/bin/osascript -e 'tell application "iTerm2" to activate' 2>/dev/null

exit 0
