# Subagents — Design Spec

**Date:** 2026-09-14
**Status:** Draft for review
**App:** Claude Code Hub (`/Users/robertoppenheimer/Documents/Claude/CCH/ClaudeCodeHub`)

Sections 1–2 were approved in conversation. Sections 3–5 were filled in with proposed defaults after the user said "do it" — the list below calls out every decision made without an explicit answer.

## Decisions made without asking — please check

| # | Decision | Where |
|---|---|---|
| D1 | Right-panel filter chips become **All · Agents · Task · Bug · Feature · Helper**. "Investigate" has no matching category, so it is replaced; the four category chips filter the Subagents tab. | §4 |
| D2 | Subagents cannot spawn subagents (only the main pane gets `spawn_subagent`). | §3 |
| D3 | Subagents run with `--permission-mode acceptEdits` plus the existing allowlist. Any other permission prompt turns the row (and session dot) red. | §3 |
| D4 | Worktrees live outside the repo: `~/Library/Application Support/ClaudeCodeHub/worktrees/…`. Branches are `cch/<category>/<id>-<slug>`. | §3 |
| D5 | Spawning while main has uncommitted changes is allowed; main Claude is told which files the subagent won't see. | §3 |
| D6 | Spawning from a session that isn't a git repo is refused; main Claude asks you whether to `git init`. | §3 |
| D7 | Merge is enabled only when the subagent is `idle` or `complete` (not mid-turn). | §5 |
| D8 | After a verified merge: host stops, worktree removed, branch deleted, row moves to a collapsed **Done** section. | §5 |
| D9 | A subagent with zero commits and a clean tree shows **Done** instead of **Merge** and archives without involving main Claude (typical for helpers). | §5 |
| D10 | Interrupted subagents auto-resume when `cch-agentd` starts — even if the app isn't open (e.g. after a reboot). A setting turns this into a manual **Resume** click. | §2 |
| D11 | The main session now resumes its previous Hub conversation on relaunch instead of starting fresh. | §2 |
| D12 | Tunables: status reminder after 10 min without a report; crash-loop limit of 3 auto-resumes per 30 min; commit wait timeout 10 min; `pty.log` cap 20 MB. | §2, §5 |
| D14 | Model picker per category offers **CLI default · Fable · Opus · Sonnet · Haiku · Custom…**. Every category starts at CLI default (no `--model` flag, same as today). Changing a default affects new spawns only; a subagent keeps its recorded model across resumes. | §3, §4 |
| D13 | The earlier spec's `_tasks.md` tracker (step 6) and `bug`/`investigate` prefix dispatch (step 5) are superseded by this work and dropped. The `panes` table is left in place, unused. | Non-goals |

## Requirements traceability

| # | Requirement (user's words, condensed) | Covered in |
|---|---|---|
| R1 | `/task`, `/bug`, `/feature`, `/helper` each spawn a subagent into its own category (`/bug` is shipped as **`/bugfix`** — Claude Code has a built-in `/bug`) | §3 |
| R2 | Subagents tab replaces the Tasks tab | §4 |
| R3 | One section per category, rows for running subagents | §4 |
| R4 | Main row always pinned at top | §4 |
| R5 | Clicking a row shows its content in the main pane | §4 |
| R6 | Each subagent works on a worktree based on the session it spawned from | §3 |
| R7 | Each subagent in its own XPC process | §1 |
| R8 | Merge button on every row | §4, §5 |
| R9 | Merge → view switches to main, main merges the subagent's branch into its own | §5 |
| R10 | Main pane can message subagents after they start | §5 |
| R11 | Overlapping work gets an index; merges must happen in index order | §5 |
| R12 | Sections tracking changes grouped by those indexes | §4, §5 |
| R13 | Subagents write status periodically so a crash can resume where they left off | §2 |
| R14 | Completed subagents tag themselves complete and never start over on relaunch/restart/resume | §2 |
| R15 | Settings sets the default model for each subagent type; a spawn may override it when the user asks | §3, §4 |
| L1 | Left sidebar keeps only Sessions (MCPs/Agents/Skills tabs removed) | §4 |
| L2 | "Analyze" chip becomes **Agents**; when on, MCPs · Agents · Skills tabs are added after Plans | §4 |
| L3 | Panes tab removed | §4 |

---

## §1 Processes and architecture (approved)

```
launchd (gui/<uid>)
 └─ cch-agentd ─ LaunchAgent, Mach service dev.cch.agentd, KeepAlive
     │   owns: agents.db, git worktree ops, output buffers + pty.log
     ├─ cch-agent-host #7 ─ forkpty → claude (worktree A)
     │     └─ claude ── cch-mcp serve (stdio MCP) ──XPC──▶ agentd
     └─ cch-agent-host #8 ─ forkpty → claude (worktree B)

Claude Code Hub.app ──XPC──▶ agentd  (list, subscribe, output, input, resize, merge)
 └─ main session PTY (in-app, as today)
     └─ claude --plugin-dir cch-main --session-id … ── cch-mcp serve ──XPC──▶ agentd
```

