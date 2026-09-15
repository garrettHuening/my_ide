# Subagents — Roadmap

**Spec:** `docs/superpowers/specs/2026-09-14-subagents-design.md`

The spec spans five subsystems (helper runtime, UI, Claude integration, recovery, merging), so it is delivered as one plan per phase. Each phase ends with working, testable software. A phase's detailed plan is written only after the previous phase lands, because Phase 0's findings change concrete code in Phases 2–6 (IPC transport, MCP tool prefix, worktree location).

| Phase | Plan file | Delivers | Requirements | Status |
|---|---|---|---|---|
| 0 | `2026-09-14-subagents-phase0-spike.md` | Throwaway proofs + `spikes/FINDINGS.md` with go/fallback decisions | Risk list §1 | Plan written |
| 1 | `2026-09-14-subagents-phase1-foundation.md` | git repo, `scripts/bundle.sh`, `CCHCore` library with tested state machine, naming, merge gate/order, recovery planner, hook policy, model resolution | groundwork for R11, R13, R14, R15 | Plan written |
| 2 | `…-phase2-runtime.md` | `cch-agentd` + `cch-agent-host` + git worktrees + output streaming; app shows a subagent terminal from a debug menu | R6, R7 | Write after Phase 1 |
| 3 | `…-phase3-ui.md` | Sidebar tabs removed; right panel tabs + Agents toggle + chips; Subagents tab, Main row, main-pane swap, status bar, session dot | R2–R5, L1–L3 | Write after Phase 2 |
| 4 | `…-phase4-commands.md` | `cch-mcp`, `cch-main`/`cch-sub` plugins, `/task` `/bugfix` `/feature` `/helper`, spawn/list/message tools, Settings → Subagents (per-category default model, per-spawn override, auto-resume toggle), main launch flags + main resume | R1, R10, R15, D11, D14 | Write after Phase 3 |
| 5 | `…-phase5-recovery.md` | Hooks, `report_status`/`mark_complete`, recovery + auto-resume, read-only complete view | R13, R14 | Write after Phase 4 |
| 6 | `…-phase6-merge.md` | Merge flow, merge groups/order, cleanup, Done section | R8, R9, R11, R12 | Write after Phase 5 |

## Gates

- **After Phase 0:** user reviews `spikes/FINDINGS.md`. If proof 1 or 2 failed, the user must approve the Unix-socket fallback before Phase 2 is planned. Update spec D4 and the tool prefix per findings.
- **After every phase:** `swift test` green, `scripts/bundle.sh --run` launches the app from the real bundle, the phase's manual checklist passes, and the user signs off before the next plan is written.

## Execution notes

- Always test from the `.app` bundle, never `.build/debug/ClaudeCodeHub` directly (the window never appears).
- Phases 0, 4, 5, 6 run the real `claude` CLI and spend tokens; prefer `--model haiku` in scripted checks.
- The CCH project was not under git when this plan was written; Phase 1 Task 1 initializes it (user approval required).
