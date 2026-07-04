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
[ -f "$state_file" ] || exit 1

wezterm_pane=$(jq -r '.wezterm_pane // ""' "$state_file")
iterm_session_id=$(jq -r '.iterm_session_id // ""' "$state_file")
term_bundle_id=$(jq -r '.term_bundle_id // ""' "$state_file")
tmux_socket=$(jq  -r '.tmux_socket  // ""' "$state_file")
tmux_sess=$(jq    -r '.tmux_sess    // ""' "$state_file")
tmux_win_id=$(jq  -r '.tmux_win_id  // ""' "$state_file")
tmux_pane_id=$(jq -r '.tmux_pane_id // ""' "$state_file")
cwd=$(jq -r '.cwd // ""' "$state_file")

# Hook-time capture of $ITERM_SESSION_ID is unreliable in practice (the var
# demonstrably exists in the live process's own environment, per `ps eww`,
# even when the hook captured nothing — Claude Code's hook execution
# doesn't appear to reliably pass it through). Fallback: at click time, find
# this session's live process by matching cwd and read ITS env directly.
# Only usable when exactly one candidate matches — if multiple sessions
# share a project directory, there's no way to tell them apart, so skip
# rather than jump to the wrong one.
if [ -z "$iterm_session_id" ] && [ -n "$cwd" ]; then
  candidates=""
  count=0
  for pid in $(pgrep -x "claude"; pgrep -f "claude/versions.*--"); do
    pid_cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    # Skip forks/backgrounded conversations (--resume) and the bg-pty-host
    # plumbing process — neither is "the real terminal to jump to", and a
    # fork shares its parent's cwd, so it'd otherwise falsely count as a
    # second candidate for the SAME directory as the real session.
    case "$pid_cmd" in
      *--resume*|*--bg-pty-host*) continue ;;
    esac
    p_cwd=$(lsof -p "$pid" 2>/dev/null | awk '$4=="cwd"{print $NF}')
    if [ "$p_cwd" = "$cwd" ]; then
      candidates="$pid"
      count=$((count+1))
    fi
  done
  if [ "$count" -eq 1 ]; then
    env_iterm=$(ps eww "$candidates" 2>/dev/null | tr ' ' '\n' | grep '^ITERM_SESSION_ID=' | cut -d= -f2-)
    [ -n "$env_iterm" ] && iterm_session_id="$env_iterm"
    if [ -z "$term_bundle_id" ]; then
      env_bundle=$(ps eww "$candidates" 2>/dev/null | tr ' ' '\n' | grep '^__CFBundleIdentifier=' | cut -d= -f2-)
      [ -n "$env_bundle" ] && term_bundle_id="$env_bundle"
    fi
  fi
fi

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
fi

exit 0
