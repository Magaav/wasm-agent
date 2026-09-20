# Release status

**Windows developer candidate: built and verified as described below.**
**Live assisted alpha: GO for disposable/approved pilots; general customer release:
NO-GO.** The managed onboarding flow is publicly reachable and one disposable
Windows journey passed end to end. It provides pinned operator consent, model-free
guest execution, registry-controlled promotion, revocation and a background
PowerShell bootstrap. Ordinary `wa setup guest` remains offline.

## Live assisted-alpha evidence (alpha.10)

- Source: `e666bfa` (branch `change/independent-onboarding`; not merged to `main`).
- Public ZIP: `https://rendezvous.colmeio.com/releases/wasm-agent-0.1.0-alpha.10-windows-x64.zip`.
- SHA-256: `e9c43edff98d7d9fd67a4ebd0a64baaf1cc6d31ba7ca4e7af871360a256aa018`.
- Public descriptor and script: `/releases/windows-service.json` and
  `/releases/install.ps1` on `rendezvous.colmeio.com`.
- Live service: protocol 1, two pinned existing operator identities, systemd units
  using the deployment-gate-certified ARM binary. Installed record names source
  `e666bfa` and SHA-256 `01ca90df9b055c8319466e7db9ae443b9166e120360c1f1c1d6bf4f0f2dbec26`.
- Exact alpha.10 package: PASS 20 extracted personal-runtime checks and PASS 50
  isolated managed-network/bootstrap checks, both zero-skip where applicable.
- Public one-liner test: downloaded the hosted script, descriptor and ZIP into a
  fresh local install/home; background install completed; node name became
  `live-e2e-customer`; registration and relay attachment were verified; no model
  key was configured.
- Live operator effect: cloud operator `2b941f…` sent a signed write through the
  public relay; exact bytes `live-one-liner-proof-1789913200` appeared on the
  disposable Windows home. `wa disconnect` then revoked access; the same operator's
  next write returned `unknown_caller`, bytes stayed unchanged, and only the
  fixture's recorded PID was stopped before its directory was removed.

Still unverified: unfamiliar user on a clean VM, publisher/code signing, issued
single-use invitations, real operator-model task quality, diff/undo/recovery in
this assisted journey, and the broader conversation-isolation gate. These block a
general customer-ready claim.

## Managed onboarding follow-up

See [ONBOARDING.md](../ONBOARDING.md). Follow-up candidate:

- Version: `0.1.0-alpha.4`; source `3d088b7b26dc08330706bcb8440464e354f98223`.
- ZIP: `dist/wasm-agent-0.1.0-alpha.4-windows-x64.zip` (local, ignored, unpublished).
- SHA-256: `a567455a6fa2afd39a29c4382a2ce9cd72f8be4bbd428b4cc8ceae9b63217e54`.
- Inventory: **19 assets plus manifest**. The packaged guide documents managed
  connection, consent expiry, local audit, promotion and revocation.

Verification on the development Windows machine:

| Check | Result / boundary |
| --- | --- |
| Locked/offline package build | PASS; all three binaries built from clean source. Optional window icon still omitted without `windres`. |
| `test-managed-network.cjs <packaged-wa.exe> <alpha.4.zip>` | **PASS: 50 checks, zero skips.** Isolated registry, two administrators, two customer nodes, plus a freshly bootstrapped customer installation. |
| Paste-once UX | Typed name and CONNECT through redirected console input while installation runs in a background job; verified registration **and outbound relay attachment**, then a real signed file effect with no model. |
| Negative controls | Self-promotion, wrong target, unrelated admin/customer, role-body tampering, replay across recipient/registry restart, relay-route bypass/result theft, foreign Origin/Host, revoked/expired access and bad package checksum refused. |
| Owner control | Packaged disconnect/reconnect, operator promotion/demotion, local audit attribution, cancellation without enrollment; completed background install reported if retained. |
| Isolation from operator shell | Service command shim ignores inherited identity/key/provider/script overrides. Customer config contains no provider key. Persistent user PATH mutation deliberately not performed by this isolated test. |
| Existing first-run/integrity suites | PASS: 27 setup checks and 17 synthetic integrity/mutation checks. |
| Extracted alpha.4 personal runtime | PASS: 20 checks, synthetic local provider, actual native write, memory/session persistence, package integrity and launcher ownership. |
| Browser UI with packaged binary | PASS: structure, interrupted tools, real mid-run reload using repository fixtures. |
| Full smoke | Final serial run PASS: `smoke ok`, zero skips, including downgrade, concurrency and plugin gates. Earlier failures remain documented below; this is not a claim that every concurrency issue is solved. |
| Live deployment, public download, clean VM, real operator-model/customer journey | NOT RUN. |

