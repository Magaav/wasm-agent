# Mission change/mastermind — orchestration built into the CLI: a session forks itself and runs workers, visible in Fleet View

Victor 18/11: the master mind is "just like Claude here", but built in: from the CLI and from inside any
session, the session can fork itself and create brand-new subsessions (workers/subagents) and coordinate them.
That machinery ALREADY EXISTS (subagent facade, fork, workers - lua/core/subagents.lua, docs/ORCHESTRATION*.md,
docs/ORCHESTRATOR-WORKSPACE.md). This mission is not new architecture: it is brutal refinement, meticulous
testing and polish of what is there, until it is reliable and pleasant, and every subsession shows in Fleet
View. Depends on guard-wait being landed. It DEFINES the fabric API (one implementation) that Fleet View and the
wa-fabric bridge (change/fabric-bridge) are thin faces of; design the API so every tool in fabric-bridge.md maps 1:1.

1. Inventory first (REPORT.md): every way today to fork / spawn / delegate / supervise / cancel / collect a
   subsession, local and on another node; run each one for real (scratch homes, stubbed or cheap provider) and
   record what works, what fails, what is confusing - quoted, measured. One implementation per behaviour: where
   two paths do the same thing, converge them.
2. Refine to these properties, each with a test that fails before and passes after:
   - fork: a session can fork itself (same context, new session id) and the fork appears at once as a child;
   - spawn: a fresh worker with its own brief, on this or another node, with its own session folder;
   - supervise without burning tokens: child state changes (started, commit, real failure, done, rc) arrive to
     the parent as events; the parent never needs polling rounds of the model to know;
   - collect: a child's result (answer, files/commits, failures) is returned to the parent as data;
   - control: cancel/stop a child cleanly (the run really ends - see weakness 13), resume a child, message it;
   - a child that outlives its parent, or whose CLI exits, is never a silent second writer.
3. Fleet View integration (done in change/fleet-view on this API; here only the data it needs): every subsession under its node with parent->child links, state, rounds, tokens,
   age; enter any of them read-only; the parent's status bar shows its children in one line.
4. Polish: names/titles readable at a glance; errors quote the input and name the cause; no internal status
   strings leak into the user's view.
5. Any change to orchestrator/subagent prompt text is shown to Victor VERBATIM before landing.
Done when: from the master chat, a real small goal is split into 2-3 workers on two nodes, followed live in
Fleet View, results collected, one worker cancelled mid-way cleanly - recorded as an end-to-end proof; the
refined paths have tests; no regression in existing orchestration tests.
