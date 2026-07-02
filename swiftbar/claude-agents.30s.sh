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
  # Drop any pipe characters from title to keep field parsing trivial.
  title="${title//|/-}"
  entries+=("$status|$ts|$title|$sid|$cwd")
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

# Menu bar title — empty state shows a robot, otherwise stack colored counts.
if [ ${#entries[@]} -eq 0 ]; then
  echo "🤖"
else
  parts=()
  [ "$attn" -gt 0 ] && parts+=("🔴 $attn")
  [ "$work" -gt 0 ] && parts+=("🟡 $work")
  [ "$idle" -gt 0 ] && parts+=("🟢 $idle")
  echo "${parts[*]}"
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
  local emoji="$2"
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
  while IFS='|' read -r ts title sid cwd; do
    [ -z "$ts" ] && continue
    local age
    age=$(age_human $((now - ts)))
    echo "$emoji  $title   ($age) | bash='$HOME/.claude/hooks/focus-agent.sh' param1='$sid' terminal=false"
    [ -n "$cwd" ] && echo "-- $cwd | size=10 color=#888888 bash='/usr/bin/open' param1='$cwd' terminal=false"
    echo "-- Dismiss | size=10 color=#c0392b bash='$HOME/.claude/hooks/dismiss-agent.sh' param1='$sid' terminal=false refresh=true"
  done <<< "$sorted"
  return 0
}

printed_any=0
if print_group "needs-attention" "🔴" "Needs attention"; then printed_any=1; fi
if [ "$work" -gt 0 ]; then
  [ "$printed_any" = 1 ] && echo "---"
  print_group "working" "🟡" "Working" && printed_any=1
fi
if [ "$idle" -gt 0 ]; then
  [ "$printed_any" = 1 ] && echo "---"
  print_group "idle" "🟢" "Idle" && printed_any=1
fi

echo "---"
echo "Refresh | refresh=true"
echo "Open state dir | bash='/usr/bin/open' param1='$state_dir' terminal=false"
[ ${#entries[@]} -gt 0 ] && echo "Clear all | color=#c0392b bash='$HOME/.claude/hooks/dismiss-agent.sh' param1='--all' terminal=false refresh=true"
