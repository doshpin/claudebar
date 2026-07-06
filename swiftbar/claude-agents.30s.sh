#!/bin/bash
# <xbar.title>claudebar</xbar.title>
# <xbar.version>v3.0</xbar.version>
# <xbar.author>claudebar</xbar.author>
# <xbar.desc>Menu-bar dashboard for every running Claude Code agent-view session.</xbar.desc>
# Refreshed every 30s as a fallback; hooks trigger immediate refresh via swiftbar:// URL.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

state_dir="$HOME/.claude/state/agents"
dismissed_file="$HOME/.claude/state/claudebar-dismissed"
mkdir -p "$state_dir"
touch "$dismissed_file"

# `claude agents --json --all` is Claude Code's own authoritative session
# list — the exact same data backing the desktop app's agent view. Its
# entries come in two kinds: "background" (a dispatched/forked agent-view
# session — what the desktop app's Needs input / Working / Completed groups
# show) and "interactive" (a plain terminal tab running claude, e.g. a
# WezTerm+tmux pane). The desktop app's agent view lists only background,
# but claudebar's whole point is watching your own foreground terminal
# sessions too (that's why the hooks capture WezTerm/tmux pane info), so we
# keep both. Background carries an API state; interactive doesn't — we fill
# its status from the hook-written state file below.
agents_json=$(claude agents --json --all 2>/dev/null \
  | jq -c '[.[] | select(.kind=="background" or .kind=="interactive")]')
[ -z "$agents_json" ] && agents_json="[]"

is_dismissed() { grep -qF "$(printf '%s\t' "$1")" "$dismissed_file" 2>/dev/null; }

# Dismissed entries store "sessionId<TAB>state" (the state at dismiss time).
# Un-dismiss (drop from the file) any entry whose session is gone entirely,
# or whose state has since changed — a state change means new activity, so
# a session you hid shouldn't stay hidden forever just because you kept
# using it under the same sessionId.
# (No associative arrays here — macOS ships bash 3.2 as /bin/bash, which
# doesn't have them; `declare -A` fails there. Grep against a tsv instead.)
live_state_tsv=$(printf '%s' "$agents_json" | jq -r '.[] | [.sessionId, (.state // "done")] | @tsv')

: > "$dismissed_file.tmp"
while IFS=$'\t' read -r dsid dstate; do
  [ -z "$dsid" ] && continue
  printf '%s\n' "$live_state_tsv" | grep -qxF "$(printf '%s\t%s' "$dsid" "$dstate")" \
    && printf '%s\t%s\n' "$dsid" "$dstate" >> "$dismissed_file.tmp"
done < "$dismissed_file"
mv "$dismissed_file.tmp" "$dismissed_file"

# The API's own "state" field (working / blocked / done) is exactly the
# same signal the desktop app groups by (Working / Needs input /
# Completed) — no need to reconstruct it from hook events anymore.
#
# One gap: right after a background session restarts (its inner process
# got reaped and the daemon relaunched it), the API briefly reports "name"
# as the bare short id instead of its real title — the desktop app just
# shows its own last-cached title instead. Detect that (name == id) and
# resolve a proper title from the transcript ourselves, same fallback
# chain Claude Code itself uses: custom-title > ai-title > folder name.
resolve_title() {
  local sid="$1" cwd="$2"
  local sanitized transcript_path title=""
  sanitized=$(printf '%s' "$cwd" | sed 's|/|-|g')
  transcript_path="$HOME/.claude/projects/${sanitized}/${sid}.jsonl"
  if [ -f "$transcript_path" ]; then
    local reversed line
    reversed=$(tail -r "$transcript_path" 2>/dev/null)
    line=$(printf '%s\n' "$reversed" | grep -m1 '"type":"custom-title"')
    [ -n "$line" ] && title=$(printf '%s' "$line" | jq -r '.customTitle // empty' 2>/dev/null)
    if [ -z "$title" ]; then
      line=$(printf '%s\n' "$reversed" | grep -m1 '"type":"ai-title"')
      [ -n "$line" ] && title=$(printf '%s' "$line" | jq -r '.aiTitle // empty' 2>/dev/null)
    fi
  fi
  [ -z "$title" ] && [ -n "$cwd" ] && title=$(basename "$cwd")
  echo "$title"
}

