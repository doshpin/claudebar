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

entries=()
shopt -s nullglob
for f in "$state_dir"/*.json; do
  ts=$(jq -r '.last_event_ts // 0' "$f" 2>/dev/null)
  age=$((now - ts))
  if [ "$age" -gt "$max_age" ]; then
    rm -f "$f"
    continue
  fi
  status=$(jq -r '.status     // "idle"' "$f")
  title=$(jq  -r '.title      // ""'     "$f")
  sid=$(jq    -r '.session_id // ""'     "$f")
  cwd=$(jq    -r '.cwd        // ""'     "$f")
  kind=$(jq   -r '.kind       // "fg"'   "$f")
  # Drop any pipe characters from title to keep field parsing trivial.
  title="${title//|/-}"
  entries+=("$status|$ts|$title|$sid|$cwd|$kind")
done
shopt -u nullglob

attn=0; work=0; idle=0
for e in "${entries[@]}"; do
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

# Menu bar title — dominant-status tinted Claude icon plus the total
# session count. Empty state: plain orange Claude icon, no count.
if [ ${#entries[@]} -eq 0 ]; then
  b64_dom=$(b64 "$tint_dir/claude-orange.png")
  [ -n "$b64_dom" ] && echo " | image=$b64_dom" || echo "🤖"
else
  if [ "$attn" -gt 0 ]; then dominant="$tint_dir/claude-red.png"
  elif [ "$work" -gt 0 ]; then dominant="$tint_dir/claude-yellow.png"
  else dominant="$tint_dir/claude-green.png"
  fi
  total=${#entries[@]}
  b64_dom=$(b64 "$dominant")
  if [ -n "$b64_dom" ]; then
    echo "$total | image=$b64_dom"
  else
    echo "🤖 $total"
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

print_group() {
  local target="$1"
  local color="$2"
  local heading="$3"
  local list=()
  for e in "${entries[@]}"; do
    local s="${e%%|*}"
    [ "$s" = "$target" ] || continue
    list+=("${e#*|}")
  done
  [ ${#list[@]} -eq 0 ] && return 1
  echo "$heading | size=11 color=#888888"
  # Sort newest first (numeric on ts).
  local sorted
  IFS=$'\n' sorted=$(printf '%s\n' "${list[@]}" | sort -t'|' -k1,1 -nr)
  while IFS='|' read -r ts title sid cwd kind; do
    [ -z "$ts" ] && continue
    local age sym sfconfig
    age=$(age_human $((now - ts)))
    # </> = a normal foreground terminal session,
    # sparkles = background/forked (Agent tool, bg job).
    [ "$kind" = "bg" ] && sym="sparkles" || sym="chevron.left.forwardslash.chevron.right"
    # sfimage alone renders as a template image (forced monochrome by macOS,
    # ignoring color=). Palette rendering mode is what actually lets an SF
    # Symbol take a custom tint on this SwiftBar version.
    sfconfig=$(printf '{"renderingMode":"Palette","colors":["%s"]}' "$color" | base64 | tr -d '\n')
    echo "$title   ($age) | sfimage=$sym sfconfig=$sfconfig bash='$HOME/.claude/hooks/focus-agent.sh' param1='$sid' terminal=false"
    [ -n "$cwd" ] && echo "-- $cwd | size=10 color=#888888 bash='/usr/bin/open' param1='$cwd' terminal=false"
    echo "-- Dismiss | size=10 color=#c0392b bash='$HOME/.claude/hooks/dismiss-agent.sh' param1='$sid' terminal=false refresh=true"
  done <<< "$sorted"
  return 0
}

printed_any=0
if print_group "needs-attention" "#e74c3c" "Needs attention"; then printed_any=1; fi
if [ "$work" -gt 0 ]; then
  [ "$printed_any" = 1 ] && echo "---"
  print_group "working" "#f1c40f" "Working" && printed_any=1
fi
if [ "$idle" -gt 0 ]; then
  [ "$printed_any" = 1 ] && echo "---"
  print_group "idle" "#2ecc71" "Idle" && printed_any=1
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
