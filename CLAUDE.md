# Claude Code Hub

Native macOS (SwiftUI, macOS 14+) desktop app that wraps the `claude` CLI: a sidebar of sessions, a main terminal per session, core memory that makes every session continue the last one, and subagents that work in their own git worktrees and get merged back.

## Build, test, run

```bash
swift test                      # all unit/integration tests (CCHMemoryTests + CCHSubagentsTests)
scripts/bundle.sh               # build + assemble signed build/ClaudeCodeHub.app
scripts/bundle.sh --run         # …and relaunch it
build/ClaudeCodeHub.app/Contents/MacOS/cch-mcp agentd ensure   # (re)register + start the helper
```

- Always run the **bundle**, never `.build/debug/ClaudeCodeHub` (no window appears without the bundle).
- Relaunching the app kills Claude conversations running inside it and interrupts background memory jobs. Say so before doing it.
- After rebuilding, the running `cch-agentd` keeps its old image; launchd refuses to restart a rebuilt ad-hoc bundle (exit 78 EX_CONFIG) until it is unregistered, the old job is gone, and it is registered again. `cch-mcp agentd ensure` (and the app on launch/reconnect) does exactly that. Subagent hosts survive helper restarts.
- Real `claude` runs cost tokens. Use `--model haiku` for scripted checks and point `CCH_SUPPORT_DIR` at a scratch directory to avoid touching real data.

## Targets

| Target | What |
|---|---|
| `ClaudeCodeHub` | The app. Sessions (app.db), terminals (`TerminalRegistry`, SwiftTerm), right panel, console drawer, memory jobs (`MemoryJobs`), subagent client/UI. |
| `CCHMemory` | Core memory library: `memory.db` store with triggers, retrieval (FTS5 + on-device embeddings + RRF + graph), grounding, MCP tool handlers, hooks, sweep/dream/docs prompts, session snapshots, console log, `ClaudeLocator`. |
| `CCHSubagents` | Subagent rules (state machine, naming, merge gate/order, recovery planner, hook policy, model resolution), `agents.db`, git helpers, prompts, XPC protocol/RPC, `SMAppServiceBridge`. |
| `cch-mcp` | The one binary Claude talks to: `serve` (stdio MCP; toolset via `CCH_TOOLSET`, subagent tools via `CCH_ROLE`), `hook …`, `snapshot`, `log`, `agentd register|unregister|status|ensure|call`. |
| `cch-agentd` | LaunchAgent + Mach XPC service `dev.cch.agentd`. Owns subagents, worktrees, output buffers, tools, hooks, merges, recovery. |
| `cch-agent-host` | One process per subagent: `claude` in a pty inside its worktree, streams to agentd, handles the trust prompt, reattaches after helper restarts. |

Plugins shipped in `Resources/plugins` (loaded per launch with `--plugin-dir`): `cch-main` (main sessions: memory hooks, `/task` `/bugfix` `/feature` `/helper` **skills**), `cch-sub` (subagents: memory + lifecycle hooks), `cch-sweep`, `cch-dream`, `cch-docs` (background jobs, no hooks).

## Data

`~/Library/Application Support/ClaudeCodeHub/`: `app.db` (sessions, folders), `memory.db`, `console.db`, `agents.db`, `subagents/<id>/{pty.log,status.md}`, `jobs/*.stderr.log`. Subagent worktrees: `~/.cch/worktrees/<repo>-<hash>/<id>-<slug>` (no spaces on purpose). Helper stdout: `/tmp/cch-agentd.log`. App log: `~/Library/Logs/ClaudeCodeHub.log`.

## Conventions

- Colors only from `Theme.swift` (monochrome; no blue/purple).
- Errors and findings go to the one console (`ConsoleLog`, domain + severity), not bespoke error views. `appLog` mirrors into domain `hub`.
- Pure rules live in the libraries with XCTest coverage; side effects (git, processes, XPC, SQLite) call them.
- Bugs are append-only and bug learnings frozen — enforced by SQLite triggers; never work around them.
- Feature version bumps are conservative (see `Dreaming.conservativeBumpRule`).
- Claude Code facts verified here: plugin MCP tools are named `mcp__plugin_<plugin>_<server>__<tool>`; plugin **commands** are namespaced-only but plugin **skills** work unprefixed; the folder-trust prompt defaults to "No, exit" (Down + Enter accepts); `UserPromptSubmit` `additionalContext` works in `-p` and interactive.

## Docs

- `docs/core-memory.md` — core memory as built, differences from design, what's left.
- `docs/subagents.md` — subagents as built, verification record, what's left.
- `docs/superpowers/specs/2026-09-14-subagents-design.md` — subagents spec (requirements R1–R15, decisions D1–D14).
- `docs/context/core-memory-design-2026-08-26.md` — original core memory design conversation.
- `spikes/FINDINGS.md` — platform findings that shaped the architecture.
