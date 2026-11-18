# mission-fabric round 2 — liveness is the node's run, not the launcher's pid

Same worktree/branch (head 84a195c0). Your REPORT measured it: session 830fa92f printed provider_stalled and
its CLI exited rc=1, but the node-side run kept writing; the relaunch made two writers. So:
1. `mission.sh start` refuses while the node has an unfinished, recently active session for this mission
   (read `wa sessions` / the node's run lease, matched by mission name and worktree), naming the session id;
   `--force` only with that session first cancelled through wa, never by killing processes by pattern.
2. A per-mission lock owned by the node-side run (not the CLI pid), released when the run settles; `status`
   reports the run's real state from the node, not from run.pid.
3. Fixture: a stub wa whose CLI exits while a "node run" stays unfinished -> start refuses with the session id.
4. Run scripts/fast.sh once (the first round did not) and classify reds against the base.
Commit locally; never push.
