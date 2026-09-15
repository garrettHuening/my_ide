# Core memory — as built (2026-09-14, updated with dreaming, docs and subagents)

Design source: `docs/context/core-memory-design-2026-08-26.md`. This file records what exists in code and where it deliberately differs from the design discussion.

## Pieces

| Piece | Where | What it does |
|---|---|---|
| Store | `Sources/CCHMemory/Storage/` | `memory.db` (projects, memories + FTS5, edges, feature_versions, bugs + FTS5, bug_links, retrievals, sweeps, prefs). Triggers make bugs append-only (one open→fixed update), bug links undeletable and bug-learning memories frozen. |
| Project identity | `Project/ProjectKey.swift` | Normalized `origin` URL, else the main checkout root, so every checkout and worktree of a repo shares memories. Non-git folders are their own project. |
| Retrieval | `Retrieval/Retriever.swift` | FTS5 BM25 + on-device embedding (`NLEmbedding` sentence, behind `Embedder`) fused with reciprocal rank fusion, one-hop graph expansion (linked memories at half score, recent/similar bugs on matched features), previous session memory pinned on a session's first prompt, 12 entries / ~6,000 chars. |
| Grounding | `Retrieval/Grounding.swift` | `<core-memories>` block with Off / Balanced / Strict rules; Strict relaxes to Balanced under 50 memories; Strict Stop hook blocks one uncited long answer. |
| Tools | `Tools/MemoryTools.swift` | `memory_search/get/write/update/link/flag_conflict`, `bug_open/fix/learning/similar/link_regression`, `log_event`. |
| Hooks | `Hooks/HookHandlers.swift`, `Resources/plugins/cch-main/hooks/hooks.json` | UserPromptSubmit (retrieval, near-miss logging), Stop (strict check), PreCompact/SessionEnd (session snapshot). 1.5 s hook timeout, never blocks a prompt. |
| Sweep (M3) | `Sweep/Sweep.swift`, `Sources/ClaudeCodeHub/Memory/MemoryJobs.swift` | Headless `claude -p` with the `cch-sweep` plugin (memory tools only). Runs on first terminal start of a never-swept git project, or when 20+ commits / 7+ days behind (change-only); session menu → Re-sweep Project runs a full sweep. Scripts tab reads `script` memories (`Command:` first line). |
| Session continuation (M5) | `Session/SessionSnapshot.swift`, `Sources/cch-mcp/SessionSummarizer.swift` | Hook spawns a detached `cch-mcp snapshot`; condensed transcript → background model (`--tools ""`) → one `session` memory per Claude session, linked `touched_in` to retrieved/cited memories. |
| Console (M7) | `Console/ConsoleLog.swift`, `Views/Console/ConsoleDrawer.swift` | `console.db`, domain + severity + source; drawer via status bar or ⇧⌘Y; `cch-mcp log --domain … --severity … msg` is the open logging API; `appLog` mirrors into domain `hub`. |
| Dreaming (M6) | `Dreaming/Dreaming.swift`, `MemoryJobs.dream` | Every 6 h per project with changed memories (or session menu → Core Memory → Dream Now): merges duplicates (`memory_supersede`), fixes stale memories against code, links, flags doc-vs-code conflicts, bumps feature versions under the conservative rule. Verified: merged a planted duplicate, caught a fake claim, made no bump. |
| Docs (M4) | `Jobs/HeadlessClaude.swift` (`DocsIngestion`), `DocumentationPicker` | Session menu → Core Memory → Add Documentation URL…/Files…: `doc`/`api`/`design` memories forced to `source: doc`, linked `documents` to code, conflicts flagged. Verified: caught two planted doc-vs-code contradictions. |
| Tool sets | `Tools/MemoryTools.swift` (`Toolset`) | Per-plugin `CCH_TOOLSET`: main, sweep (source code), dream, docs (source doc). |
| Binary | `Sources/cch-mcp/` | `serve` (stdio MCP), `hook user-prompt-submit|stop|post-tool-use|notification|session-snapshot`, `snapshot`, `log`, `agentd …`, `sweep-prompt`/`dream-prompt` (debug). |

## Differences from the design

- **Memory isn't served by the background helper.** `cch-agentd` exists (for subagents), but `cch-mcp` processes open `memory.db` directly (WAL, busy timeout) and the app runs sweeps, dreams and doc ingestion. The embedding model loads in ~40 ms, so per-prompt latency doesn't need the helper. Background jobs stop if the app quits.
- **Tool prefix** is `mcp__plugin_cch-main_cch__` (Claude Code's naming for plugin MCP servers), not `mcp__cch__`.
- **Diagram flowchart** is stored as Mermaid text in a `diagram` memory body, because sweeps run without write tools.
- **Near-miss logging** approximates "cited" with "injected": a correction-like prompt right after a retrieval that injected memories is logged to `memory.nearmiss`.
- **Session snapshots on Hub quit** aren't captured if Claude doesn't get to run `SessionEnd`.
- **On-device embeddings are weak** (3/5 on a toy ranking test); keyword search and graph links carry most relevance. Swap `Embedder` for a stronger model when available.

## Not built yet

- M8 cloud sync (needs a server/auth decision). Merged subagent branches already re-tag their memories to the main branch as the promotion marker.
- Moving sweeps/dreaming/docs jobs into `cch-agentd` so they survive app quit (today: time-limited, marked interrupted on next launch).

## Develop

- `swift test --filter CCHMemoryTests` (`HashingEmbedder` + temp databases).
- `scripts/bundle.sh --run` builds and relaunches (kills Claude sessions running inside the Hub).
- `CCH_SUPPORT_DIR=/some/dir` points `memory.db` / `console.db` elsewhere for manual runs.
