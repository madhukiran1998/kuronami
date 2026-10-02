# Hyperterm

A native macOS terminal for running many Claude Code and Codex sessions, shells, and dev servers at once. Every terminal has a label like `@api`. The sidebar shows what each one is doing and which ones need you. Agents can message each other by label.

Terminal rendering is [libghostty](https://github.com/ghostty-org/ghostty), Ghostty's own GPU (Metal) engine. It reads your `~/.config/ghostty/config`, so your fonts, theme, and keybinds carry over.

## What it does

- **Labeled terminals.** Each one is a Claude Code agent, a Codex agent, a shell, or a server. The label is the name you see, the name `ht` uses, and the name agents use. Claude sessions start as `claude --name <label>`, so Claude's built-in `SendMessage` / `@mentions` resolve to the same label.
- **Live status.** Each terminal shows one of: working, needs you (with the actual question), idle with a one-line summary of the last reply, failed, or exited. "Needs you" rows float to the top and turn orange. You also get a macOS notification and a Dock badge. ⌘⇧U jumps to the session that has been waiting longest.
- **Servers and ports.** Listening ports are found per terminal from its process tree. Click a port chip to open it. A server that crashes turns red and notifies you.
- **Layouts.** Focus (one terminal), Split (the last two), or Grid (every live terminal as a tile with its own header). ⌘⌥1/2/3 switch layouts, and ⌘⏎ zooms a tile in and out.
- **Agents talk to each other.** Each agent gets a `hyperterm` MCP server with these tools: `list_terminals`, `send_message`, `read_terminal`, `restart_server`, and `start_server`. Messages arrive as "Message from @ui (Claude Code, via Hyperterm): …". If the target agent is blocked on a permission prompt, the message waits until it unblocks.
- **Agents name their own terminals.** If you don't name a terminal, it starts with a placeholder (the folder name). The agent calls `rename_terminal` when it starts a task, and again when its focus changes, e.g. `@auth-refactor` then `@fix-login`. Old names keep working as aliases. Claude Code is told to `/rename` at its next idle prompt, so its native name stays in sync. A name you set yourself is never overridden; choose "Let Agent Name It" in the row's menu to hand naming back.
- **Resume.** Terminals are restored when you reopen the app. Claude conversations come back with `--resume` and Codex threads with `codex resume`.
- **⌘P switcher.** Jump to a terminal, run an action, or type `@api fix the failing test` to send that message.

## How status is detected

| Signal | Used for |
|---|---|
| Claude hooks (`UserPromptSubmit`, `PostToolUse`, `Notification`, `Stop`, `StopFailure`, `SessionEnd`) | Precise turn state, permission prompts, last-message summary |
| Codex `notify` + TUI OSC 9 notifications | Turn complete (with summary and thread id), approval requests |
| `~/.claude/sessions/<pid>.json` | Corrects drift (busy vs. idle) |
| Process tree + `lsof` | Ports, foreground command, agent quit back to its shell |
| Return pressed in the terminal | Provisional "working" until the next hook |

The state machine is a pure function (`Sources/Hyperterm/Status/StatusReducer.swift`) with unit tests.

## Nothing global is modified

Hooks and the MCP server are attached per launch through wrappers in `~/.hyperterm/bin`:

- `claude` runs the real Claude Code with `--settings ~/.hyperterm/claude-settings.json --mcp-config ~/.hyperterm/mcp.json`. These merge with your own settings, and your existing hooks still run.
- `codex` runs the real Codex with `-c notify=…`, OSC 9 notifications, and the MCP server.

Your `~/.claude/settings.json` and `~/.codex/config.toml` are never written.

## Security model

The control socket (`~/.hyperterm/control.sock`, mode 0600) identifies callers by **kernel peer PID and process ancestry**, never by what the caller claims. A command run by an agent is attributed to that agent's terminal, and agents can:

- message other agents, read any terminal, and start or restart servers.

Agents can't:

- type into shells or servers, press keys, or close terminals. That would let one agent answer another's permission prompt, or run commands outside its own permission checks.

Peer messages are framed as coming from another agent, so they can't grant permissions.

## `ht` CLI

Add `export PATH="$HOME/.hyperterm/bin:$PATH"` to `~/.zshrc`.

```
ht ls                                  # label · kind · state · ports · summary
ht new claude @api --cwd ~/Code/app    # also: codex, shell, server -- pnpm dev
ht send @api "the schema changed: users.name is now display_name"
ht read @web -n 50                     # recent output
ht key @api down enter                 # answer a prompt
ht layout grid                         # focus | split | grid
ht restart @web · ht focus @ui · ht rename @api backend · ht close @scratch
```

## Build

Requires Xcode 16+, XcodeGen, and Zig 0.15.2 (`brew install xcodegen zig@0.15`).

```sh
scripts/build-ghosttykit.sh   # once: builds libghostty (Ghostty v1.3.1, ReleaseFast) into GhosttyKit.xcframework
scripts/run.sh                # build + launch (CONFIG=Release for an optimized build)
xcodebuild -project Hyperterm.xcodeproj -scheme Hyperterm -derivedDataPath build/DerivedData test
```

## Layout

```
Sources/Hyperterm/Ghostty   libghostty bridge: runtime callbacks, action router, NSView surface (input/IME/mouse)
Sources/Hyperterm/Model     LaunchSpec, TerminalSession, SessionStore (labels, layout, persistence, hooks)
Sources/Hyperterm/Status    StatusReducer (pure), ProcessInspector (ports, ancestry), notifications
Sources/Hyperterm/IPC       control socket server + request handler/permissions
Sources/Hyperterm/Launch    agent wrappers, hooks, and MCP config generation
Sources/Hyperterm/UI        sidebar, toolbar, tiles/grid, quick switcher, new-terminal sheet
Sources/ht                  CLI + stdio MCP server
```

Input handling in `TerminalSurfaceView.swift` and `GhosttyInput.swift` is adapted from Ghostty's macOS app (MIT).
