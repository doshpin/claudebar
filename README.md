# claudebar

A macOS menu-bar dashboard + desktop notifications for [Claude Code](https://claude.com/claude-code).

Run several Claude Code sessions at once and you lose track of which one is
waiting on you. claudebar puts a live status in your menu bar and pings you the
moment a session needs attention or finishes a turn.

```
🔴 1  🟡 2  🟢 3        ← menu bar: 1 needs you, 2 working, 3 idle
────────────────
Needs attention
  🔴  fix-auth-bug        (4s)
────────────────
Working
  🟡  refactor-parser     (12s)
  🟡  write-tests         (30s)
────────────────
Idle
  🟢  update-readme       (2m)
```

- 🔴 **needs attention** — a permission prompt is waiting
- 🟡 **working** — actively running
- 🟢 **idle** — finished its turn

You also get a native macOS notification on **needs attention** and **turn
complete**, titled with the session's name. Click a session in the menu (or the
notification) to **jump straight to its terminal** — if you run WezTerm + tmux
(see [Click-to-focus](#click-to-focus)).

## How it works

Three moving parts, all plain shell:

1. **Claude Code hooks** fire on session events (`Stop`, `Notification`,
   `UserPromptSubmit`, …) and call two scripts.
2. `update-state.sh` writes a small JSON file per session under
   `~/.claude/state/agents/` describing its status and terminal location.
3. A **SwiftBar plugin** reads those files and renders the menu. `notify.sh`
   sends the desktop notification.

No daemon, no background process — the hooks do the work, and SwiftBar polls
every 30s as a fallback (hooks also nudge it to refresh instantly).

## Requirements

- **macOS**
- **[SwiftBar](https://github.com/swiftbar/SwiftBar)** — `brew install --cask swiftbar`
- **jq** — `brew install jq`
- **[terminal-notifier](https://github.com/julienXX/terminal-notifier)** *(optional but recommended)* — `brew install terminal-notifier`
  Without it, notifications still work via `osascript` but clicking them won't focus your terminal.
- **WezTerm + tmux** *(optional)* — only needed for [click-to-focus](#click-to-focus). Everything else works in any terminal.

## Install

```sh
git clone https://github.com/doshpin/claudebar.git
cd claudebar
./install.sh
```

The installer:
- copies the hook scripts to `~/.claude/hooks/`
- installs the SwiftBar plugin to your SwiftBar plugin folder
- merges the required hooks into `~/.claude/settings.json` (your existing
  settings and hooks are preserved; a timestamped backup is written next to it)

Then:
1. Launch **SwiftBar** and point it at your plugin folder if it asks. A 🤖 icon
   appears in the menu bar.
2. **Restart any running Claude Code sessions** so they pick up the new hooks.

That's it. Start a session and watch the menu bar.

## Uninstall

```sh
./uninstall.sh
```

Removes claudebar's hooks (leaving any hooks you added yourself), the scripts,
the SwiftBar plugin, and the session state. A settings backup is written first.

## Click-to-focus

Clicking a session — in the menu or the notification — activates its terminal
and switches to the exact tmux pane it's running in. This part is specific to
**WezTerm + tmux**, because it uses `wezterm cli` and `tmux switch-client`.

If you use a different terminal, everything else still works; clicking is just a
no-op. The terminal location is captured from `$WEZTERM_PANE` / `$TMUX` when each
hook runs, so no configuration is needed — it only lights up if those are present.

Want it for your terminal? `hooks/focus-agent.sh` is ~40 lines and the one place
to adapt. PRs welcome.

## Model / context / cost detail

Each session's row can expand into the same numbers your terminal's
statusLine already shows: model, effort, context % (with token counts),
cost, elapsed time, and lines changed. Repo/branch is always shown (read
straight from the session's `cwd`), no setup required.

The rest needs one line added to your own `statusLine` script, right after
it reads stdin, so claudebar sees the same numbers your terminal does:

```sh
input=$(cat)
printf '%s' "$input" | "$HOME/.claude/hooks/capture-statusline.sh" &
```

That's it — no further config. It's a no-op for sessions claudebar isn't
tracking, and for anyone who hasn't wired it up, those lines just don't
appear. There's no cost estimate without this: reproducing Claude Code's
own cache-aware pricing from a transcript alone isn't worth it — this reads
the number Claude Code itself already computed.

The account-wide 5-hour rate limit usage shows up once (menu bar + dropdown)
rather than per session. Settings → 5h usage lets you switch it between
showing the reset countdown, percent only, or hiding it entirely.

## Configuration

It's shell scripts — edit them directly.

| Want to change | Where |
|---|---|
| Notification sounds | `hooks/notify.sh` args in `settings.hooks.json` (e.g. `'Glass'`, `'Funk'`) |
| Which events notify you | `settings.hooks.json` (add/remove `notify.sh` lines) |
| Menu layout / colors / grouping | `swiftbar/claude-agents.30s.sh` |
| SwiftBar refresh interval | rename the plugin file — `claude-agents.30s.sh` → `.10s.sh` |
| Stale-session prune window | `max_age` in the SwiftBar plugin (default 24h) |

After editing `settings.hooks.json`, re-run `./install.sh` to re-apply.

## Files

```
hooks/
  notify.sh          desktop notification for an event
  update-state.sh    writes per-session state JSON (drives the menu)
  focus-agent.sh     jump to a session's WezTerm tab + tmux pane
  dismiss-agent.sh   remove a session from the dashboard
  capture-statusline.sh   optional: model/cost/context detail from your statusline
swiftbar/
  claude-agents.30s.sh   the menu-bar plugin
settings.hooks.json  the hooks block merged into ~/.claude/settings.json
install.sh / uninstall.sh
```

## License

MIT
