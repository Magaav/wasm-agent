# harness-land round 3 — independent review of round 2 + items 6-8: do not land yet

Same worktree/branch (change/harness-land, head 3ce1a95f). Each: fix + a test that fails before and passes
after, built through the REAL code path (real session constructors, real sentinel intake); append to REPORT.md.
(Finding 3 - the mesh pin - is handled by the components-toolchain mission; do not touch components.lock.)
Commit locally; never push.

1. Item 7 retires a held deploy's directory, then spams again (rust/wa-sentinel/src/observation.rs observe()/
   verdict()). binding.json is written only at admit (bind_parent, deploy_protocol.rs:124) while intake rewrites
   intent.json/ack.json every tick (main.rs:2489/:2537): a protocol deploy held >300 s (busy / protocol not ready /
   parent_owner_unavailable) is judged "missing binding.json" = structural and moved to deploy-protocol-retired/,
   with its evidence; the next intake recreates it; after grace `retire` fails because the target exists and,
   since verdict keeps answering Retire, `return-observation-retire-failed` is written every tick. Fix: structural
   only when the id is in neither requests/ nor claimed/; after a failed retire store a quiet state, never retry
   per tick. Test: a held deploy with intent+ack and no binding survives N ticks with one line at most.
2. Operator exception unreachable (round-1 #1/#2). workspaces.lua:85 requires an empty objective, but every real
   operator session has objective "chat" (chat.lua:261, commands.lua:187, agent.lua:866, memory.lua:672 title or
   "chat", subagents.lua:973), so `wa chat` on a node without wave registration is refused again; the test passes
   only with objective '' (test-wave-operator-session.lua:105,116), a shape no code produces. Accept '' or
   'chat', exclude 'remote' and 'subagent', keep the owner-principal check; build test sessions through
   commands.new_session / memory.ensure_session.
4. Item 6 is silent for protocol deploys: withdraw_request (main.rs ~2093) settles the outcome only without
   expected_sha; a withdrawn protocol deploy never emits sentinel.return and its state.json stays held/accepted,
   so the requesting session waits forever. Record a withdrawn phase/return event. Test with expected_sha.
5. Minor: wire scripts/test-deploy-runtime-recheck.sh into a harness (the orphan ledger scans only .mjs/.cjs/.js -
   extend it to .sh test files too); document in docs that a `js run` fence inside a list item is not executed and
   not flagged (accepted trade-off), or flag it.
