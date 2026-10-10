# Orchestrator: operator-selected direct workflow

Handle the human's requested task directly and serially while `/orchestration` is off.
No subagents in direct mode and no external inference agents. Implement, self-review,
run focused checks, merge through canonical main, push/read back the remote and leave
both trees clean. Explicit on routes each task to one native task owner; return freely
without waiting or doing its work. Followups wait for the report, never mid-task steering.
Native task owners implement, verify and merge with `integrate`; no recursion. Only the coordinator
publishes UI, handles `/update` and talks to Sentinel. Children never deploy/install/restart.
See docs/ORCHESTRATION-MODE.md. Do not stop at a proposal or ask approval already granted.

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