Four executables, all inside the `.app` bundle:

1. **`ClaudeCodeHub`** — the app. Draws everything. Subagent terminals are SwiftTerm `TerminalView`s fed bytes over XPC; keystrokes go back the same way. The main session keeps running in-app via `TerminalRegistry`.
2. **`cch-agentd`** — LaunchAgent registered with `SMAppService.agent(plistName: "dev.cch.agentd.plist")`. Source of truth for subagents. Starts one host per subagent, keeps each one's output, runs all `git` operations, answers tool calls and hook events.
3. **`cch-agent-host`** — one process per subagent. `cforkpty_open` + exec `claude` in the worktree. Streams PTY bytes to agentd, applies input and resize. If it crashes, only that subagent dies. If agentd dies, the host keeps `claude` alive and reconnects with backoff (launchd restarts agentd).
4. **`cch-mcp`** — two subcommands:
   - `cch-mcp serve`: stdio MCP server that each `claude` launches. Identifies the caller from env (`CCH_ROLE=main|subagent`, `CCH_SESSION_ID`, `CCH_SESSION_DIR`, `CCH_AGENT_ID`) and forwards every tool call to agentd.
   - `cch-mcp hook <event>`: Claude Code hook entry point. Reads the hook JSON on stdin, forwards it to agentd, prints agentd's decision JSON.

Why a stdio shim over XPC rather than an HTTP MCP server in agentd: no open ports, no tokens, and caller identity comes for free from env.

### XPC interfaces (`CCHCore/XPC`)

```swift
@objc protocol AgentdAppAPI {        // app → agentd
  func subscribe(sessionID: Int64, client: AgentdAppClient)          // pushes changes + output
  func attach(agentID: Int64, reply: (Data /*scrollback*/) -> Void)
  func sendInput(agentID: Int64, data: Data)
  func resize(agentID: Int64, cols: Int, rows: Int)
  func requestMerge(agentID: Int64, reply: (MergeTicketDTO?, String? /*error*/) -> Void)
  func stop(agentID: Int64); func reopen(agentID: Int64); func discard(agentID: Int64)
  func getSettings(reply: (SubagentSettingsDTO) -> Void)             // per-category models, autoResume
  func setSettings(_ settings: SubagentSettingsDTO, reply: (String? /*error*/) -> Void)
}
@objc protocol AgentdAppClient {     // agentd → app
  func subagentsChanged(_ dtos: [SubagentDTO])
  func output(agentID: Int64, data: Data)
  func deliverToMain(sessionID: Int64, text: String)  // merge prompt typed into main PTY
}
@objc protocol AgentdHostAPI {       // host → agentd
  func hello(agentID: Int64, pid: Int32, reply: (LaunchSpecDTO) -> Void)
  func output(agentID: Int64, data: Data)
  func exited(agentID: Int64, code: Int32)
}
@objc protocol HostControl {         // agentd → host (exported by host)
  func write(_ data: Data); func resize(cols: Int, rows: Int); func terminate()
}
@objc protocol AgentdToolAPI {       // cch-mcp → agentd
  func call(caller: CallerDTO, tool: String, argsJSON: Data, reply: (Data /*resultJSON*/) -> Void)
  func hook(caller: CallerDTO, event: String, payloadJSON: Data, reply: (Data /*stdout JSON*/) -> Void)
}
```

The listener validates peers with `NSXPCConnection.setCodeSigningRequirement` using signing identifiers (`dev.cch.ClaudeCodeHub`, `dev.cch.agent-host`, `dev.cch.mcp`). Ad-hoc signing makes this identifier-only; tighten to a team anchor once a Developer ID exists.

### Risk: prove first (Phase 0 spike)

1. An ad-hoc-signed bundle can register the LaunchAgent via `SMAppService` and the app can look up `dev.cch.agentd`.
2. A grandchild process (host → `claude` → `cch-mcp`) can look up the same Mach service.
3. `--plugin-dir` makes `/task`, `/bugfix`, `/feature`, `/helper` available unprefixed; plugin `.mcp.json` and `hooks.json` resolve `${CLAUDE_PLUGIN_ROOT}`-relative paths to `Contents/MacOS/cch-mcp`.
4. Bracketed paste + `\r` written to the PTY submits a message into the `claude` TUI, including while it's mid-turn (queued).
5. Record the exact tool-name prefix Claude Code gives MCP servers loaded from a plugin (`mcp__cch__…` vs. a plugin-namespaced form). Allowlists and command prompts use whatever it is.
6. Whether `claude` shows its folder-trust dialog in a brand-new worktree directory. If it does under Application Support but not under `<repo>/.claude/worktrees/`, D4 moves worktrees to `<repo>/.claude/worktrees/<id>-<slug>`; if it does in both, agentd must handle the dialog before delivering the brief.

**Fallback if 1 or 2 fail:** keep the same process layout, but the app launches agentd detached (`setsid`) and all IPC uses a Unix domain socket at `~/Library/Application Support/ClaudeCodeHub/agentd.sock` with the same message shapes. Subagents still survive app quit; only the transport changes. Requires the user's OK before adopting.

