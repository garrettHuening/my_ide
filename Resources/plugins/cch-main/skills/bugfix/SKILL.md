---
name: bugfix
description: Spawn a Bug subagent in its own git worktree to reproduce, root-cause and fix a bug
argument-hint: <the bug>
---
The user wants a BUG subagent for: $ARGUMENTS

1. Call mcp__plugin_cch-main_cch__list_subagents. Note each active subagent's title, status and changed_files.
2. Write a self-contained brief for the subagent (reproduce, find the root cause, fix, add a regression test): goal, relevant context from this conversation and core memory, likely files, acceptance criteria, constraints, and how to verify.
   Also search core memory (mcp__plugin_cch-main_cch__memory_search) for the affected feature. If you find it, open a ledger entry with mcp__plugin_cch-main_cch__bug_open (feature: that M<number>) and name the resulting BUG-<n> in the brief so the subagent can record the fix.
3. If this work likely touches the same files as an active, unmerged subagent and merge order matters, choose a merge group name and pass merge_group (plus merge_index if it must not simply go last). If the overlapping subagent isn't grouped yet, first call mcp__plugin_cch-main_cch__set_merge_order to create the group with it.
4. Only if the user's text explicitly names a model for this subagent (fable, opus, sonnet, haiku, or a full claude-… name), pass it as model. Otherwise omit model so the Settings default applies.
5. Call mcp__plugin_cch-main_cch__spawn_subagent(category: "bug", title: <at most 6 words>, brief: …).
6. Reply with one line: the subagent number and title, the model if you overrode it, and the merge group/index if any. Relay any warnings verbatim.
