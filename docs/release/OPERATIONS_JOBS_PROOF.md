# Operations / jobs proof — 2026-09-20

**Candidate, not deployed.** Tested source: `85c077f` on
`change/operations-jobs`. The branch preserves the earlier independent-onboarding
work; it does not remove that authorization boundary to expose these APIs.
Terminology and limits: [operations](../OPERATIONS.md), [jobs](../JOBS.md),
[architecture](../../ARCHITECTURE.md), section 6.

## What was actually tested

| Gate | Windows | Linux |
| --- | --- | --- |
| Release-profile operation tests | 13 passed | 12 passed |
| Durable jobs tests | 9 passed | 9 passed |
| Sentinel contract tests | 2 passed | 2 passed |
| Independent HTTP observation/cancellation during a real tool call | 8 checks passed | 8 checks passed |
| Busy-listener recovery, graceful deferral, running-script cancellation | 6 checks passed | 5 checks passed |
| Real browser CDP + file/event delivery, deduplication, toggles, no ambiguous wake retry | 19 checks passed | 19 checks passed |
| `scripts/test.sh` full smoke, including native contracts and HTTP control probe | not run as a full Windows suite | passed; final verdict `smoke ok`, no skips |
| `scripts/test-ui.ps1` real headless browser | passed, including jobs position/toggles/safe rendering and mid-run reload | not run; this is the Windows visual gate |
| Desktop shell integration | `cargo check --offline` passed | not a Linux shell target |

The extra Windows operation test exercises native cmd/PowerShell quoting. The extra
Windows recovery check kills its own fixture host and proves that a descendant
cannot subsequently write a marker: closing the owning Job Object kills the tree.
There is **no equivalent owner-death claim for the POSIX process-group fallback**.

All model endpoints in the new integration tests were local fixtures. Real shell
processes, real node/sentinel binaries, real Chrome/Chromium pages, and real OS
termination were exercised. No paid inference, user's browser profile, external
recipient, or production server was used as a fixture.

### Reproduction commands

```sh
cargo build --release --offline --manifest-path rust/Cargo.toml
cargo build --release --offline --manifest-path rust/wa-sentinel/Cargo.toml
cargo test --release --offline --manifest-path rust/Cargo.toml -p wa-operation -p wa-jobs
cargo test --release --offline --manifest-path rust/wa-sentinel/Cargo.toml
node scripts/test-operation-control.cjs
node scripts/test-operation-recovery.cjs
node scripts/test-jobs.cjs
bash scripts/test.sh
```

On Windows, also run `scripts/test-ui.ps1` with scratch ports and `-WaExe` pointing
to the candidate using a **native Windows path**. Linux browser proof used
`CHROME_BIN=/snap/bin/chromium`, a scratch profile beneath the snap's permitted
common directory, and the already-installed `undici.WebSocket` for Node 18.

The Linux smoke invocation used a fresh HOME, explicit existing CARGO_HOME and
RUSTUP_HOME, and **unset WASM_AGENT_HOME**. The suite intentionally tests refusal of
on-disk Lua with a default home; setting WASM_AGENT_HOME outside the suite defeats
that fixture. The scratch clone had its own Git identity and `origin/main` ref.
Earlier attempts failed those fixture preconditions; they were not counted as passes.
An offline sentinel dependency mismatch was corrected by aligning its new bitflags
lock with the shared cached version. Missing WebSocket support initially failed the
Linux browser test; the existing Node 18 implementation was used, not a skipped test.

## Original failure shape, before and after

Same isolated Windows probe, one-second execution budget. These are individual
measurements, not throughput benchmarks or hard-real-time guarantees.

| Command shape | Installed `03f0617` | Candidate |
| --- | --- | --- |
| `printf visible` | 51.7 ms; correct success | 55.0 ms; correct success |
| `sleep 7 & printf visible; printf diagnostic >&2` | 4059 ms; lost output; false success | 119 ms; both outputs retained; failure; shell exit zero recorded separately |
| `sleep 7 & wait` | 5019 ms | 1033 ms; deadline failure and owned cleanup |

The correction is lifetime ownership, not a larger timer: no blocking pipe-reader
join; bounded incremental capture; one execution deadline and a shared, disclosed
cleanup budget; descendant ownership even after shell exit or pipe redirection.
The legacy synchronous shell interface remains; explicit operations provide
start receipts, cursor reads, bounded waits and cancellation without blocking the
run worker on the full external execution.

## Evidence locations

Windows final fixtures under `%TEMP%`:

* `wa-jobs-proof-ndI228`
* `wa-operation-control-1qzrOX`
* `wa-recovery-proof-2SFRCY`

Linux isolated clone/logs: `/tmp/wa-operations-proof-D1EnnN`:

* `smoke-verified.log` / `.exit`: exit 0.
* `integration-verified.log` / `.exit`: exit 0.
* Browser evidence:
  `/home/ubuntu/snap/chromium/common/wa-proof-YsTniT/wa-jobs-proof-fZltLs`.

Windows candidate SHA-256:

* `wa.exe`: `0c0e395d9c25c22576406b2c90e86443a170cd06308f5eb84b09338acd5b13b1`
* `wa-sentinel.exe`: `a87dce860c792e3d89da602242b889ce5de5245b154e132687f603bb396f7ec4`

The installed Windows node stayed unchanged:
`135639e94a9faf7c15917ae60fa7b1c45218723afff1946e6f98b6e34102fda7`.
No desktop window was restarted and no live service was replaced.

## What this does not prove

Not run: paid-model behavior suite, real messaging-account integration, production
deployment. A skill-backed wake proves delivery of the approved instruction, not
that an arbitrary model obeys it or that a business action is correct. Deterministic
procedures still need their own postconditions.

This is not universal cancellation for HTTP/browser/plugin/native code, a cgroup
sandbox, hard-real-time storage, a total-disk quota, or a lossless browser event bus.
A blocked filesystem observer consumes a bounded source slot; replacing a stuck
native thread safely needs an executor-process boundary. Existing interpreter-pool
saturation and legacy maintenance paths retain the limits documented in OPERATIONS.md.
Do not turn these measured improvements into a claim that arbitrary software can
never hang. The enforced contract is owned shell lifetime, truthful outcomes,
retained bounded evidence, independent control and explicit automation admission.