---

## §2 Data, status reporting, crash recovery (approved; states refined)

### Storage

agentd is the only writer, through one serial queue.

- `~/Library/Application Support/ClaudeCodeHub/agents.db` (SQLite, WAL).
- `~/Library/Application Support/ClaudeCodeHub/subagents/<id>/pty.log` — raw PTY bytes, capped at 20 MB, rotated once (`pty.log.1`).
- `~/Library/Application Support/ClaudeCodeHub/subagents/<id>/status.md` — human-readable copy of the latest status report.
- In-memory ring buffer of the last 2 MB per subagent for fast `attach`.

Nothing is written into the worktree, so status files never reach a merge.

```sql
CREATE TABLE merge_groups (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  created_at REAL NOT NULL,
  UNIQUE(session_id, name)
);
CREATE TABLE subagents (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL,          -- app.db sessions.id
  session_dir TEXT NOT NULL,            -- main working dir at spawn
  repo_root TEXT NOT NULL,              -- git toplevel of session_dir
  category TEXT NOT NULL,               -- task|bug|feature|helper
  title TEXT NOT NULL,
  brief TEXT NOT NULL,
  model TEXT,                           -- resolved at spawn; NULL = CLI default (no --model)
  state TEXT NOT NULL,                  -- see state machine
  merge_substate TEXT,                  -- awaiting_commit|awaiting_main
  claude_session_id TEXT NOT NULL,      -- UUID passed via --session-id
  worktree_path TEXT NOT NULL,
  branch TEXT NOT NULL,
  base_commit TEXT NOT NULL,
  base_branch TEXT,                     -- main's branch at spawn (NULL if detached)
  merge_tip TEXT,                       -- branch tip recorded when merge requested
  merge_group_id INTEGER REFERENCES merge_groups(id),
  merge_index INTEGER,
  host_pid INTEGER, host_started_at REAL,
  resume_count INTEGER NOT NULL DEFAULT 0, last_resume_at REAL,
  turns_started INTEGER NOT NULL DEFAULT 0,
  last_report_turn INTEGER NOT NULL DEFAULT -1,
  last_report_at REAL,
  created_at REAL NOT NULL, updated_at REAL NOT NULL,
  completed_at REAL, merged_at REAL,
  failure_reason TEXT
);
CREATE TABLE status_reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  subagent_id INTEGER NOT NULL REFERENCES subagents(id),
  at REAL NOT NULL,
  summary TEXT NOT NULL,
  done_json TEXT NOT NULL,              -- ["…", …]
  next_json TEXT NOT NULL
);
CREATE TABLE prefs (
  key TEXT PRIMARY KEY,                 -- subagents.autoResume ("1"/"0"),
  value TEXT NOT NULL                   -- model.task|model.bug|model.feature|model.helper ("" = CLI default)
);
```

app.db migration v4: `ALTER TABLE sessions ADD COLUMN claude_session_id TEXT;`

### State machine

```
starting → running ⇄ idle
             ⇅
         needs_input
running/idle → complete → merging → merged
(any live state) → interrupted → (auto-resume) → running
side exits: stopped (user stop, worktree kept, Reopen-able)
            failed  (spawn error or crash loop)
            discarded (worktree + branch deleted)
```

| State | Meaning | Set by | Dot |
|---|---|---|---|
| `starting` | host launched, no hook yet | spawn | green |
| `running` | turn in progress | `UserPromptSubmit`, `PostToolUse` hooks | green |
| `idle` | turn ended, not complete | `Stop` hook | yellow |
| `needs_input` | permission prompt showing | `Notification` hook with `notification_type == "permission_prompt"` (other types ignored) | red |
| `complete` | subagent called `mark_complete` | tool | accent ✓ |
| `merging` | merge requested | Merge click | green |
| `merged` | merge verified | `mark_merged` | muted ✓ |
| `interrupted` | host died while live | agentd | gray ↻ |
| `stopped` | user stopped | UI | gray |
| `failed` | spawn error / crash loop | agentd | red ✕ |
| `discarded` | user discarded | UI | — (hidden) |

Pure transition rules live in `CCHCore/SubagentStateMachine.swift` and are unit-tested; agentd applies them.

### Status reporting (R13)

- The subagent's appended system prompt requires `report_status` after each meaningful step and before ending any turn.
- `turns_started` increments on every `UserPromptSubmit` (including nudges and messages typed by agentd). `mark_complete` also counts as a report (its summary is stored as a status report with empty `next`).
- **`Stop` hook enforcement:** if `last_report_turn < turns_started`, `completed_at` is NULL, and `stop_hook_active` is false, agentd replies `{"decision":"block","reason":"Call report_status (summary, done, next) before stopping."}`. The flag prevents loops.
- **Long turns:** on `PostToolUse`, if `last_report_at` is older than 10 min, agentd replies with `hookSpecificOutput.additionalContext` = "It has been over 10 minutes since your last report_status. Call it now, then continue."
- Each report inserts into `status_reports`, updates `last_report_*`, rewrites `status.md`, and pushes to the app (row subtitle shows `summary`).