# Sub-agents (background/forked sessions) aren't shown as their own rows —
# only the main (interactive) session is. Instead, a running sub-agent rolls
# its "busy" up onto its parent: while any of a session's sub-agents is still
# working/blocked, the parent stays yellow and never reports "turn complete",
# even after its own Stop hook fired. parent_session_id is captured by the
# update-state hook (process ancestry via --resume); read it from the child's
# state file. bash 3.2 has no assoc arrays, so collect a newline list + grep.
active_parents=""
while IFS=$'\t' read -r sid state kind; do
  [ "$kind" = "background" ] || continue
  case "$state" in working|blocked) ;; *) continue ;; esac
  psid=$(jq -r '.parent_session_id // ""' "$state_dir/$sid.json" 2>/dev/null)
  [ -n "$psid" ] && active_parents="${active_parents}${psid}
"
done < <(printf '%s' "$agents_json" | jq -r '.[] | [.sessionId, (.state // "done"), .kind] | @tsv')

entries=()
# Tab is "IFS whitespace" to bash's `read`, so consecutive tabs (an empty
# field, e.g. .pid missing on a respawned session) get squeezed into one
# delimiter instead of preserved as an empty field — silently shifting
# every later column left by one. Force every field non-empty with a "-"
# sentinel so no column is ever truly blank, then strip the sentinel back.
while IFS=$'\t' read -r sid name cwd pid state id kind; do
  [ -z "$sid" ] && continue
  # Hide sub-agents; only the main (interactive) session gets a row.
  [ "$kind" = "background" ] && continue
  is_dismissed "$sid" && continue
  [ "$pid" = "-" ] && pid=""
  [ "$id" = "-" ] && id=""
  case "$state" in
    blocked) status="needs-attention" ;;
    working) status="working" ;;
    *)       status="completed" ;;
  esac
  # Interactive (foreground) sessions carry no API state — it's always null,
  # which maps to "completed" above. Use the accurate working/idle/
  # needs-attention our own hooks recorded for this session instead, so a
  # busy or input-waiting foreground pane isn't misfiled as Completed.
  if [ "$kind" = "interactive" ] && [ -f "$state_dir/$sid.json" ]; then
    case "$(jq -r '.status // ""' "$state_dir/$sid.json" 2>/dev/null)" in
      needs-attention) status="needs-attention" ;;
      working)         status="working" ;;
      idle)            status="completed" ;;
    esac
  fi
  # A running sub-agent keeps its parent yellow, overriding an idle Stop.
  if printf '%s' "$active_parents" | grep -qxF "$sid"; then
    status="working"
  fi
  if [ "$name" = "$id" ]; then
    resolved=$(resolve_title "$sid" "$cwd")
    [ -n "$resolved" ] && name="$resolved"
  fi
  name="${name//|/-}"
  entries+=("$status|$name|$sid|$cwd|$pid")
done < <(printf '%s' "$agents_json" | jq -r '.[] | [.sessionId, .name, .cwd, (.pid // "-" | tostring), (.state // "done"), (.id // "-"), .kind] | @tsv')

attn=0; work=0; done_n=0
for e in "${entries[@]}"; do
  case "${e%%|*}" in
    needs-attention) attn=$((attn+1)) ;;
    working)         work=$((work+1)) ;;
    completed)       done_n=$((done_n+1)) ;;
  esac
done

# Pre-tinted Claude icons (red/yellow/green/orange), generated once from
# the tray icon's transparent silhouette — the bundled app icon has a solid
# background so it can't be tinted, only this template asset can.
tint_dir="$HOME/.claude/state/claudebar-icons"
if [ ! -f "$tint_dir/claude-green.png" ]; then
  "$HOME/.claude/hooks/gen-tinted-icons.sh" "$tint_dir" >/dev/null 2>&1
fi
b64() { [ -f "$1" ] && base64 -i "$1" | tr -d '\n'; }

# ansi=true lets a SINGLE line carry per-segment colors (unlike color=,
# which only styles the whole line). True-color (38;2;r;g;b) escape codes
# rendered wrong (cyan with a highlight box) — SwiftBar's ANSI support
# only handles the standard 16-color codes, not 24-bit truecolor.
ansi_bold() {
  local code="$1" text="$2"
  printf '\033[1;%dm%s\033[0m' "$code" "$text"
}

