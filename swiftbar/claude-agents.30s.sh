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
# session — what the desktop app's Needs input / Working / Completed
# groups show) and "interactive" (a plain terminal tab running claude, which
# the desktop app's agent view does NOT list as a session at all). Matching
# the desktop app 1:1 means showing only "background" here too — otherwise
# every idle terminal tab you forgot about shows up as a phantom "session".
agents_json=$(claude agents --json --all 2>/dev/null | jq -c '[.[] | select(.kind=="background")]')
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
  sanitized=$(printf '%s' "$cwd" | sed 's|[/.]|-|g')
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

entries=()
# Tab is "IFS whitespace" to bash's `read`, so consecutive tabs (an empty
# field, e.g. .pid missing on a respawned session) get squeezed into one
# delimiter instead of preserved as an empty field — silently shifting
# every later column left by one. Force every field non-empty with a "-"
# sentinel so no column is ever truly blank, then strip the sentinel back.
while IFS=$'\t' read -r sid name cwd pid state id; do
  [ -z "$sid" ] && continue
  is_dismissed "$sid" && continue
  [ "$pid" = "-" ] && pid=""
  [ "$id" = "-" ] && id=""
  case "$state" in
    blocked) status="needs-attention" ;;
    working) status="working" ;;
    *)       status="completed" ;;
  esac
  if [ "$name" = "$id" ]; then
    resolved=$(resolve_title "$sid" "$cwd")
    [ -n "$resolved" ] && name="$resolved"
  fi
  name="${name//|/-}"
  entries+=("$status|$name|$sid|$cwd|$pid")
done < <(printf '%s' "$agents_json" | jq -r '.[] | [.sessionId, .name, .cwd, (.pid // "-" | tostring), (.state // "done"), (.id // "-")] | @tsv')

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

# Account-wide 5-hour usage — same number for every session, computed once
# here (not per-session) and shown both in the menu bar title and, more
# fully, in the dropdown below. Only present once
# hooks/capture-statusline.sh has been wired up (see its header comment).
fiveh_file="$HOME/.claude/state/claudebar-fiveh.json"
fiveh_title="" fiveh_line=""
if [ -f "$fiveh_file" ]; then
  fiveh_pct=$(jq -r '.used_percentage // empty' "$fiveh_file" 2>/dev/null)
  fiveh_resets=$(jq -r '.resets_at // empty' "$fiveh_file" 2>/dev/null)
  if [ -n "$fiveh_pct" ]; then
    fiveh_hex="#30d158" fiveh_ansi=92
    p="${fiveh_pct%.*}"
    if [ "$p" -ge 80 ]; then fiveh_hex="#ff453a"; fiveh_ansi=91
    elif [ "$p" -ge 65 ]; then fiveh_hex="#ff9f0a"; fiveh_ansi=93
    elif [ "$p" -ge 50 ]; then fiveh_hex="#ffd60a"; fiveh_ansi=93
    fi
    fiveh_pct_fmt="$(printf '%.0f' "$fiveh_pct")"
    fiveh_remain=""
    if [ -n "$fiveh_resets" ]; then
      remain_min=$(( (${fiveh_resets%.*} - $(date +%s)) / 60 ))
      [ "$remain_min" -lt 0 ] && remain_min=0
      fiveh_remain=" (${remain_min}m)"
    fi
    fiveh_title="$(ansi_bold "$fiveh_ansi" "⏳${fiveh_pct_fmt}%${fiveh_remain}")"
    fiveh_line="⏳ ${fiveh_pct_fmt}%${fiveh_remain}"
  fi
fi

# Menu bar title — one Claude icon tinted to the dominant status, plus a
# per-status count breakdown, each number bold and colored to match its own
# circle (not just one line-wide color), plus the 5-hour usage if known.
# Empty state: plain orange icon, no counts.
if [ ${#entries[@]} -eq 0 ]; then
  b64_dom=$(b64 "$tint_dir/claude-orange.png")
  if [ -n "$b64_dom" ]; then
    echo "$fiveh_title | ansi=true image=$b64_dom"
  else
    echo "🤖 $fiveh_title | ansi=true"
  fi
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
  [ -n "$fiveh_title" ] && parts+=("$fiveh_title")
  b64_dom=$(b64 "$dominant")
  if [ -n "$b64_dom" ]; then
    echo "${parts[*]} | ansi=true image=$b64_dom"
  else
    echo "🤖 ${parts[*]} | ansi=true"
  fi
fi

echo "---"

# The fuller 5h line (with reset countdown) belongs only in the dropdown —
# anything printed before the FIRST "---" is treated as a menu bar title
# line in SwiftBar/xbar and cycles with the icon+dots line above, which is
# not what we want here.
if [ -n "$fiveh_line" ]; then
  echo "$fiveh_line | size=12 color=$fiveh_hex"
  echo "---"
fi

status_icon() {
  case "$1" in
    needs-attention) echo "$tint_dir/claude-red.png" ;;
    working)         echo "$tint_dir/claude-yellow.png" ;;
    *)               echo "$tint_dir/claude-green.png" ;;
  esac
}

