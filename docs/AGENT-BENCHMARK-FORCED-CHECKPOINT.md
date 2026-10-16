# Forced-code-mode parallel pilot: blocked implementation checkpoint

> Historical checkpoint at `de33333`, superseded by the coordinator-authorized
> adapter prerequisite and [the explicit forced/parallel guide](AGENT-BENCHMARK-FORCED.md).
> The failures and original missing provenance below remain historical evidence,
> not current qualification or a new execution.

**Not qualified, not integrated, not ready for a live wave.** The old serial and
Pi-only commands remain separate. No new approval reference has been fabricated.

The experimental implementation adds a common neutral `codemode` schema/appendix,
private native dispatcher admission (only trusted VM callbacks can enter nested
native dispatch), a Pi tool using the pinned reference VM, host protocol/nested
call journals, guarded `--pilot-forced-qualify`, `--pilot-forced-prepare`, and
`--pilot-forced-run-approved` entries, and a staged parallel start/actor-settlement
barrier. All lifecycle promises settle before grading. Four-way timings are
shared-CPU/provider-contention affected, not clean backend latency comparisons.
The 120-dispatch/20M input/120k output/45min/180s/zero-trial-retry per-arm envelope
is unchanged. Up to 8CPU/8GiB of box limits plus uncapped Windows controllers is
not a host capacity or reservation claim. Workspace disk quota and dollars remain
unknown. No production defaults or instruction files change.

The q5 V2 log reported automatic rg provisioning after PATH was restricted;
that attempt's installation/download outcome was not independently verified.
The later copied-rg PATH preparation prevents that trigger but has not received a
new runtime qualification. No Node installation was attempted.

Mapping (all explicitly adapted): Pi 1.2 and historical b384 wasm use benchmark
Node QuickJS-WASI; candidate V1 uses Node; candidate V2 uses native Rust/Wasmtime,
without a reference endpoint. V2 PATH removes Node, retaining a copied existing rg
binary to avoid the runtime's automatic rg provisioning. The benchmark controller
and Pi remain Node processes outside V2 VM execution.

## Actual contract blocker

During the real synthetic-vault/Docker concurrent fixture, native `tools.write`
executes the task-file write, then its original changeset recorder attempts to
read its generated controller-private artifact through the blind filesystem
adapter. This is refused as `sandbox_path_outside_workspace`. It is an effect
followed by a native exception, **not a successful task operation**. The forced
broker now halts the wave on that unknown outcome; no model/tool replay is allowed.

Original evidence under the task's owned scratch root:
`C:/Users/Victor/.wasm-agent/session-scratch/6368696c643a666f726365642d636f64656d6f64652d706172616c6c656c2d32303236313031352d31/`

- `q4`: native journals `records/{wasm-current,node-v1,rust-v2}/vm.jsonl`,
  `nested_end` sequence 13: `write`, `ok:false`, ending in
  `sandbox_path_outside_workspace`. `records/sandbox.jsonl` retains the preceding
  successful `/tmp/work/result.txt` write and then the refused read of
  `<private-home>/.wasm-agent/changes/e3/e3b0c442...`.
- `q5`: the halt/no-replay revision preserves this failure and terminates the
  concurrent wave. Pi executed a real VM nested read first; its raw capture is
  163 events / 44,737,179 bytes, SHA256
  `f45451778ac39298d504b93a50f5f16380cf07bc0c382c12c02d6bb7aae9f6ff`.
  Its SDK's later "usage limit" message is a synthetic route shutdown/refusal,
  **not a live provider quota observation**.

Attempts q2–q5 were drained, losslessly sealed and archive-verified before exact
owned cleanup (12 resources each). `failed-archive-receipt.json` in each attempt
links its bundle and cleanup receipts. The journal addresses above are **sealed
record addresses** after cleanup; use `readSealedRecord(<attempt>/g, <address
without records/>)`, not a recursive scratch scan. q4 bundle SHA256:
`6b9d149962997ec849e8a354268657b55b200dc459f56721625794e0c89f01c4`;
q5: `acee7137f0747f1d1a20a4e8e6e5ba9c4ffc9fedad303a58fa81c30e5b2404f3`.
Failed early source provenance not retained in q2–q4 is explicitly unknown, not
reconstructed as a new successful qualification. q5 retains invocation pins.

The assignment explicitly forbids repairing the retained native write-adapter
issue or smuggling unrelated repairs into this change. Successful four-arm nested
read/write/bash qualification therefore cannot honestly be issued. A coordinator
scope decision is needed: authorize a narrowly scoped trusted changeset-artifact
adapter correction, or revise the qualification criterion. Disabling changesets,
ignoring the exception, substituting shell writes and calling them native write,
or replaying the affected task operation are not accepted workarounds here.

## Verification status

`node --test --test-reporter=tap scripts/test-agent-benchmark-forced.mjs`:
17 passed, 0 failed, 0 skipped. These are receipt/protocol mutation, zero-use,
cross-arm/scope, barrier/drain/failure and old-limit tests, not completed runtime
qualification. Actual attempts q2–q5 failed and remain failures. q1 failed before
generation creation (missing parent directory). No hidden acceptance, full release
gate, live provider, credential access, UI publication or deployment ran.
The full requested bypass/limit/SDK/native regression matrix and source-bound
successful qualification/postcheck are **unfinished**, not implicitly passed.
The new entries must not be used for a live wave from this checkpoint.