### Recovery

`RecoveryPlanner` (pure, in `CCHCore`) takes DB rows + a process-liveness probe and returns actions. agentd runs it on every start.

| Row state | Host alive (pid + start time match) | Action |
|---|---|---|
| `starting`/`running`/`needs_input` | yes | reattach |
| `starting`/`running`/`needs_input` | no | → `interrupted`, relaunch with `--resume`, send continue nudge |
| `idle` | no | relaunch with `--resume`, **no** nudge, stay `idle` |
| `interrupted` | no | auto-resume on → relaunch with `--resume` + nudge; off → leave, row shows **Resume** |
| `merging` + `awaiting_commit` | no | relaunch with `--resume`, resend commit request |
| `merging` + `awaiting_main` | any | no subagent action; row button reads **Re-send Merge** (main may have restarted mid-merge) |
| `complete`/`merged`/`stopped`/`failed`/`discarded` | no | nothing (R14) |

Continue nudge (typed into the resumed session):

> You were interrupted by a crash or restart. Your last status report: **<summary>**. Done: <done>. Next: <next>. Commits on your branch: <`git log --oneline base..HEAD`>. Uncommitted: <`git status --short`>. Continue from Next.

- Every relaunch passes the subagent's recorded `model` (`--model <model>` when non-NULL), so a resume never silently switches models.
- Auto-resume is on by default (D10). Pref `subagents.autoResume` (agents.db `prefs`, toggled in Settings → Subagents) switches to manual: interrupted rows show a **Resume** button.
- Crash-loop guard: if `resume_count` reaches 3 within 30 min → `failed` with `failure_reason = "crash loop"`.

### Never start over (R14)

- `complete`, `merging`, `merged`, `stopped`, `failed`, `discarded` are never relaunched automatically.
- A `complete` subagent's host stays alive idle until merged, so it can still be messaged.
- After a restart, a `complete` row with no host shows the saved `pty.log` read-only with a **Reopen** button (`claude --resume`, no nudge).
- `message_subagent` on a complete subagent with no host reopens it first; the conversation continues rather than restarting.
- `mark_complete` refuses (tool error) while `git status --porcelain` is non-empty: "Commit all work first."

### Main session resume (D11)

- The app generates a UUID on a session's first Hub launch, stores it in `sessions.claude_session_id`, and starts `claude --session-id <uuid>`.
- On later launches, if `~/.claude/projects/<encoded session dir>/<uuid>.jsonl` exists, it starts `claude --resume <uuid>`; otherwise it starts fresh with `--session-id <uuid>`.
- Restarting main never touches subagents. Main Claude catches up with `list_subagents`.

---

## §3 Spawning and worktrees

### Plugins (replace user-dir command installs)

Shipped in `Contents/Resources/plugins/`, passed with `--plugin-dir` so they exist only in Hub-launched sessions:

```
cch-main/
  .claude-plugin/plugin.json          {"name":"cch-main", …}
  commands/task.md  bugfix.md  feature.md  helper.md
  .mcp.json                           cch server, CCH_ROLE from env
cch-sub/
  .claude-plugin/plugin.json          {"name":"cch-sub", …}
  .mcp.json
  hooks/hooks.json                    UserPromptSubmit, PostToolUse, Notification, Stop
```

`.mcp.json` (both):

```json
{ "mcpServers": { "cch": {
    "command": "${CLAUDE_PLUGIN_ROOT}/../../../MacOS/cch-mcp",
    "args": ["serve"] } } }
```

Each hook command in `cch-sub/hooks/hooks.json` is `"${CLAUDE_PLUGIN_ROOT}/../../../MacOS/cch-mcp" hook <event>`.

### Commands (R1)

| Command | Category | Section |
|---|---|---|
| `/task <text>` | `task` | Task |
| `/bugfix <text>` | `bug` | Bug |
| `/feature <text>` | `feature` | Feature |
| `/helper <text>` | `helper` | Helper |

Each command file is a prompt for main Claude (shown for `/feature`; others differ in the category line and brief guidance):

```markdown
---
description: Spawn a Feature subagent in its own worktree
argument-hint: <what to build>
---
The user wants a FEATURE subagent for: $ARGUMENTS

1. Call mcp__cch__list_subagents. Note each active subagent's title, brief and changed_files.
2. Write a self-contained brief: goal, relevant context from this conversation, likely files,
   acceptance criteria, constraints, how to verify.
3. If this work likely touches the same files as an active, unmerged subagent and merge order
   matters, pick a merge group name. Pass merge_group (and merge_index if order within the group
   is not simply "after the existing ones"). If the overlapping subagent isn't grouped yet, call
   mcp__cch__set_merge_order first to create the group with it.
4. Only if the user's text explicitly names a model for this subagent (fable, opus, sonnet, haiku, or a
   full claude-… model name), pass it as model. Otherwise omit model so the Settings default applies.
5. Call mcp__cch__spawn_subagent(category: "feature", title: <≤6 words>, brief: …, model?).
6. Reply with one line: the title, the model if you overrode it, and the merge group/index if any.
   Relay any warnings verbatim.
```

