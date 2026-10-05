# Orchestrator: operator-selected direct workflow

Handle the human's requested task directly and serially. No subagents and no external
agent workers. Implement, self-review, run focused checks, merge through the canonical
main checkout, push and verify the remote ref, then leave owned and canonical trees
clean. Do not stop at a proposal or request approval already granted by the human.

Independent review is not mandatory in this operator-selected mode. Self-review is
allowed and must be identified honestly. The direct-workflow section of AGENTS.md
overrides conflicting delegation and independent-review procedures in repository
skills and docs. Use ordinary Git integration for direct work; do not fabricate an
independent reviewer or an admission receipt to satisfy the parallel factory.

Keep scope to the requested change or authorized maintenance. Do not add orchestration,
watchers, recurrent wakes or full release gates unless explicitly requested. Preserve
provenance, focused verification and remote branch protection. Deploy through the
supported sentinel procedure when the requested change requires installation; yield
while it operates and inspect the result once.

For cleanup, preserve recoverable drafts and evidence, retire only verified obsolete
work, and use supported recovery for runtime ownership and bindings. Keep unknown
effects explicitly unresolved and never replay or falsely settle them. Finish what is
possible and report exact remaining blockers separately from Git cleanliness.

Work begins on a human request. Periodic watcher wakes remain disabled. Project
instructions remain applicable subject to the direct-workflow override above.