# Per-session detail lines — the exact numbers your terminal statusLine
# shows (effort / context% / cost / duration / lines changed), not a
# reconstruction. Only present if hooks/capture-statusline.sh has been
# wired into the user's own statusline script (see its header comment);
# a no-op otherwise, so no extra lines appear.
fmt_duration() {
  local ms="$1" s m
  s=$(( ${ms%.*} / 1000 ))
  m=$(( s / 60 ))
  if [ "$m" -ge 60 ]; then printf '%sh%sm' "$((m / 60))" "$((m % 60))"
  else printf '%sm%ss' "$m" "$((s % 60))"
  fi
}

fmt_tok() {
  local n="${1%.*}"
  if [ "$n" -ge 1000000 ]; then printf '%sm' "$((n / 1000000))"
  elif [ "$n" -ge 1000 ]; then printf '%sk' "$((n / 1000))"
  else printf '%s' "$n"
  fi
}

# Same context-%  thresholds as a typical statusline: cools from red (nearly
# full) down to green (plenty of room left).
ctx_color() {
  local p="${1%.*}"
  if [ "$p" -ge 70 ]; then echo "#ff453a"
  elif [ "$p" -ge 50 ]; then echo "#ff9f0a"
  elif [ "$p" -ge 35 ]; then echo "#ffd60a"
  else echo "#30d158"
  fi
}

# Repo + branch, read straight from cwd's own git checkout — always
# available regardless of whether capture-statusline.sh is wired up.
repo_branch_line() {
  local cwd="$1" repo branch
  [ -d "$cwd" ] || return
  repo=$(basename -s .git "$(git -C "$cwd" remote get-url origin 2>/dev/null)" 2>/dev/null)
  [ -z "$repo" ] && repo=$(basename "$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
  branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
  [ -z "$repo" ] && [ -z "$branch" ] && return
  printf '%s\t%s' "$repo" "$branch"
}

render_detail_lines() {
  local sid="$1" cwd="$2" f="$state_dir/$sid.json"
  [ -f "$f" ] || return
  local model effort ctx tok_in tok_out cost dur lines_added lines_removed repo branch
  model=$(jq -r '.model // empty' "$f" 2>/dev/null)
  effort=$(jq -r '.effort // empty' "$f" 2>/dev/null)
  ctx=$(jq -r '.context_pct // empty' "$f" 2>/dev/null)
  tok_in=$(jq -r '.tok_in // empty' "$f" 2>/dev/null)
  tok_out=$(jq -r '.tok_out // empty' "$f" 2>/dev/null)
  cost=$(jq -r '.cost_usd // empty' "$f" 2>/dev/null)
  dur=$(jq -r '.duration_ms // empty' "$f" 2>/dev/null)
  lines_added=$(jq -r '.lines_added // empty' "$f" 2>/dev/null)
  lines_removed=$(jq -r '.lines_removed // empty' "$f" 2>/dev/null)
  IFS=$'\t' read -r repo branch <<< "$(repo_branch_line "$cwd")"

  if [ -n "$model" ]; then
    local model_line="🤖 $model"
    [ -n "$effort" ] && model_line="$model_line - $effort"
    echo "-- $model_line | size=12 color=#5ac8fa"
  fi
  [ -n "$ctx" ] && echo "-- 🧠 $(printf '%.0f' "$ctx")% ctx | size=12 color=$(ctx_color "$ctx")"
  if [ -n "$tok_in" ] || [ -n "$tok_out" ]; then
    echo "-- 🔢 $(fmt_tok "${tok_in:-0}") in / $(fmt_tok "${tok_out:-0}") out | size=12 color=#e5e5e7"
  fi
  [ -n "$cost" ] && echo "-- 💰 \$$(printf '%.2f' "$cost") | size=12 color=#e5e5e7"
  [ -n "$dur" ] && echo "-- ⏱️ $(fmt_duration "$dur") | size=12 color=#e5e5e7"
  [ -n "$repo" ] && echo "-- 📦 $repo | size=12 color=#e5e5e7"
  [ -n "$branch" ] && echo "-- 🌿 $branch | size=12 color=#e5e5e7"
  if [ -n "$lines_added" ] || [ -n "$lines_removed" ]; then
    echo "-- 📝 $(ansi_bold 92 "+${lines_added:-0}") $(ansi_bold 91 "-${lines_removed:-0}") | size=12 ansi=true"
  fi
}

render_row() {
  local status="$1" name="$2" sid="$3" cwd="$4"
  local b64_icon
  b64_icon=$(b64 "$(status_icon "$status")")
  echo "${name} | image=$b64_icon bash='$HOME/.claude/hooks/focus-agent.sh' param1='$sid' terminal=false"
  [ -n "$cwd" ] && echo "-- $cwd | size=10 color=#888888 bash='/usr/bin/open' param1='$cwd' terminal=false"
  render_detail_lines "$sid" "$cwd"
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
