# Binding-discovery v1

`solver/` is the sanitized input, not the grader. `manifest.json` contains private
original-content hashes and provenance references and must NOT be mounted to a
solver. The old `provenance.candidate.json` is retained as the earlier incomplete
checkpoint, not the final descriptor.

Export a blind, clean tracked task snapshot with:

```
node scripts/agent-benchmark.mjs --binding-export <fresh-private-output>
```

Only the original `dc11c462` task tree, `solver/` input/declarations and sanitized
artifact are copied. No original Git directory/remotes/history, grader, known
repair, private provenance, later discussion or automatic memory is injected.
The five instruction files are checked byte-for-byte against that source.
Source and harness runtime are separate. This CLI exports files, not a security
sandbox or an authorized paid trial.

Model-free behavioral preflight:

```
node scripts/agent-benchmark.mjs --binding-preflight <separately-pinned-native-binary> <fresh-private-evidence>
node scripts/agent-benchmark.mjs --binding-grade <native-binary> <candidate-source> <fresh-private-evidence>
```

The hidden oracle is outside each task root. It checks actual native Lua discovery,
load state, permissions, parameter-schema preservation, conditional tools, failed/
unknown bindings, drift, unbound status and real process restart. Client/network
and other external effects are fenced before importing task modules; client status
uses a mock only. This is not an OS security boundary for malicious source: future
solver grading must remain inside the credential-isolated container substrate.

Preflight proves original source fails, known repair passes and eleven deceptive
controls fail: blanket deny, discovery hiding, hardcoded availability, guard bypass, unbound reject,
profile bypass, stale loaded state, actual private DB loss across restart, role
bypass, dynamic-scope hardcode and schema drift. The restart-loss control removes
only that private grader DB, never any original session.

Normalization is disclosed in `manifest.json`. The exact task and two refusal
objects are unchanged. Private Windows paths/identifiers and unrelated simultaneous
calls are not exported. The original artifact is privately sealed; solver HTML is
an explicitly sanitized reference, not the original prompt-bearing artifact.
Historical measured run elapsed time is1,797,766ms; start/end field subtraction is
1,797,769.200ms and the answer's recorded duration is1,797,387ms. These are different
observations, not a paid benchmark result or a duration for the restricted solver
handoff. The original run included work outside the future solver's allowed scope.

## Declaration evidence limits

The52-tool master catalogue is reconstructed model-free from the exact original
source. The11-tool bootstrap array is copied from retained original-runtime envelope
proof. That proof is not the exact historical task provider body; the original
pre-request loaded-name state is not retained in selected evidence and stays unknown.
This distinction is disclosed, not filled in by replaying later state. Required
allocation, direct original calls/refusals and the task/run boundary are exact.

## Launch remains refused

Paid launch remains refused: exact route/runtime/image/package/model/reasoning/
token/quota/spend pins and complete attempt capture must still be proven. No code-
mode engine is implemented here. Canonical source confirms the Node-free
Rust/Wasmtime V2 target: no Node process,
bridge or fallback during execution. V1 Node hosting is comparison only; benchmark
Node tooling and Pi are separate. The engine/guest ABI/imports remain unimplemented.
