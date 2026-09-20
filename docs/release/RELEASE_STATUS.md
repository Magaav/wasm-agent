# Release status

**Windows developer candidate: built and verified as described below.**
**Public/customer release: NO-GO.** Packaging and first-run delivery are complete
for this slice; customer authorization and isolation are not. Guest setup is
explicitly disconnected and cannot launch a network service through the packaged
UI command. No release was published, no live installation was upgraded, and no
customer was enrolled.

## Candidate

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

## Verification

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

1. HTTP authority/origin handling and cross-worker conversation/stream ownership.
   Baseline review findings were not fixed by this packaging work.
2. Genuine customer enrollment: verified operator identity, consent, scoped grants,
   customer isolation and effective revocation. An offline guest profile is not
   an invitation implementation. Do not onboard customers by editing around it.
3. Clean Windows environment, runtime prerequisite verification, a real model-backed
   user journey, diff/undo/recovery acceptance and unfamiliar-user success.
4. Review the intermittent concurrency-test failure and preserve full failure output.
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