# Menu bar title — one Claude icon tinted to the dominant status, plus a
# per-status count breakdown, each number bold and colored to match its own
# circle (not just one line-wide color). Empty state: plain orange icon,
# no counts.
if [ ${#entries[@]} -eq 0 ]; then
  b64_dom=$(b64 "$tint_dir/claude-orange.png")
  [ -n "$b64_dom" ] && echo " | image=$b64_dom" || echo "🤖"
else
  if [ "$attn" -gt 0 ]; then dominant="$tint_dir/claude-red.png"
  elif [ "$work" -gt 0 ]; then dominant="$tint_dir/claude-yellow.png"
  else dominant="$tint_dir/claude-green.png"
  fi
  # ● (a plain text bullet, colored via ANSI) instead of the 🔴🟡🟢 emoji —
  # renders at normal text size instead of the emoji's fixed larger size.
  # It sits slightly above the digit baseline at menu-bar font size (how
  # solid-circle glyphs are drawn) — same trade-off as Slack/Discord-style
  # status dots next to text; U+2022 BULLET sits lower but reads too small.
  parts=()
  [ "$attn" -gt 0 ] && parts+=("$(ansi_bold 91 "●") $(ansi_bold 91 "$attn")")
  [ "$work" -gt 0 ] && parts+=("$(ansi_bold 93 "●") $(ansi_bold 93 "$work")")
  [ "$done_n" -gt 0 ] && parts+=("$(ansi_bold 92 "●") $(ansi_bold 92 "$done_n")")
  b64_dom=$(b64 "$dominant")
  if [ -n "$b64_dom" ]; then
    echo "${parts[*]} | ansi=true image=$b64_dom"
  else
    echo "🤖 ${parts[*]} | ansi=true"
  fi
fi

echo "---"

status_icon() {
  case "$1" in
    needs-attention) echo "$tint_dir/claude-red.png" ;;
    working)         echo "$tint_dir/claude-yellow.png" ;;
    *)               echo "$tint_dir/claude-green.png" ;;
  esac
}

render_row() {
  local status="$1" name="$2" sid="$3" cwd="$4"
  local b64_icon
  b64_icon=$(b64 "$(status_icon "$status")")
  echo "${name} | image=$b64_icon bash='$HOME/.claude/hooks/focus-agent.sh' param1='$sid' terminal=false"
  [ -n "$cwd" ] && echo "-- $cwd | size=10 color=#888888 bash='/usr/bin/open' param1='$cwd' terminal=false"
  echo "-- Dismiss | size=10 color=#c0392b bash='$HOME/.claude/hooks/dismiss-agent.sh' param1='$sid' terminal=false refresh=true"
}

print_group() {
  local target="$1" heading="$2" printed=0
  for e in "${entries[@]}"; do
    IFS='|' read -r status name sid cwd _pid <<< "$e"
    [ "$status" = "$target" ] || continue
    if [ "$printed" = 0 ]; then echo "$heading | size=11 color=#888888"; printed=1; fi
    render_row "$status" "$name" "$sid" "$cwd"
  done
  [ "$printed" = 1 ]
}

has_status() {
  local target="$1" e
  for e in "${entries[@]}"; do
    [ "${e%%|*}" = "$target" ] && return 0
  done
  return 1
}

printed_any=0
for target_heading in "needs-attention:Needs input" "working:Working" "completed:Completed"; do
  target="${target_heading%%:*}"
  heading="${target_heading#*:}"
  has_status "$target" || continue
  [ "$printed_any" = 1 ] && echo "---"
  print_group "$target" "$heading"
  printed_any=1
done

echo "---"
echo "Refresh | refresh=true"
echo "Open state dir | bash='/usr/bin/open' param1='$state_dir' terminal=false"
[ ${#entries[@]} -gt 0 ] && echo "Clear all | color=#c0392b bash='$HOME/.claude/hooks/dismiss-agent.sh' param1='--all' terminal=false refresh=true"
dismissed_count=$(wc -l < "$dismissed_file" | tr -d ' ')
[ "$dismissed_count" -gt 0 ] && echo "Restore dismissed ($dismissed_count) | bash='$HOME/.claude/hooks/dismiss-agent.sh' param1='--restore' terminal=false refresh=true"

echo "---"
echo "Settings"
current_sound=$(cat "$HOME/.claude/state/claudebar-sound" 2>/dev/null)
[ -z "$current_sound" ] && current_sound="Glass"
echo "-- Sound | size=11 color=#888888"
for s in Basso Blow Bottle Frog Funk Glass Hero Morse Ping Pop Purr Sosumi Submarine Tink; do
  mark=""
  [ "$s" = "$current_sound" ] && mark="✓ "
  echo "-- ${mark}${s} | bash='$HOME/.claude/hooks/set-sound.sh' param1='$s' terminal=false refresh=true"
done
