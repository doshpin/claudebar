#!/bin/bash
# claudebar uninstaller. Removes claudebar's hooks from settings.json (leaving
# yours intact), deletes the scripts, the SwiftBar plugin, and session state.
set -euo pipefail

claude_dir="$HOME/.claude"
settings="$claude_dir/settings.json"

if [ -f "$settings" ] && command -v jq >/dev/null 2>&1; then
  echo "==> Removing claudebar hooks from $settings"
  cp "$settings" "$settings.bak.$(date +%s)"
  jq '
    def ours(cmd): cmd | test("\\.claude/hooks/(notify|update-state)\\.sh");
    if .hooks then
      .hooks |= (with_entries(.value |= map(select(.hooks | any(.command | ours(.)) | not)))
                 | with_entries(select(.value | length > 0)))
    else . end
  ' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
fi

echo "==> Removing hook scripts"
rm -f "$claude_dir/hooks/notify.sh" "$claude_dir/hooks/update-state.sh" \
      "$claude_dir/hooks/focus-agent.sh" "$claude_dir/hooks/dismiss-agent.sh"

echo "==> Removing session state"
rm -rf "$claude_dir/state/agents"

plugin_dir="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || echo "$HOME/SwiftBar-plugins")"
echo "==> Removing SwiftBar plugin"
rm -f "$plugin_dir/claude-agents.30s.sh"

echo "Done. Restart Claude Code sessions to drop the hooks."
