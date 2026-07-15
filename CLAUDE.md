# claudebar

SwiftBar runs the **installed** copies, not the repo. After editing any file
under `hooks/` or `swiftbar/`, sync it to the live location or the change has
no effect:

- `hooks/*.sh` → `~/.claude/hooks/`
- `swiftbar/claude-agents.30s.sh` → SwiftBar plugin dir
  (`defaults read com.ameba.SwiftBar PluginDirectory`, else `~/SwiftBar-plugins`)

Either run `./install.sh` (re-syncs everything) or `install -m 0755 <src> <dest>`
the changed files, then refresh: `open -g 'swiftbar://refreshplugin?name=claude-agents'`.
