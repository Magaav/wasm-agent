# Independent exact-tip bounded review

Verdict: NARROWED, not a complete safety acceptance. See verdict.json for exact anchors and limitations. No producer implementation edited. Own managed branch retained without rename; candidate fast-forwarded into reviewer-owned checkout.

Reproduce from this checkout:
```
node scripts/test-delivery-refresh.mjs
node scripts/test-delivery-admission.mjs
node scripts/test-delivery-store.mjs
node scripts/test-merge-lane.mjs
node reviews/local-b10/attacks.mjs
node scripts/lib/wave-guard.mjs . admit
```
All four suites exited 0, with original full stdout preserved beside this document (58 + local consumer; 9 store; 107 merge). Refresh/local explicit zero skips. Admission suite has no aggregate skip field; inspected assertions ran. Merge includes intentionally skipped contained-tip and ungated-policy scenarios, not a full release gate. Independent driver uses untouched original private fixture, absolute source imports and actual delivery-admission CLI, actual focused proof, private OS-temp SQLite/Git; three negative controls: revoked reviewer exit2, different review tip/same tree exit2, dirty caller policy override exit4. Restored positive CLI exit0 explicitly private-fixture-only. Scratch cleaned by original fixture; no arbitrary DB promoted to runtime authority.

Inspected three-commit diff, delivery-local helper, admission CLI/evaluate, refresh and store CAS, merge consumers, full-gate-proof, wave guard, test assertions and complete newly produced logs. Original producer/coordinator reports were only provided as task context; not separately retrieved. No retrospective claim of reading unavailable reports.

Runtime home on this machine is C:/Users/Victor: recorded env/result in home.log. Host main.rs sets HOME to resolve_home before host.paths uses HOME; explicit WASM_AGENT_HOME is a home directory, then .wasm-agent appended. Current Windows USERPROFILE/HOME agree. Helper lacks host resolve_home's HOMEDRIVE/HOMEPATH fallback when USERPROFILE is absent: cross-environment compatibility not proven.

Normal wave refusal reproduced exit2, preserved in wave.log; optional recovery forwarding is INCOMPLETE because current wave-guard ignores recovery. No legacy row relabelled or written. No live memory/jobs/wave store mutations, remote branches/upstream/fake refs, pushes, hooks bypass, main movement, install/deploy/client/request effects, native builds or full release gate. finish check was observed refusing dirty/unpushed state (initial invocation lacked expected-head); final check/verify are recorded separately. Full gate deliberately not run under assignment. Main-only prohibits pushing this reviewer branch.

Record CAS protects record snapshots/revisions; refresh preserves prior review/admission/lane/proof/local evidence and invalidates current generation. Producer/reviewer managedLocal validates full40, allocated binding, branch, shared Git and final Agent session trailer. Review tip binding is blocking only in main-only mode, maintaining published compatibility. Local evidence published:false does not assert publication; focused proof is not combined gate evidence. More complete race injection and real runtime canonical binding test remain required for unconditional acceptance.
