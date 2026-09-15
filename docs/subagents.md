# Subagents — as built (2026-09-14)

Spec: `docs/superpowers/specs/2026-09-14-subagents-design.md`. Platform findings: `spikes/FINDINGS.md`.

## Flow

1. In a Hub session, `/task`, `/bugfix`, `/feature` or `/helper <text>` runs a `cch-main` skill. Main Claude lists subagents, writes a brief, picks a merge group when work overlaps, and calls `spawn_subagent`. `/bugfix` also opens a core-memory ledger entry (`bug_open`).
2. `cch-mcp` forwards the tool call over XPC to `cch-agentd`, which creates a worktree + branch `cch/<category>/<id>-<slug>` from the session's HEAD, resolves the model (override → Settings default → CLI default) and starts `cch-agent-host`.
3. The host runs `claude --session-id … --plugin-dir cch-sub --permission-mode acceptEdits --append-system-prompt <rules> "<brief>"` in a pty, accepts the folder-trust prompt when the main repo is trusted, and streams output to agentd, which buffers it and forwards it to the app.
4. `cch-sub` hooks drive state: UserPromptSubmit → running, Notification(permission_prompt) → needs_input (red), Stop → idle (blocks once if the turn didn't `report_status`), PostToolUse reminder after 10 min without a report. `mark_complete` requires a clean worktree.
5. Merge (row button): gate checks busy/merge order; dirty worktree → subagent is asked to commit (10-min wait); then the merge request is typed into the main session's terminal. Main Claude merges and calls `mark_merged`; agentd verifies the tip is in HEAD, re-tags the branch's memories to main, stops the host, removes the worktree and deletes the branch. Nothing to merge → Done archives directly.
6. Crash recovery: agentd restarts (launchd) → hosts reattach; missing hosts after 8 s → RecoveryPlanner: resume with `--resume` + continue nudge (auto-resume setting), idle relaunch silently, commit request re-sent, crash-loop guard (3 in 30 min), complete/merged/stopped never restart.

## UI

- Sidebar: sessions only.
- Right panel chips: All · Agents (adds MCPs/Agents/Skills tabs) · Task · Bug · Feature · Helper (filters). Tabs: Subagents | Plans | Scripts.
- Subagents tab: pinned MAIN row (session + branch), merge-group sections (ordered, `n/m merged`, `waits #n`), category sections with placeholders, collapsible Done with Clear. Row: state dot, index/category chips, model chip when not the default, last status, note, action button (Merge / Done / Re-send Merge / Resume), context menu (Stop, Reopen, Reveal Worktree, Copy Branch, Remove from Group, Discard…).
- Clicking a row swaps its live terminal into the main pane (topbar shows category · title · branch · Back to Main); a Reopen/Resume bar appears when Claude isn't running.
- Settings → Subagents: default model per category (CLI default / Fable / Opus / Sonnet / Haiku / Custom) and auto-resume. Status bar: subagent count, "k need you", "helper offline".

## Verified end to end (real claude, Haiku)

- `/bugfix` in a main session → BUG-1 in the memory ledger + spawn via tools.
- Subagent fixed a bug, committed, reported status, marked complete; permission prompts answered through `app.input`.
- Merge refused before the tip was in HEAD; after `git merge` it verified, cleaned up worktree + branch.
- Merge group order: second member refused ("must wait until … #1"), first archived, second then allowed.
- Helper killed/re-registered: host process survived and reattached.
- Trust prompt auto-accepted for a worktree of a trusted repo.

## Known gaps / not built

- The UI was checked only through a user screenshot of the Subagents tab (no automated UI tests; no screenshot access from the agent).
- `message_subagent` from the UI is typing into the subagent's terminal; there's no separate message sheet.
- Subagents often stop on permission prompts for shell commands outside the allowlist (D3); the row turns red and you answer in its terminal.
- Background memory jobs (sweep, dreaming, docs) still run inside the app, not the helper, so they stop when the app quits (now marked interrupted and time-limited).
- Cloud sync (M8) needs a backend decision; only the merge-promotion marker (branch re-tagging) exists.