The packaged check command was:

```powershell
node scripts/test-managed-network.cjs `
  dist/wasm-agent-0.1.0-alpha.4-windows-x64/wa.exe `
  dist/wasm-agent-0.1.0-alpha.4-windows-x64.zip
```

Logs: `pi-astra-package-alpha4.log`, `pi-astra-bootstrap-alpha4-final.log`,
`pi-astra-first-run-alpha4.log`, `pi-astra-tools-alpha4.log`,
`pi-astra-runtime-alpha4.log`, `pi-astra-ui-alpha4.log`,
`pi-astra-smoke-alpha4-final.log`, plus earlier failures
`pi-astra-smoke-alpha4.log`, `pi-astra-smoke-alpha4-serial.log` and standalone
`pi-astra-concurrency-alpha4.log` / `pi-astra-concurrency-alpha4-isolated.log` in the
session scratch directory. These checks use neither real provider credentials nor live
rendezvous enrollment. Alpha.2 below predates this protocol.

The current public service has not been upgraded to managed protocol 1. The
bootstrap refuses it. GitHub CLI on the cloud host is not authenticated; no public
release asset was uploaded. Neither condition is bypassed by the installer.

## Previous candidate (alpha.2)

- Version: `0.1.0-alpha.2` (local candidate, not a published Git tag).
- Source: `4ae9bae83bf7543b70557047e7395a1fa2e1d3a2`.
- Target: `x86_64-pc-windows-msvc`.
- Archive: `dist/wasm-agent-0.1.0-alpha.2-windows-x64.zip`.
- SHA-256: `fd952378aa0607fb8473c91caafccc4ba73e82c666509c37a258d8c714387097`.
- Inventory: 18 assets plus `manifest.json`; archive checksum alongside the ZIP.
- Build command: `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package-windows.ps1 -Version 0.1.0-alpha.2`.

The ZIP is local, ignored build output—not a file committed to GitHub. The branch
contains the sources to reproduce it. Timestamped archives are not claimed to be
bit-for-bit reproducible. Later builds need their own hash and evidence.

The initial offline build could not resolve the desktop shell's `tao` crate. Its
locked dependencies were explicitly fetched into the developer cache with
`cargo fetch --locked --manifest-path rust/wa-window/Cargo.toml --target
x86_64-pc-windows-msvc`. All three candidate builds then ran locked and offline.
The shell built with a warning that its optional embedded icon was omitted because
`windres` was unavailable. This does not assert clean-machine runtime compatibility.

## Delivered

- README and roadmap for personal agents **and** operator-assisted automation,
  with explicit customer consent, isolation, data flow and cost responsibilities.
- Independent candidate package and a fresh per-user installer, defaulting to
  `%LOCALAPPDATA%/wasm-agent-preview`. No private SSH, maintainer configuration,
  repo checkout, downloaded UI fragments or automatic service installation.
- Packaged `bin/wa.cmd setup`, `doctor` and `ui` commands; native `wa.exe` still
  handles agent commands. Masked API-key entry, restricted config-file DACL,
  atomic config replacement, and neutral runtime instructions.
- Setup preserves identity, memory, sessions, existing instructions and unrelated
  settings. It refuses unmanaged configuration, conflicting environment values,
  persisted provider-selection conflicts and recorded live servers.
- Provider validation is optional and explicit about the request/cost. Failure
  retains settings and gives a recovery instruction without echoing provider bodies.
- Local UI launch verifies PID/port ownership, supports browser or server-only
  operation and writes mutable launcher state outside the package. No window or
  live executable is stopped or replaced by the launcher.
- Guest setup stores an **offline** profile without requiring a model key. It is
  not enrollment, not authorization, and not permission to bypass the release gates.
- Browser test now waits for the asynchronous renderer/reload verdict and isolates
  both its browser profile and node home, not only its database.

## Previous verification (alpha.2)

Checks were run on the development Windows machine with isolated directories and
ports. This is not a fresh Windows VM or an unfamiliar-user study.

