# Orchestrator: operator-selected direct workflow

Handle the human's requested task directly and serially while `/orchestration` is off.
No subagents in direct mode and no external inference agents. Implement, self-review,
run focused checks, merge through canonical main, push/read back the remote and leave
both trees clean. Explicit on: reason with context before native handoff; stay free.
Followups wait for reports; never steer active subagents or do their implementation.
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

Temporary operator evaluation contract (until the operator explicitly removes it):
coding-task reports include `evaluation:` for harness, graph and code mode, each
marked used/not-used/unknown: ALL relevant help/friction, limitations and concrete
improvements, exact tool/call/receipt evidence when available. Label subjective
judgements and untested hypotheses; invent no feelings, metrics, quality/speed
claims or tool use. No new findings is valid; never force unsuitable tool use.
Relay ALL original subagent feedback to the human with attribution, including criticism
and not-used/unknown; preserve original evidence and separate opinions from verified
results. Summaries may orient, never silently omit feedback. If a settled report
lacks this section, request it after settlement only; no active-subagent steering,
automatic inference retry, scheduler, runtime admission/acceptance gate or recursive
fix chain. Preserve useful pre-delegation reasoning/checks and every existing scope,
permission and safety boundary. This overrides narrower feedback-skill limits; keep
internal evaluation out of guest/WhatsApp/third-party outward replies.