Brief guidance per category: **bug** — reproduce, find root cause, fix, add a regression test. **feature** — implement against acceptance criteria with tests. **task** — scoped change, follow instructions exactly. **helper** — research/analysis/support; may produce notes or small edits; commit anything worth keeping.

### Tools

| Role | Tool | Args → result |
|---|---|---|
| main | `spawn_subagent` | `category, title, brief, merge_group?, merge_index?, model?` → `{id, branch, worktree, model, warnings[]}` (invalid `model` → tool error listing accepted values) |
| main | `list_subagents` | — → `[{id, category, title, model, state, merge_group, merge_index, last_status, changed_files[]}]` (`changed_files` = `git diff --name-only base..HEAD` ∪ dirty files) |
| main | `message_subagent` | `id, text` → `{delivered, reopened}` |
| main | `set_merge_order` | `group, ids[]` → `{group, order[]}` |
| main | `mark_merged` | `id, merge_commit` → ok / error |
| main | `merge_failed` | `id, reason` → ok |
| subagent | `report_status` | `summary, done[], next[]` → ok |
| subagent | `mark_complete` | `summary` → ok / "commit first" error |

`cch-mcp serve` only lists the tools for its `CCH_ROLE` (D2).

### Spawn sequence (agentd, `spawn_subagent`)

0. If a `model` override is given and `SubagentModel.isValid` rejects it → tool error "Unknown model '<value>'. Use fable, opus, sonnet, haiku, or a full claude-… model name." Nothing is created.
1. `git -C <session_dir> rev-parse --show-toplevel` → `repo_root`. Failure → tool error: "This session isn't a git repository. Ask the user whether to run `git init` and make a first commit." (D6)
2. `base_commit = git rev-parse HEAD` (no commits → same error as 1). `base_branch = git symbolic-ref --short -q HEAD` (NULL if detached).
3. `git status --porcelain` non-empty → add warning: "Uncommitted changes in main are not visible to the subagent: <files>." (D5)
4. Insert row (`starting`) to get `id`. `slug` = lowercase title, non-alphanumerics → `-`, max 32 chars.
5. `branch = cch/<category>/<id>-<slug>`; `worktree_path = ~/Library/Application Support/ClaudeCodeHub/worktrees/<repo-basename>-<first 8 of sha1(repo_root)>/<id>-<slug>` (D4).
6. `git -C <repo_root> worktree add -b <branch> <worktree_path> <base_commit>`. Failure → row `failed`, tool error with git's stderr.
7. Subagent cwd = `worktree_path` + (`session_dir` relative to `repo_root`), so sessions opened in a repo subfolder stay in that subfolder.
8. Resolve/record group membership (§5).
8a. Resolve the model: `SubagentModel.resolve(override: model arg, categoryDefault: prefs["model.<category>"])`; store it in `subagents.model`.
9. Launch `cch-agent-host --agent-id <id>` detached. The host calls `hello` and receives the launch spec:

```
claude
  --session-id <uuid>
  --name "<Category>: <title>"
  [--model <subagents.model>]            # omitted when NULL (CLI default)
  --plugin-dir <bundle>/Contents/Resources/plugins/cch-sub
  --permission-mode acceptEdits
  --settings '{"permissions":{"allow":["Read","Edit","Write","Glob","Grep","Bash(git:*)","mcp__cch__*"]}}'
  --append-system-prompt "<subagent rules + category guidance>"
  "<brief>"
env: CCH_ROLE=subagent CCH_AGENT_ID=<id> CCH_SESSION_ID=<sid> CCH_SESSION_DIR=<session_dir>
     + ClaudeLocator.env()
```

Subagent rules (appended system prompt): you are a Claude Code Hub subagent working in an isolated git worktree on branch `<branch>`; commit in small logical steps on this branch; never push, never switch branches, never touch the main checkout; call `report_status` after each meaningful step; when the brief is fully done and everything is committed, call `mark_complete`.

The main session's launch adds: `--plugin-dir …/cch-main`, `--settings '{"permissions":{"allow":["mcp__cch__*"]}}'`, env `CCH_ROLE=main CCH_SESSION_ID CCH_SESSION_DIR`. Existing `ClaudeSettings.ensureWritten` behavior is unchanged.

The claude path comes from `ClaudeLocator.findExecutable()` (moved to `CCHCore`), overridable with `CCH_CLAUDE_PATH` for tests.

---

## §4 UI

### Left sidebar (L1)

Remove the tab strip and `AppState.SidebarTab`. Sidebar = header · `SessionsTab` · autosave footer.

### Right panel (L2, L3, R2, D1)