| Check | Result / boundary |
| --- | --- |
| `scripts/test-release-tools.ps1` | PASS: 17 synthetic integrity/mutation checks, including changed/missing/extra assets, invalid identity, traversal and ZIP round trip. |
| `scripts/test-first-run.ps1` | PASS: 27 isolated configuration checks; credentials/DACL, preservation, invalid input, environment conflicts, unmanaged/live configuration refusal and disconnected guest mode. |
| `scripts/test-release-package.ps1` on alpha.2 | PASS: all 18 assets match the manifest. Integrity is not publisher authentication or behavioral certification. |
| `scripts/test-release-runtime.ps1` on alpha.2 | PASS: 20 checks against extracted and freshly installed bytes outside the checkout, no Lua/script overrides, synthetic localhost provider. |
| Actual task effect | The packaged agent received a mock model tool call and wrote exact unpredictable bytes to a real file; the persisted run settled as answered. This proves integration, not real-model task quality. |
| Persistence | Remember/recall across separate processes; setup preserved node identity and existing memory. |
| Launcher | Server-only launch verified actual PID ownership, served installed UI assets from a path containing spaces, and reused its recorded process on a second launch. No native window was opened by this test. |
| Browser UI | PASS with the packaged binary: structure, interrupted tools and a real mid-run page reload, using the repository UI fixtures. |
| `bash scripts/test.sh`, final serial run | PASS: exit 0, `smoke ok`, zero skips, including the deploy downgrade gate. |
| Real model, unfamiliar user/clean VM | NOT RUN. |
| Customer enrollment, two-customer isolation, revocation | NOT IMPLEMENTED / NOT RUN. |

The exact runtime command was:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-release-runtime.ps1 `
  -ArchivePath dist/wasm-agent-0.1.0-alpha.2-windows-x64.zip `
  -ExpectedSha256 fd952378aa0607fb8473c91caafccc4ba73e82c666509c37a258d8c714387097
```

Retained local scratch logs: `pi-astra-package-alpha2.log`,
`pi-astra-runtime-alpha2.log`, `pi-astra-ui-alpha2.log`,
`pi-astra-smoke-alpha2-serial.log`, `pi-astra-first-run-alpha2.log` and
`pi-astra-tools-alpha2.log` in the session's temporary directory.

### Failures retained, not erased by retries

- Alpha.3's first bootstrap harness waited on a Windows stdout pipe inherited by
  the background node and timed out. File-backed harness output waits for the
  installer instead of the node lifetime. Alpha.4's final 50-check run uses actual
  redirected name/consent input and the packaged runtime; it passed.
- Alpha.4's initial full smoke failed after a passing wedge line; the old grep
  suppressed the later assertion. Once full output was retained, another run
  exposed an empty wedge health response / HTTP 000. Standalone reruns passed.
  The hermetic concurrency fixture now has its own home, clears inherited operator
  configuration, cleans only owned jobs and retains logs on failure. The final
  serial full smoke passed with zero skips. The precise cause of every earlier
  intermittent failure is **not established**; stream/conversation ownership still
  requires its independent release work.

- The first browser check dumped the DOM before the renderer/harness completed.
  It failed, was fixed with a bounded virtual-time wait and isolated profile, and
  then passed. The final browser run also uses a fresh node home.
- One smoke run concurrent with browser tests exited 1 in the concurrency portion
  after the wedge check. The parent script's grep obscured the sub-suite's failure
  text. A standalone concurrency run and a complete serial smoke rerun passed.
  Root cause is **not established**; logs `pi-astra-smoke-alpha2.log` and
  `pi-astra-concurrency-detail.log` retain that distinction. Do not call the suite
  proven stable under parallel load.
- Earlier dirty/behind-main runs skipped the downgrade test. The final serial run
  was clean and current and skipped nothing.

## Remaining release blockers

1. Legacy/operator HTTP authority/origin handling and cross-worker conversation/
   stream ownership. Managed guests now reject foreign Host/Origin and unapproved
   peer calls, but this does not certify the unrestricted operator UI or its workers.
2. Approve/deploy the managed registry and hardened operator environment; review the
   protocol independently before actual customers. The tested grant is explicit
   **full-user-account** control, not a task/workspace sandbox or a finished issued-
   invitation/customer-consent UI. Do not enable the descriptor against legacy nodes.
3. Clean Windows environment, runtime prerequisite verification, a real model-backed
   user journey, diff/undo/recovery acceptance and unfamiliar-user success.
4. Investigate the intermittent concurrency-test failure (also observed on the
   alpha.4 serial smoke run). The parent smoke script now retains the full sub-suite
   output instead of hiding later failures behind an earlier successful grep.
5. Publisher authenticity, public distribution and external update integration.
   The fresh installer intentionally refuses existing installations.

## Ownership and handoff

- Branch: `change/independent-onboarding`, worktree `pi-astra`.
- Implementer: Pi session `01a0be4c-3bf7-775b-a001-2cc1538701ac`.
- Main base: `f6361370c4e62530c2e9943602b9c8b2655a93f2`.
- Independent verifier: not assigned; no delegation claimed.
- The other worktrees' naming migration was not modified.

The human owns merges, publication and approval of a real-customer pilot. The
[release contract](RELEASE_CONTRACT.md) remains the go/no-go checklist, not an
assertion that all gates passed.
