# Release status

**Verdict: NO-GO for public/customer release.** A packaging tool is not a passed
release contract. No release has been tagged/published; no live node or customer
has been installed, upgraded or enrolled by this work.

## Baseline and ownership

- Review baseline: `62912e56d3882f04f49536e441149231c666c2ac` on `origin/main`.
- Rebased onto `f6361370c4e62530c2e9943602b9c8b2655a93f2`; merge-tree check clean.
- Tested implementation: `102adeff9ed5370bceb9b276d1ef350abc672a52`.
- Change branch: `change/independent-onboarding`, in the `pi-astra` worktree.
- Implementer: Pi session `01a0be4c-3bf7-775b-a001-2cc1538701ac`.
- Owned surfaces: `README.md`, `ROADMAP.md`, `docs/release/`,
  `scripts/package-windows.ps1`, `scripts/test-release-package.ps1`,
  `scripts/test-release-tools.ps1`, `scripts/lib/release-package.ps1`.
- Other live work: naming migration in another worktree; not modified here.
- Independent verifier: **not assigned**. No delegation claimed.

## Delivered in this slice

- Personal + assisted automation product vision, with guest/customer onboarding
  as a first-class journey and operator tools/procedures as the reusable arsenal.
- Explicit separation of existing node roles from planned customer consent,
  grants, isolation, revocation and data/cost responsibilities.
- Removal of private-host provisioning commands from public quick-start guidance.
- Windows candidate builder: clean-source check, three locked offline Rust builds,
  allowlisted assets, source revision, hashes, manifest, ZIP and archive checksum.
  No installer, network enrollment, PATH change, service launch or deployment.
- An extracted-package integrity verifier and mutation tests. No executable code
  is run by the verifier; it does not certify a binary's behavior or publisher.
- A neutral candidate README; repository-maintainer instructions and user state
  are excluded from the package inventory.

## Evidence

| Check | Result / boundary |
| --- | --- |
| `powershell -NoProfile -File scripts/test-release-tools.ps1` | PASS: 17 synthetic integrity checks, including tampered/missing/extra files, bad manifest identity, traversal and ZIP round trip. Runtime/user journeys not tested. |
| Candidate builder on dirty source | PASS refusal: exit 1 with `dirty_source`, before any builds or output. |
| `bash scripts/test.sh` during implementation | Initial runs exited 0 with one skipped downgrade-gate check (dirty tree, then main drift). Superseded by the clean rebased run below. |
| `bash scripts/test.sh` at tested implementation | PASS: exit 0, `smoke ok`, zero skips; includes 21 deploy-downgrade checks. Log: `pi-astra-smoke-rebased.log` in the session's temporary directory. |
| Local links in rewritten documentation | PASS: 16 local links resolve. |
| Full candidate build | BLOCKED: host and sentinel compiled for Windows MSVC; desktop-shell build failed because `tao` is absent from the offline dependency cache. Exit 1, `build_failed: window`. No candidate/archive/checksum produced; temporary staging/build directories removed. |
| Extracted real runtime | NOT RUN: no complete candidate exists. |
| Clean unfamiliar Windows user / WebView2 / model task | NOT RUN. |
| Customer enrollment, two-customer isolation, revocation | NOT IMPLEMENTED / NOT RUN. |
| Live authority/concurrency concerns from baseline review | Read-only authority probes and source findings; not fixed by packaging. |

Candidate build command: `powershell -NoProfile -ExecutionPolicy Bypass -File
scripts/package-windows.ps1 -Version 0.1.0-alpha.1`, at pre-rebase source
`1132fa7c53b818f45438c2e7e3161f88742cbb5b`. Log: `pi-astra-package-build.log`
in the session's temporary directory. Packaging sources are unchanged by rebase.
The offline dependency rule was not bypassed; no network dependency download or
cloud-tree modification was attempted. A build environment with the locked
Windows shell dependencies must rerun the entire candidate build and verification.

Local command logs are scratch evidence, not distributable user transcripts.
There is no archive hash to report. Later evidence must name the new exact source
revision and archive hash; do not promote synthetic integrity checks to a claim
that a real packaged runtime has been tested.

## Next bounded changes

1. **Authority + isolation:** reproduce the reviewed HTTP fallback, cross-worker
   login state, conversation routing and global stream-sink risks in scratch
   instances; fix with negative tests. No live attack probes.
2. **Fresh installation + setup:** verify a real candidate outside the checkout,
   supply a safe first-install path, reuse existing config, separate display name
   from node/branch identity, and add thin read-only diagnostics. Existing installs
   must stay on the external upgrade path.
3. **Guest enrollment:** design the invitation/grant/revoke boundary and data flow,
   then prove one operator with two isolated customer environments. No onboarding
   button that simply sets `role=guest` and trusts the whole rendezvous.
4. **Independent verification:** run both supported journeys against exact packaged
   bytes; retain commands, assertions, failures, skips and interventions.

Only the human may approve publication and a real-customer pilot. See
[RELEASE_CONTRACT.md](RELEASE_CONTRACT.md) for the gate definitions.