```
┌──────────────────────────────────────────────┐
│ [All] Agents  Task  Bug  Feature  Helper     │  chips
├──────────────────────────────────────────────┤
│ Subagents 4 │ Plans 0                        │  Agents off
│ Subagents 4 │ Plans 0 │ MCPs │ Agents │ Skills│  Agents on
└──────────────────────────────────────────────┘
```

- **Agents** is a toggle, not a filter: on → the MCPs, Agents, Skills tabs appear after Plans. Turning it off while one of those tabs is active selects Subagents.
- **All / Task / Bug / Feature / Helper** are multi-select filters over the Subagents tab's category sections (existing toggle semantics: All clears the others; empty → All). Group sections show if any member matches.
- MCPs / Agents / Skills tab bodies are the existing placeholder empty states moved from the sidebar. Discovery is out of scope.
- Tabs: `enum Tab { subagents, plans, mcps, agents, skills }`. Count chips: Subagents = non-archived count; others unchanged.

### Subagents tab (R3, R4, R12)

```
▣ MAIN · milegacy · main                      ●   ← pinned, never scrolls
────────────────────────────────────────────────
GROUP · theme                        1/3 merged
  ✓ 1 FEATURE  dark mode toggle         MERGED
  ● 2 BUG      sidebar contrast        [Merge]
      "fixed contrast tokens; running tests"  3m
  ○ 3 TASK     screenshots            waits #2
────────────────────────────────────────────────
TASK                                         1
  ● refactor PrefsStore                [Merge]
BUG                                          1
  ● crash on empty folder              [Merge]
FEATURE                                      0
HELPER                                       1
  ✓ research SMAppService               [Done]
────────────────────────────────────────────────
▸ DONE                                       2     ← collapsed; merged/stopped
```

- **Main row**: session name, current branch (from `git symbolic-ref`, refreshed on subagent changes), main status dot. Highlighted when main is displayed. Click → show main.
- **Group sections** first (by creation), members sorted by `merge_index`; header shows `merged/total`. A grouped subagent appears only in its group. A fully merged group moves into Done.
- **Category sections**: Task, Bug, Feature, Helper — always listed with count; ungrouped, non-archived subagents only.
- **Done**: `merged` and `stopped`, collapsed by default, with a **Clear** button (hides; rows stay in DB). `discarded` rows are never shown.
- **Row**: state dot/icon · index badge (grouped only) · category chip (in group sections only) · title · model chip (only when the subagent's model differs from its category's current default) · one-line last status summary + age (muted) · action button. Selected row highlighted.
- **Action button**: `Merge` / `Done` (D9) / `Resume` (manual-resume interrupted) / disabled `waits #n` / disabled `busy` (running, needs_input, starting) / `MERGING…` label (`awaiting_commit`) / `Re-send Merge` (`awaiting_main`).
- **Context menu**: Stop · Reopen (stopped/complete without host) · Reveal Worktree in Finder · Copy Branch Name · Discard… (confirm dialog; stops host, `git worktree remove --force`, `git branch -D`).
- All colors from `Theme.swift`; dots follow the existing red > green > yellow > gray priority.

### Main pane swap (R5)

- `AppState.selectedSubagent: [Int64 /*sessionID*/: Int64 /*agentID*/]`. Missing key = main.
- `MainColumnView.terminalArea` uses conditional rendering (spec rule 10): `TerminalHost(session:)` when no selection, else `SubagentTerminalHost(agentID:)`.
- `SubagentTerminalRegistry` caches one SwiftTerm `TerminalView` per subagent, fed from the `output` stream even while hidden, so switching is instant. Delegate `send(source:data:)` → `sendInput`; `sizeChanged` → `resize`. On first attach, it feeds the scrollback from `attach`, then sends a resize to force a Claude redraw.
- A read-only view (complete with no host) feeds `pty.log` and shows a **Reopen** bar at the bottom.
- **Topbar view label**: `MAIN` badge, or `FEATURE · dark mode toggle · cch/feature/7-dark-mode` with a **Back to Main** button.

### Settings → Subagents (R15)

New section in `SettingsSheet`, below the Claude state directory. Values are read from and written to agentd (`getSettings` / `setSettings`), not app.db, because agentd resolves them at spawn time.

```
SUBAGENTS
Default model
  Task      [ CLI default ▾ ]
  Bug       [ Sonnet      ▾ ]
  Feature   [ Opus        ▾ ]
  Helper    [ Custom…     ▾ ] [ claude-haiku-4-5-20251001 ]
            Applies to new subagents. Running ones keep their model.
[✓] Resume interrupted subagents automatically
```

- Picker values: CLI default (stored `""`), Fable (`fable`), Opus (`opus`), Sonnet (`sonnet`), Haiku (`haiku`), Custom… (shows a text field; stored verbatim).
- Custom text is validated with `SubagentModel.isValid` on commit. Invalid → red helper text, value not saved.
- Saved when **Done** is clicked, together with the existing state-directory apply.
- agentd unreachable → section disabled with "Subagent service isn't running."
- The sheet grows from 540×360 to 540×600 to fit.

### Other surfaces

