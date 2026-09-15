---
name: helper
description: Spawn a Helper subagent in its own git worktree for research, analysis or support work
argument-hint: <what to look into>
---
The user wants a HELPER subagent for: $ARGUMENTS

1. Call mcp__plugin_cch-main_cch__list_subagents. Note each active subagent's title, status and changed_files.
2. Write a self-contained brief for the subagent (research/analysis/support; small edits or notes are fine): goal, relevant context from this conversation and core memory, likely files, acceptance criteria, constraints, and how to verify.
3. If this work likely touches the same files as an active, unmerged subagent and merge order matters, choose a merge group name and pass merge_group (plus merge_index if it must not simply go last). If the overlapping subagent isn't grouped yet, first call mcp__plugin_cch-main_cch__set_merge_order to create the group with it.
4. Only if the user's text explicitly names a model for this subagent (fable, opus, sonnet, haiku, or a full claude-… name), pass it as model. Otherwise omit model so the Settings default applies.
5. Call mcp__plugin_cch-main_cch__spawn_subagent(category: "helper", title: <at most 6 words>, brief: …).
6. Reply with one line: the subagent number and title, the model if you overrode it, and the merge group/index if any. Relay any warnings verbatim.
