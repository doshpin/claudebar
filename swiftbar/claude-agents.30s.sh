#!/bin/bash
# <xbar.title>claudebar</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>claudebar</xbar.author>
# <xbar.desc>Menu-bar dashboard for every running Claude Code session.</xbar.desc>
# Refreshed every 30s as a fallback; hooks trigger immediate refresh via swiftbar:// URL.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

state_dir="$HOME/.claude/state/agents"
mkdir -p "$state_dir"

now=$(date +%s)
max_age=$((24 * 3600))   # prune stale entries after 24h

# ponytail: tried verifying each session has a live backing process (via
# --session-id in `ps`, or a live fork's --resume path) to catch ghost
# entries. Reverted — a plain `claude` invocation with no --resume never
# shows a session id in `ps` at all (confirmed: cwd is visible via lsof,
# but nothing ties it to a specific session id, not even open transcript
# files), so the check was deleting live sessions' state files on every
# refresh. Unreliable-and-destructive is worse than not having it. Back to
# only the safe age-based prune below.

entries=()
shopt -s nullglob
for f in "$state_dir"/*.json; do
  ts=$(jq -r '.last_event_ts // 0' "$f" 2>/dev/null)
  age=$((now - ts))
  if [ "$age" -gt "$max_age" ]; then
    rm -f "$f"
    continue
  fi
  status=$(jq -r '.status            // "idle"' "$f")
  title=$(jq  -r '.title             // ""'     "$f")
  sid=$(jq    -r '.session_id        // ""'     "$f")
  cwd=$(jq    -r '.cwd               // ""'     "$f")
  kind=$(jq   -r '.kind              // "fg"'   "$f")
  parent=$(jq -r '.parent_session_id // ""'     "$f")
  # Drop any pipe characters from title to keep field parsing trivial.
  title="${title//|/-}"
  entries+=("$status|$ts|$title|$sid|$cwd|$kind|$parent")
done
shopt -u nullglob

# sessionKind "bg" does NOT mean "disposable sub-agent" — a real, hour-long
# agent-view session someone is actively chatting in also carries that tag.
# So a bg entry only gets folded away when it's a genuine duplicate: a
# fork-to-background copy of a conversation whose original is ALSO
# currently visible (found via its --resume path in its own process
# ancestry — see update-state.sh). Every other bg entry, including a
# standalone agent-view session with no such parent, is a real session and
# shows as a normal top-level row.
all_sids="|"
for e in "${entries[@]}"; do
  IFS='|' read -r _ _ _ sid _ _ _ <<< "$e"
  all_sids="${all_sids}${sid}|"
done

top_level=()
for e in "${entries[@]}"; do
  IFS='|' read -r _ _ _ _ _ kind parent <<< "$e"
  if [ "$kind" = "bg" ] && [ -n "$parent" ] && [[ "$all_sids" == *"|$parent|"* ]]; then
    continue   # genuine duplicate — folded into its live parent's "· N running" suffix
  fi
  top_level+=("$e")
done

child_count_of() {
  local parent_sid="$1" n=0
  for e in "${entries[@]}"; do
    IFS='|' read -r _ _ _ _ _ kind parent <<< "$e"
    [ "$kind" = "bg" ] && [ "$parent" = "$parent_sid" ] && n=$((n+1))
  done
  echo "$n"
}

attn=0; work=0; idle=0
for e in "${top_level[@]}"; do
  s="${e%%|*}"
  case "$s" in
    needs-attention) attn=$((attn+1)) ;;
    working)         work=$((work+1)) ;;
    idle)            idle=$((idle+1)) ;;
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
if [ ${#top_level[@]} -eq 0 ]; then
  b64_dom=$(b64 "$tint_dir/claude-orange.png")
  [ -n "$b64_dom" ] && echo " | image=$b64_dom" || echo "🤖"
else
  if [ "$attn" -gt 0 ]; then dominant="$tint_dir/claude-red.png"
  elif [ "$work" -gt 0 ]; then dominant="$tint_dir/claude-yellow.png"
  else dominant="$tint_dir/claude-green.png"
  fi
  # ● (a plain text bullet, colored via ANSI) instead of the 🔴🟡🟢 emoji —
  # renders at normal text size instead of the emoji's fixed larger size.
  parts=()
  [ "$attn" -gt 0 ] && parts+=("$(ansi_bold 91 "●") $(ansi_bold 91 "$attn")")
  [ "$work" -gt 0 ] && parts+=("$(ansi_bold 93 "●") $(ansi_bold 93 "$work")")
  [ "$idle" -gt 0 ] && parts+=("$(ansi_bold 92 "●") $(ansi_bold 92 "$idle")")
  b64_dom=$(b64 "$dominant")
  if [ -n "$b64_dom" ]; then
    echo "${parts[*]} | ansi=true image=$b64_dom"
  else
    echo "🤖 ${parts[*]} | ansi=true"
  fi
fi

echo "---"

age_human() {
  local s="$1"
  if [ "$s" -lt 60 ];   then echo "${s}s"
  elif [ "$s" -lt 3600 ]; then echo "$((s/60))m"
  elif [ "$s" -lt 86400 ]; then echo "$((s/3600))h"
  else echo "$((s/86400))d"
  fi
}

status_icon() {
  case "$1" in
    needs-attention) echo "$tint_dir/claude-red.png" ;;
    working)         echo "$tint_dir/claude-yellow.png" ;;
    *)               echo "$tint_dir/claude-green.png" ;;
  esac
}

# One row per real session: colored Claude icon (same tinting as the menu
# bar badge — bg is folded into the "· N running" suffix, so there's no
# more need for a separate shape to distinguish it), cwd, Dismiss.
render_row() {
  local status="$1" ts="$2" title="$3" sid="$4" cwd="$5"
  local age b64_icon n suffix=""
  age=$(age_human $((now - ts)))
  b64_icon=$(b64 "$(status_icon "$status")")
  n=$(child_count_of "$sid")
  [ "$n" -gt 0 ] && suffix="  · $n running"
  echo "${title}${suffix}   (${age}) | image=$b64_icon bash='$HOME/.claude/hooks/focus-agent.sh' param1='$sid' terminal=false"
  [ -n "$cwd" ] && echo "-- $cwd | size=10 color=#888888 bash='/usr/bin/open' param1='$cwd' terminal=false"
  echo "-- Dismiss | size=10 color=#c0392b bash='$HOME/.claude/hooks/dismiss-agent.sh' param1='$sid' terminal=false refresh=true"
}

print_group() {
  local target="$1"
  local heading="$2"
  local list=()
  for e in "${top_level[@]}"; do
    local s="${e%%|*}"
    [ "$s" = "$target" ] || continue
    list+=("${e#*|}")
  done
  [ ${#list[@]} -eq 0 ] && return 1
  echo "$heading | size=11 color=#888888"
  # Sort newest first (numeric on ts).
  local sorted
  IFS=$'\n' sorted=$(printf '%s\n' "${list[@]}" | sort -t'|' -k1,1 -nr)
  while IFS='|' read -r ts title sid cwd _kind _parent; do
    [ -z "$ts" ] && continue
    render_row "$target" "$ts" "$title" "$sid" "$cwd"
  done <<< "$sorted"
  return 0
}

printed_any=0
if print_group "needs-attention" "Needs attention"; then printed_any=1; fi
if [ "$work" -gt 0 ]; then
  [ "$printed_any" = 1 ] && echo "---"
  print_group "working" "Working" && printed_any=1
fi
if [ "$idle" -gt 0 ]; then
  [ "$printed_any" = 1 ] && echo "---"
  print_group "idle" "Idle" && printed_any=1
fi

echo "---"
echo "Refresh | refresh=true"
echo "Open state dir | bash='/usr/bin/open' param1='$state_dir' terminal=false"
[ ${#entries[@]} -gt 0 ] && echo "Clear all | color=#c0392b bash='$HOME/.claude/hooks/dismiss-agent.sh' param1='--all' terminal=false refresh=true"

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
