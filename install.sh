#!/bin/bash
# claudebar installer.
#   - copies the hook scripts to ~/.claude/hooks/
#   - installs the SwiftBar plugin
#   - merges the required hooks into ~/.claude/settings.json (idempotent, backed up)
#
# Re-running is safe: it replaces claudebar's own hooks and leaves yours alone.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
claude_dir="$HOME/.claude"
hooks_dir="$claude_dir/hooks"
settings="$claude_dir/settings.json"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (brew install jq)"; exit 1; }

echo "==> Installing hook scripts to $hooks_dir"
mkdir -p "$hooks_dir"
for f in notify.sh update-state.sh focus-agent.sh dismiss-agent.sh capture-statusline.sh; do
  install -m 0755 "$repo_dir/hooks/$f" "$hooks_dir/$f"
done

echo "==> Installing SwiftBar plugin"
plugin_dir="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
if [ -z "$plugin_dir" ]; then
  plugin_dir="$HOME/SwiftBar-plugins"
  echo "    SwiftBar plugin folder not set in preferences; defaulting to $plugin_dir"
  echo "    (Set it in SwiftBar → Preferences → Plugin Folder if this is wrong.)"
fi
mkdir -p "$plugin_dir"
install -m 0755 "$repo_dir/swiftbar/claude-agents.30s.sh" "$plugin_dir/claude-agents.30s.sh"
echo "    -> $plugin_dir/claude-agents.30s.sh"

echo "==> Merging hooks into $settings"
[ -f "$settings" ] || echo '{}' > "$settings"
cp "$settings" "$settings.bak.$(date +%s)"

merged="$(jq -s '
  def ours(cmd): cmd | test("\\.claude/hooks/(notify|update-state)\\.sh");
  (.[0] // {}) as $cur | .[1] as $add |
  $cur * {
    hooks: (
      ($cur.hooks // {}) as $ch |
      reduce ($add.hooks | keys[]) as $k (
        ($ch | with_entries(.value |= map(select(.hooks | any(.command | ours(.)) | not)))) ;
        .[$k] = ((.[$k] // []) + $add.hooks[$k])
      )
    )
  }
' "$settings" "$repo_dir/settings.hooks.json")"

printf '%s\n' "$merged" > "$settings"
echo "    backup saved next to settings.json"

echo
echo "Done. Restart any running Claude Code sessions so the hooks load."
echo "The 🤖 icon appears in your menu bar once SwiftBar is running."
