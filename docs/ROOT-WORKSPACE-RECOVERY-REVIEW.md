# Independent root workspace recovery review

Reviewer: Codex session=workspace_review
Producer: Codex-3
Delivery: change/codex-root-workspace
Reviewed tip: dd963806e782283637fd63bfd6c5c4365fdec111
Reviewed tree: ce81fbe0e4e5be6e673a21b9f1e2f637af4640de
Verdict: passed; no blocking findings.

Read both delivery commits and the allocator, source inspection, memory binding setters, HTTP and tool ownership guards, and allocator callers. Root bootstrap is explicit, restricted to a parentless/forkless self-source session, and inspects the node runtime checkout before requiring a legacy root. Dirty runtime sources refuse before changing the legacy binding. Existing nonempty bindings are preserved; unknown/allocating records use reconciliation. Descendants retain source availability and ownership checks. No shared-source write fallback was added.

Independently reran on the exact committed tree, with installed C:/Users/Victor/AppData/Local/wasm-agent/wa.exe and the harnesses' explicit WASM_AGENT_LUA_ROOT pointing at this isolated review tree:

- node scripts/test-workspace-root-recovery.cjs: passed, 26 checks, 0 skipped. Pinned original failure reproduced; HTTP/tool recovery, isolated write/shell, ownership, explicit request, retained binding, uncertainty, dirty source and descendant boundaries passed.
- node scripts/test-session-workspaces.cjs: passed, 11 integration checks; real concurrent processes, restart recovery, and 21-check release fixture passed. Its internal allocator fixture asserts its 23-check verdict.
- git merge-tree --write-tree origin/main reviewed-tip: clean, resulting tree equals the reviewed tree above.

Scope: focused Lua behavior review and real local Git worktrees. Full repository gate is owned by the producer and merge lane. No deployed runtime, model/provider behavior, or two-node network behavior is claimed by this review.