- **Status bar**: replace `0 panes · 0 tasks` with `N subagents · k need you`.
- **Session dot**: `hasPendingAction` is true if any of the session's subagents is `needs_input` (app sets it from agentd pushes).
- **agentd unavailable**: banner at top of the Subagents tab — "Subagent service isn't running." [Retry] [Open Login Items] (`SMAppService.openSystemSettingsLoginItems()`).

---

## §5 Messaging, merging, merge order

### Messaging (R10)

`message_subagent(id, text)` → agentd → host `write`: `ESC[200~` + text + `ESC[201~`, 50 ms pause, then `\r`. Claude Code queues it if the subagent is mid-turn. If the subagent has no live host (complete/stopped/interrupted-manual), agentd reopens it with `--resume` first, waits for the first `Stop`/idle hook or 20 s, then delivers. `discarded`/`merged` → tool error.

You can also click a row and type into its terminal directly.

### Merge flow (R8, R9)

Click **Merge** on subagent S:

1. **Gate (agentd)**:
   - S is `idle` or `complete` (D7), else error "busy". Exception: `merging/awaiting_main` skips to step 5 (Re-send Merge).
   - If grouped, every member with a lower `merge_index` is `merged` or `discarded`, else error "waits on #n" (R11).
2. **Nothing to merge (D9)**: if `git rev-list --count base..branch == 0` and the worktree is clean → mark `merged`, clean up (step 7), done. The button already reads **Done** in this case.
3. **Commit**: if the worktree is dirty → state `merging/awaiting_commit`; send S: "Commit all your remaining work now with a descriptive message, then call mark_complete." Wait for clean tree + `mark_complete` (which sets `completed_at` but leaves state `merging`). Timeout 10 min → cancel: state becomes `complete` if `completed_at` is set, else `idle`; row shows "commit timed out".
4. Record `merge_tip = git rev-parse <branch>`; state `merging/awaiting_main`.
5. **Deliver**: agentd → app `deliverToMain`. The app clears the selection (view → Main), then types the prompt into the main PTY using the same bracketed-paste sequence:

   > [Claude Code Hub merge request · subagent #7] Merge branch `cch/feature/7-dark-mode` (subagent "dark mode toggle", based on `abc1234`) into your current branch.
   > Subagent summary: <last status summary>
   > Commits: <`git log --oneline base..merge_tip`>
   > Files: <`git diff --stat base..merge_tip`>
   > Steps: (1) make sure your working tree is clean — commit your own work first, or ask me if unsure; (2) `git merge --no-ff cch/feature/7-dark-mode`; (3) resolve any conflicts preserving both sides' intent; (4) run the project's build and tests; (5) call `mcp__cch__mark_merged(id: 7, merge_commit: <sha>)`. If you can't finish, call `mcp__cch__merge_failed(id: 7, reason: …)`.

6. **Verify `mark_merged`**: `git -C <repo_root> merge-base --is-ancestor <merge_tip> HEAD`. False → tool error "merge_tip <sha> is not in HEAD yet", state unchanged.
7. **Newer commits check**: if `git rev-parse <branch>` ≠ `merge_tip` (S committed after the request), skip cleanup, set S to `idle` with note "new commits after merge" (Merge enabled again).
8. **Cleanup (D8)**: host `terminate` → `git worktree remove <worktree_path>` → `git branch -d <branch>`. A dirty worktree at removal → leave it and the branch, row warning "worktree not removed: uncommitted files". State `merged`, `merged_at` set, next group member becomes mergeable, app refreshes.
9. `merge_failed` → cancel: `complete` if `completed_at` is set, else `idle`; row shows the reason.

### Merge groups (R11, R12)

- `spawn_subagent(merge_group: "theme")` creates the group if needed; with no `merge_index`, S is appended (max+1). An explicit index shifts later members up.
- `set_merge_order(group, ids)` creates the group if needed and sets the order for the listed ids. Merged members keep their positions ahead of unmerged ones; indexes are renumbered 1…n with no gaps. An id already in another group is moved.
- Context menu **Remove from Group** on a row (ungrouped; indexes renumber).
- Gating is enforced in agentd (not just UI), so main Claude can't bypass order via tools.

---

## Error handling summary

| Failure | Behavior |
|---|---|
| agentd not reachable (app) | Banner with Retry / Open Login Items; main session unaffected |
| agentd not reachable (`cch-mcp`) | Tool error "Claude Code Hub subagent service isn't running"; hook exits 0 with no output (never blocks Claude) |
| Not a git repo / no commits | Tool error asking main Claude to consult the user (D6) |
| `git worktree add` fails | Row `failed` with stderr; tool error |
| `claude` not found | Row `failed` "claude executable not found" |
| Host crash | `interrupted` → auto-resume with crash-loop guard |
| agentd crash | launchd restarts; hosts reconnect; RecoveryPlanner reattaches |
| Commit wait timeout | Merge cancelled, previous state restored, row note |
| `mark_merged` not verifiable | Tool error; stays `merging` |
| Worktree dirty at cleanup | Worktree kept, row warning |
| Disk: `pty.log` over cap | Rotate once, drop oldest |

## Code layout

```
Package.swift                      + targets below, test targets
Sources/
  CForkpty/                        (existing, now used by host)
  CCHCore/                         no AppKit
    Models/        Subagent.swift, SubagentCategory.swift, MergeGroup.swift, StatusReport.swift
    Rules/         SubagentStateMachine.swift, MergeGate.swift, MergeOrder.swift, SubagentNaming.swift,
                   RecoveryPlanner.swift, HookPolicy.swift, SubagentModel.swift
    Recovery/      RecoveryPlanner.swift
    Prompts/       SubagentPrompts.swift (system rules, nudges, merge prompt, commit request)
    XPC/           Protocols.swift, DTOs.swift, ServiceNames.swift
    MCP/           JSONRPC.swift, ToolSchemas.swift
    Git/           GitRunner.swift, GitWorktree.swift
    ClaudeLocator.swift            (moved from app)
  CCHAgentd/       main.swift, AgentdListener.swift, AgentsDB.swift, SpawnService.swift,
                   HostSupervisor.swift, OutputStore.swift, ToolHandlers.swift,
                   HookHandlers.swift, MergeService.swift, Recovery.swift
  CCHAgentHost/    main.swift, PTYSession.swift, AgentdConnection.swift
  CCHMCP/          main.swift, StdioServer.swift, HookCommand.swift, AgentdConnection.swift
  ClaudeCodeHub/   + Subagents/ AgentdClient.swift, SubagentStore.swift,
                     SubagentTerminalRegistry.swift, SubagentTerminalHost.swift, AgentdRegistration.swift
                   + Views/RightPanel/Subagents/ SubagentsTab.swift, MainRow.swift,
                     SubagentSection.swift, SubagentRow.swift, MergeGroupSection.swift
Resources/plugins/cch-main/…, cch-sub/…
Support/dev.cch.agentd.plist       BundleProgram Contents/MacOS/cch-agentd, MachServices, KeepAlive
scripts/bundle.sh                  build → assemble .app → sign inner binaries → sign bundle → clear quarantine
Tests/
  CCHCoreTests/                    state machine, merge gate/order, naming, recovery planner, prompts, JSON-RPC
  CCHAgentdTests/                  GitWorktree + SpawnService + MergeService against temp repos, fake claude
  Fixtures/fake-claude             script: echoes args/env, calls cch-mcp tools on cue
```

Products: `ClaudeCodeHub`, `cch-agentd`, `cch-agent-host`, `cch-mcp`.

## Testing

- **Unit (CCHCore, `swift test`)**: every state transition, legal and illegal; merge gate for grouped and ungrouped subagents; `set_merge_order` renumbering; branch/worktree naming and slugging; RecoveryPlanner decision table (one test per row); Stop/PostToolUse hook decisions; prompt rendering snapshots; JSON-RPC encode/decode.
- **Integration (CCHAgentdTests)**: real `git` in temp dirs — spawn creates the worktree at the right base; dirty-main warning; non-git refusal; merge verify + cleanup; "new commits after merge"; nothing-to-merge. `fake-claude` via `CCH_CLAUDE_PATH` so no tokens are spent. XPC protocol round-trips over `NSXPCListener.anonymous()`.
- **Manual end-to-end checklist** (per phase, in the plan): real bundle, real `claude`, covering R1–R14 and L1–L3, including quitting the app mid-run, `kill -9` of a host, `kill -9` of agentd, and a reboot-style agentd restart.

## Build order (phases)

0. **Spike (throwaway)** — the six proofs in §1 "Risk". Go / fallback decision, tool prefix, worktree location.
1. **Foundation** — package restructure, `CCHCore` models/rules/tests, `scripts/bundle.sh` producing a four-binary signed bundle.
2. **Runtime** — agentd + host + worktrees + output streaming; app connects and renders a subagent terminal from a debug-only "Spawn Test Subagent" menu item.
3. **UI** — sidebar tabs removed, right panel tabs + Agents toggle + chips, Subagents tab, Main row, main-pane swap, status bar, session dot.
4. **Commands & tools** — `cch-mcp`, both plugins, `/task` `/bugfix` `/feature` `/helper`, spawn/list/message, per-category model settings + override (R15), main-session launch flags + resume.
5. **Status & recovery** — hooks, `report_status`/`mark_complete`, RecoveryPlanner, auto-resume, read-only complete view (R13, R14).
6. **Merge** — merge flow, groups/order, cleanup, Done section (R8–R12).

## Non-goals

- Subagents spawning subagents (D2).
- Concurrency limits / queueing of subagents.
- UI for reordering merge groups (tool + Remove from Group only).
- Subagent → main notifications on completion.
- Moving the main session into agentd.
- MCP / Agents / Skills discovery (tabs move; contents stay placeholders).
- `_tasks.md` tracker and prefix dispatch from the original spec (D13).
- Pushing branches or opening PRs.
