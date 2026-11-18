# guard-wait round 2 — the fix misses the measured incident (verdict: land after fixes)
Same worktree/branch (head 6f12e7bc). Each: fix + test failing before/passing after; append to REPORT.md.
Commit locally; never push.
1. Both 18/11 kills went through CODEMODE: the stopped calls were
   `codemode({"code":"const r = await tools.operation({action:\"await\", id:\"op-1794999886918178-711604-211\", wait_for:\"settled\"...`
   (23 hits) and `codemode({"code":"\nawait tools.operation({action:\"await\", id:\"op-1795006184055413-975920-619\", wait_ms: 10000}...`
   (14 hits) in avell's session records. The tool name is `codemode`, so wait_fact returns nil and the 3-round stop
   still fires; inside codemode a call outliving its wait answers {state:"pending", op} (codemode.lua:561) and
   `pending` is not in LIVE_OPERATION_STATES. Fix: when a codemode call returns, derive the wait fact from the
   operation calls the script made, read from the NODE's operation record (not the model's args); treat the
   codemode `pending` answer for a live op as live. Test: a codemode row reproducing exactly those two shapes.
2. Fast polling up to 24 h: direct status answers instantly (operations.rs "status" => snapshot), wait capped
   10 s, each live answer resets repeat+idle streaks, node accepts timeouts up to 86400 s. Count a live wait as an
   observation only if the op's elapsed moved by >= a floor (e.g. 30 s) since the last counted one, or cap
   consecutive instant polls; state the rule in the stop message.
3. Mixed rounds: if one fact is live, round_wait takes it, so [await settled A, status running B] repeated never
   stops. A round counts as a wait only if EVERY operation fact in it is live.
4. Lower risk: await/status ignore the owner (tools.lua sets args.owner; operations.rs ignores it for these). A
   wait on another session's operation must not count as this session's progress (or is refused by name).
