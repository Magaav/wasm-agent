# Mission change/guard-wait — waiting on a running operation is progress, not a loop

Measured twice on 18/11: harness-fixes-rust (126 rounds) and vault-one round 2 (207 rounds, 55 min, 46.2M input
tokens) were both ended by `guard_repeated_calls` on `tools.operation({action:"await", id:"op-...", wait_ms:...})`
repeated 3 times while a long cargo build/test ran. The codemode script budget (~290 s) is why the model awaits
in rounds at all. Fix (lua/core/progress_guard.lua and its caller; one implementation):
1. A repeated await/status on an operation whose state is still running/accepted is NOT a repeat without
   observation: the operation's elapsed time and state are the observation. Count it as waiting; cap total wait
   by the operation's own timeout, not by 3 rounds.
2. A repeated await on a SETTLED operation (same answer) is still a loop and still stops.
3. The message for a real repeat names the call and suggests the next step.
Tests: a fake running operation awaited 10 times is not stopped; a settled one awaited 3 times is; existing
progress-guard tests unchanged. Base: change/harness-land (shares agent.lua); touch only the guard and its tests.
Commit locally; never push.
