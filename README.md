# Kuronami

*Kuronami (黒波): "black wave". Many agents moving at once, on one dark surface.*

**A native macOS terminal for running many coding agents at once.** Claude Code, Codex, shells and dev servers each get a labeled terminal (`@api`, `@landing-page`). Kuronami shows what every agent is doing, brings you the ones that need you, lets you approve and review their work without switching terminals, lets agents message each other by label, and gives each agent a real Chromium browser you can watch and take over.

![Kuronami in grid view: three agents in resizable tiles, one waiting on an approval, the inspector open, and a dev server on the shelf](docs/screenshot.png)

Terminals render with **libghostty**, Ghostty's own GPU (Metal) engine. Your `~/.config/ghostty/config` (fonts, theme, keybinds) applies as-is. Browsers are embedded **Chromium** (CEF), started only when first used. The app chrome is native AppKit and SwiftUI in a **Graphite** look: neutral black and charcoal, so color only ever means something (an agent's state, which agent it is, where focus is), with rounded floating panes, a unified toolbar, a shelf for servers and minimized tiles, and an inspector.

## Why

Running several agents in parallel moves the bottleneck from typing to **attention and review**. You need to know which agent is blocked on an approval, which one finished with a diff to look at, and which one is burning your rate limit. Kuronami is built around those questions instead of around tabs.

## Features

### See every agent at a glance
- **Sidebar of agents, grouped by repository.** Each card shows the agent's state (working, waiting on you, done, failed), what it's doing right now (`Bash: pnpm test`, `Edit: src/auth.ts`), its own status line, Claude's todo progress (`3/5 · Writing migration`), branch, test result, and cost.
- **Stable positions.** Cards never reorder when states change, so ⌘1–9 and muscle memory keep working. Attention is shown, not sorted.
- **Grid, split, or focus.** Every live terminal as a tile (⌘⌥3), the last two side by side (⌘⌥2), or one (⌘⌥1). ⌘⏎ zooms a tile.
- **Resize anything.** Drag the gap between two tiles to resize them; it snaps to halves and thirds, and double-clicking evens that split out again. ⌥⌘0 evens out every tile. Split and grid each remember their own arrangement across launches.
- **Arrange it your way.** Drag a tile by its header and drop it on another to trade places. Minimize a tile (⇧⌘M or the – on its header) to park it on the shelf under the canvas, next to your dev servers; click it there, or in the sidebar, to bring it back.
- **Since you left.** Come back to an agent and a banner sums up what happened: edits, commands, approvals, tests, and the final answer.

### Start agents the way you want
- **Several agents on one task.** The sidebar composer can hand a task to Claude, Codex, or several of each at once. Each gets its own worktree, so you compare their results side by side in the grid and merge the best one.
- **Permissions, model and effort per agent.** *Ask First*, *Accept Edits*, *Plan* or *Full Access*, translated to each CLI's own flags (`--permission-mode` for Claude; approval and sandbox flags for Codex). Pick a model (Claude's `opus`/`sonnet`/`haiku` aliases, or any name) and, for Codex, reasoning effort. Leave them alone and the agent's own config applies.
- **Plans you approve.** An agent in plan mode shows *Plan ready* on its card with *Approve Plan* and *Keep Planning*; the inspector's Plan tab shows the whole plan.
- **Fork a conversation.** Right-click a Claude agent → *Fork Conversation* starts a new agent that continues from this point (`--resume --fork-session`); the original carries on unchanged.
- **Reopen closed agents.** Closed agents with a conversation stay under *Recently closed* in the sidebar (and in ⌘P), one click from resuming.

### Answer approvals from anywhere
- **Real approvals, not keystrokes.** Kuronami installs Claude's `PermissionRequest` hook (per launch, never in your global settings). The moment an agent asks, its card shows the exact command with **Allow / Always / Deny**. Always saves the rule Claude suggested, and Deny can carry a reason the agent sees. Claude's own dialog still works in the terminal, and whichever answer comes first wins.
- **From the notification banner.** Allow or Deny straight from macOS notifications. The menu bar shows the waiting count.
- **Codex:** approvals from Kuronami work after you enable the hook once (App menu → *Enable Codex Approvals in Kuronami…*). Until then, Codex prompts are answered by choosing the numbered option on screen.

