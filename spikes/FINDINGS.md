# Subagents Spike Findings — 2026-09-14

| Proof | Question | Result | Evidence |
|---|---|---|---|
| P1 | Ad-hoc bundle registers LaunchAgent via SMAppService; app reaches Mach service | PASS | `registered; status=enabled` with no Login Items approval; `pong from agentd pid=89927 to app` |
| P1b | setCodeSigningRequirement rejects a foreign ad-hoc identifier | PASS | rogue client (`dev.rogue.client`): `NSCocoaErrorDomain Code=4097` |
| P2 | Grandchild of app and of agentd reach the Mach service | PASS | `grandchild-of-app`, `grandchild-of-agentd`, and a plain terminal process all got pongs |
| P2b | launchd restarts a killed agent | PASS | `kill -9` → new pid within ~1 s, ping OK |
| P2c | Rebuilt bundle | GOTCHA | After replacing the bundle (new ad-hoc cdhash) launchd refuses: `last exit code = 78: EX_CONFIG`, `job state = spawn failed`. `unregister` + `register` fixes it. The Hub must re-register when the helper is unreachable. |
| P3 | `/task` unprefixed from a plugin | FAIL for commands, PASS for skills | `commands/task.md` → `Unknown command: /task`; only `/cch-main:task` works. `skills/task/SKILL.md` → `/task`, `/bugfix`, `/feature`, `/helper` all work unprefixed (and `/cch:task`). |
| P3b | `${CLAUDE_PLUGIN_ROOT}/..` paths in plugin .mcp.json and hooks | PASS | Core memory plugin uses `../../../MacOS/cch-mcp` in production |
| P4 | Bracketed paste + CR delivers one prompt; mid-turn message | PASS | Multi-line paste arrived as one `UserPromptSubmit` prompt; a message pasted 3 s into a `sleep 8` turn was injected into the same turn (both prompts logged, one Stop, reply `QUEUED-TWO`) |
| P5 | Tool name for plugin MCP servers | `mcp__plugin_<plugin>_<server>__<tool>` | `mcp__plugin_cch-main_cch__ping` |
| P6 | Trust dialog in new worktrees | SHOWN; default selection is "No, exit" | Fresh repo and Application Support worktree both show "Quick safety check: Is this a project you created or one you trust?" with `❯ No, exit` preselected. Enter exits Claude. Down-arrow + Enter selects "Yes, I trust this folder" and Claude continues. |

## Decisions

- IPC transport: **XPC Mach service** via `SMAppService.agent`. Plist adds `AbandonProcessGroup`; hosts start with `POSIX_SPAWN_SETSID` so they survive helper restarts. The app unregisters + re-registers when it cannot reach the helper after launch.
- Command names: `/task` `/bugfix` `/feature` `/helper` ship as **plugin skills** in `cch-main`.
- MCP tool prefix: `mcp__plugin_cch-main_cch__` (main), `mcp__plugin_cch-sub_cch__` (subagents).
- Worktree location (D4): keep Application Support. The host detects the trust prompt and sends Down + Enter when the main repository is already trusted in `~/.claude.json`; otherwise the subagent is marked needs-input so the user answers it in the subagent's terminal.
- Mid-turn delivery: injected into the current turn (fine for `message_subagent` and merge requests).