### Review the work
- **Ready for review.** When an agent finishes with changes, its card shows *Review +128 −41*. The inspector (⌥⌘R) shows the diff.
- **Any scope.** All changes since the branch left its base, only what's uncommitted, or exactly one turn. Unified or side by side, with whitespace changes hidden if you like.
- **Comment on lines.** Double-click a diff line to comment; *Send comments* delivers them to the agent as one message (queued if it's mid-turn).
- **Finish it.** Commit with a message your own Claude Code (or Codex) CLI drafts from the diff, following the repo's style; push; open a PR with a written title and description (via `gh`); merge into the base branch (refused if the main checkout is dirty or on another branch); or archive the worktree. Archiving commits leftover work to the branch first, so nothing is lost.
- **Open in your editor.** ⌥⌘O, the toolbar, or any file's context menu opens the workspace in Cursor, VS Code, Zed, Xcode, JetBrains IDEs and others, whichever you have; the last one used becomes the default.

### Turns and checkpoints
Every agent turn in a Git workspace is checkpointed: a snapshot when the prompt goes in and another when the turn ends. Snapshots are hidden commits under `refs/kuronami/<session>/`, built in a throwaway index, so your index, HEAD, branches and stash are never touched and ignored files are left out.
- **See one turn.** The Activity tab lists turns; *Changes* on any of them shows exactly what that turn did.
- **Revert files to before a turn.** From that turn's diff, *Revert Files…* puts the files back. The conversation isn't changed; the agent is told so it re-reads before editing. Every revert snapshots first, so *Undo Last Revert* brings everything back.

### Steer without switching terminals
- **Follow-ups.** The Activity tab has a message box. While the agent works, messages wait in a queue and go out one per turn; *Send Now* steers the current turn instead. Queued messages show on the card and can be sent early or removed.
- **Continue after a rate limit.** When an agent stops on a usage limit, its card offers *Continue at 3:40 PM*; at the reset it's told to carry on.

### Project actions
The toolbar's play button (and ⌘P) runs your project's commands. Kuronami detects them from `package.json` scripts (with your package manager), `Cargo.toml`, `Package.swift`, `go.mod`, `pyproject.toml` or a `Makefile`, or you list them yourself:
```json
{ "actions": [
    { "name": "Test", "command": "pnpm test" },
    { "name": "Storybook", "command": "pnpm storybook --port $PORT", "icon": "book", "server": true }
] }
```
Servers open on the shelf on the agent's own `$PORT`; other commands open a shell tile that keeps the output. Running an action again restarts it.

### Isolated workspaces
- **Quick dispatch.** Type a task in the sidebar's *Ask a new agent…* field and press Return. A new agent starts on it, auto-named from the task, in its own git worktree.
- **Claude's native worktrees** (`claude --worktree`) for Claude sessions: Claude blocks writes back into the main checkout and copies `.worktreeinclude` files (like `.env`). Codex gets a worktree under `~/.hyperterm/worktrees` with the same files copied in.
- **Per-project dev setup.** Add `.hyperterm.json` to a repo:
  ```json
  { "setup": "pnpm i", "dev": "pnpm dev --port $PORT", "ports": [4100, 4199] }
  ```
  Each new workspace gets its own port (`$PORT` and `$HT_PORT` in the agent's environment), and a labeled dev-server terminal starts next to it.
- **Clean up** (Terminal → *Clean Up Worktrees…*) lists agent worktrees with merged/unmerged status and archives the leftovers.

### Browsers agents can drive
- **Real Chromium inside Kuronami.** Browsers are sessions like terminals: labeled (`@api-web`), in the sidebar under their agent, tiled in split and grid, and restored where they left off. ⇧⌘B opens one, on the selected terminal's dev server when it has one.
- **Every agent gets its own.** An agent's first browser action opens `@<agent>-web` next to it, and its tools act on that browser by default, so parallel agents never fight over a page. `list_pages` names every Kuronami browser by label, and an agent can use another one by passing its page id.
- **Watch and step in.** The tile shows who is driving (`@api · click`), and you can click, type, and log in yourself at any time.
- **Your logins, if you want them.** *Import Chrome Logins…* (in a browser's ⋯ menu) copies your Chrome cookies into Kuronami's browser profile, which is kept separate from your own Chrome (`~/.hyperterm/browser`).
- **Scoped by default.** Agents started in Kuronami use Kuronami's browsers, not your everyday Chrome. App menu → *Let Agents Use My Chrome* re-enables Claude in Chrome for them.

Agents drive the browsers through [`chrome-devtools-mcp`](https://github.com/ChromeDevTools/chrome-devtools-mcp) (Node.js required), attached to Chromium's DevTools port on 127.0.0.1. Read-only tools (snapshots, screenshots, console, network) run without asking; navigating, clicking, typing, and scripts ask first.

### Agents that talk to each other
Every agent started in Kuronami gets a `hyperterm` MCP server (it keeps its original name so saved permissions keep working):

| Tool | What it does |
|---|---|
| `list_terminals` | Who's doing what: state, summary, ports, branch |
| `send_message` | Message another agent by `@label` |
| `read_terminal` | Read an agent's or server's output, e.g. dev-server logs |
| `set_status` | Post a one-line status to its card |
| `rename_terminal` | Rename itself as the work changes (`@auth-refactor` → `@fix-login`); old names keep working |
| `start_server` / `restart_server` | Run dev servers in their own labeled terminals. Starting one asks you first |
| `start_agent` | Delegate a self-contained subtask to a new Claude or Codex agent in its own worktree. Asks you first; the new agent inherits the parent's account and permission choices and messages it back when done |

Claude sessions are launched as `claude --name <label>`, so Claude's built-in cross-session messaging (`SendMessage`, `@mentions`) uses the same names. Messages wait until the receiving agent is at an empty prompt. They're never typed into a dialog or into something you're halfway through writing. Optional (App menu): deliver messages through Claude's **channels** API instead of typing.

### Usage
The sidebar shows your 5-hour and weekly usage with reset times, taken from Claude's statusLine data (your own statusline still prints unchanged). Each card shows cost and the inspector shows context use. When an agent hits a rate limit, its card says when the limit resets, not just "failed".

### Several Claude and Codex accounts
**Accounts…** (⌘,) adds more Claude Code or Codex sign-ins. Each extra account runs from its own folder (`CLAUDE_CONFIG_DIR` / `CODEX_HOME` under `~/.hyperterm/accounts`), the way both CLIs separate accounts themselves. It gets its own login and history, and starts with your settings, skills, and instructions. Pick which account new agents use, or choose one per agent in New Session or with `ht new claude --account work`. Agents an agent starts inherit its account. When an agent hits a limit, right-click it and choose **Move to Account**: its conversation is copied over and it resumes there. Your default account (`~/.claude`, `~/.codex`) is never touched.

## Security model

Kuronami types into terminals on your behalf, so who may ask for what matters. The control socket (`~/.hyperterm/control.sock`, user-only) identifies every caller from **kernel facts** (peer PID, process ancestry, and macOS's *responsible process*), never from anything the caller claims:

- **You:** processes outside Kuronami, or inside your own shell/server terminals.
- **Agents:** anything traced to an agent terminal. Agents can message other agents, read agents and servers (not shell scrollback), restart servers, start servers with your OK, set their own status, and rename only themselves (never over a name you chose).
- **Untrusted:** anything that came from inside Kuronami but escaped its session (backgrounded, double-forked, reparented to launchd). Read-only.

Only you can press keys, answer prompts, type raw text, open shells, or close terminals. That stops one agent from approving another's permission prompt or running commands outside its own checks. Session IDs and tasks typed into shells are validated and shell-quoted, peer messages are stripped of control and escape sequences, and git runs with repo hooks and fsmonitor disabled.

**Browsers.** Agents drive Chromium over its DevTools protocol on `127.0.0.1` only. Scoping each agent to its own browser is a default and a guardrail, not isolation: `chrome-devtools-mcp` sees every Kuronami browser, and while Chromium runs, any process on your Mac can connect to that port. Every Kuronami browser shares one profile (`~/.hyperterm/browser`), so a login in one is a login in all, including logins imported from Chrome. Only sign in where you're happy for your agents to act.

**Limit:** this is a boundary between agents and Kuronami, not an OS sandbox. An agent you allow to drive other apps (for example via `osascript`) could act outside it. Claude's sandbox mode closes that gap.

## Nothing global is modified

Hooks, the statusLine, the MCP server and permissions are attached **per launch** through wrappers in `~/.hyperterm/bin` (`claude --settings … --mcp-config …`, `codex -c …`). They merge with your settings; your existing hooks keep running. `~/.claude/settings.json` and `~/.codex/config.toml` are never written. Claude agents also get `--no-chrome` per launch, so they use Kuronami's browsers rather than your Chrome (App menu → *Let Agents Use My Chrome* drops it). Your Chrome profile is only read when you choose *Import Chrome Logins…*. Two opt-in menu items write config, and each asks first: channels (`claude mcp add --scope user hyperterm`) and Codex approvals (`~/.codex/hooks.json`).

## `ht` CLI

Add `export PATH="$HOME/.hyperterm/bin:$PATH"` to `~/.zshrc` (App menu → *Use ht in Your Shell…*).

```sh
ht ls                                           # label · kind · state · ports · summary
ht new claude --cwd ~/Code/app --worktree --task "fix the flaky auth test"
ht new server @web -- pnpm dev                  # also: codex, shell
ht new browser @docs -- localhost:3000          # a browser session
ht send @api "users.name is now display_name"   # message an agent
ht approve @api   ·   ht always @api   ·   ht deny @api "use a migration instead"
ht read @web -n 50                              # recent output
ht key @api down enter                          # press keys
ht layout grid   ·   ht focus @ui   ·   ht restart @web   ·   ht rename @api backend   ·   ht close @scratch
```

## Keyboard

| | |
|---|---|
| ⌘N / ⌘T / ⇧⌘C / ⇧⌘X | New terminal / shell here / Claude here / Codex here |
| ⌘P | Go to a terminal, run an action, or `@label message` |
| ⌘J | Jump to the agent waiting longest |
| ⌥⌘R / ⌥⌘I | Review changes / toggle inspector |
| ⌥⌘O | Open the selected workspace in your editor |
| ⌘⌥1 · 2 · 3, ⌘⏎ | Focus · split · grid, zoom tile |
| ⌥⌘0 | Even out tiles |
| ⇧⌘M | Minimize the selected tile to the shelf (again to restore) |
| ⌘F, ⌘G | Find in terminal (scrollback included) |
| ⇧⌘B | New browser (on the selected terminal's dev server, if it has one) |
| ⇧⌘O | Open the selected server's port in a preview window |
| ⌘, | Accounts |

## How status is detected

| Signal | Used for |
|---|---|
| Claude hooks: `UserPromptSubmit`, `PreToolUse`, `PostToolUse(Failure)`, `PermissionRequest`, `Notification`, `Stop`, `StopFailure`, `TaskCreated/Completed` | Turn state, the exact request being approved, activity, tests, todo progress, failure reasons |
| Claude statusLine | Cost, context, 5-hour/weekly usage |
| Codex `notify` + OSC 9 | Turn complete (summary, thread id), approval requests |
| `~/.claude/sessions/<pid>.json` | Corrects a stale "working" after an interrupt |
| Process tree + libproc sockets | Ports, foreground command, an agent quitting back to its shell, server crashes |
| Browser tool calls (through `ht browser-mcp`) | Which agent is driving which browser, shown on its tile and sidebar row |

Hook events are stamped and ordered, so a slow hook can't roll state back. The state machine (`Sources/Hyperterm/Status/StatusReducer.swift`) is a pure function with unit tests.

## Build

Requires macOS 15+, Xcode 16+, XcodeGen and Zig 0.15.2 (`brew install xcodegen zig@0.15`).

```sh
scripts/build-ghosttykit.sh   # once: builds libghostty (Ghostty v1.3.1, ReleaseFast) → GhosttyKit.xcframework
scripts/run.sh                # build + launch the debug app (first build downloads Chromium, ~130 MB)
scripts/install.sh            # optimized build → /Applications/Kuronami.app
xcodebuild -project Hyperterm.xcodeproj -scheme Hyperterm -derivedDataPath build/DerivedData test
scripts/linux-check.sh        # anywhere with Swift + Git: parse every file, design lint, pure-logic tests
```

The interface is built on one design system, `Sources/Hyperterm/UI/Design.swift`: six text styles, a 4-point spacing grid, three corner radii, neutral graphite with color reserved for meaning, and one motion curve that turns off with Reduce Motion. `scripts/lint-design.sh` fails on raw font sizes, radii or colors anywhere else.

Kuronami was called Hyperterm until October 2026. Internal names keep the old spelling so existing setups carry over: the Xcode project and Swift module, the bundle id, `~/.hyperterm`, the `ht` CLI, and `HT_*` environment variables.

Chromium comes from [CefSwift](https://github.com/Rajaniraiyn/CefSwift) (MIT, pinned in `project.yml`). `scripts/embed-cef.sh` runs after each build: it caches the CEF distribution in `~/Library/Caches/Hyperterm/cef` and assembles the framework plus the five helper apps Chromium needs. Agents' browser tools need Node.js (`npx chrome-devtools-mcp`).

## Project layout

```
Sources/Hyperterm/Ghostty   libghostty bridge: runtime callbacks, action router, surface view (input/IME/mouse)
Sources/Hyperterm/Model     LaunchSpec, TerminalSession, SessionSurface, SessionStore (+Hooks, +Approvals, +Browser)
Sources/Hyperterm/Status    StatusReducer, ProcessInspector (identity, ports), Git, Review, Checkpoints, CommitWriter,
                            AgentOptions, ProjectActions, Editors, Workspaces, notifications
Sources/Hyperterm/IPC       control socket server and request handler (permissions)
Sources/Hyperterm/Launch    agent wrappers, per-launch hooks/statusLine/MCP config
Sources/Hyperterm/Browser   Chromium runtime (lazy start, DevTools port), browser surface and bar, Chrome logins import
Sources/Hyperterm/UI        Design (tokens + components), LayoutTree, sidebar, toolbar, tiles, inspector, switcher, sheets
Sources/HypertermHelper     Chromium helper process (renderer, GPU, utility)
Sources/ht                  CLI, hook/permission/statusline entry points, stdio MCP server, browser MCP proxy
Tests/HypertermTests        state machine, layout tree, checkpoints (real Git), agent options, project actions, naming,
                            safety, diff parsing, recap
```

## Status

Working and verified on macOS 26 with Claude Code 2.1.287:
- labels and messaging
- hook status
- approvals from cards, notifications and `ht` (Allow / Always / Deny with reason)
- review and diffs
- dispatch into Claude worktrees
- usage telemetry
- channels
- the security boundary, tested against key presses, double-fork escapes, environment stripping, and shell-injection attempts

Browsers are verified by driving `ht browser-mcp` directly: lazy start, per-agent default page, labeled `list_pages`, cross-browser access, and refused `new_page`. A live Claude agent opening its own browser and the Chrome logins import are implemented but not yet verified end to end.

The October 2026 redesign (resizable layout, design system, checkpoints, diff scopes, AI-written commits and PRs, permission modes, fork, multi-agent dispatch, project actions, follow-up queue, recently closed, continue-at-reset) was written without a Mac at hand. Its pure logic is unit-tested on Linux (`scripts/linux-check.sh`), checkpoints against real Git, but the app itself still needs an Xcode build and a hands-on pass.

Codex integration is implemented, but on the development machine Codex itself fails to start (an account error), so its live paths are tested only with simulated signals.

Input handling in `TerminalSurfaceView.swift` and `GhosttyInput.swift` is adapted from Ghostty's macOS app (MIT).
