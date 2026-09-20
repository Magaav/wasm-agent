# Release status

**Verdict: NO-GO for public/customer release.** A packaging tool is not a passed
release contract. No release has been tagged/published; no live node or customer
has been installed, upgraded or enrolled by this work.

## Baseline and ownership

- Review baseline: `62912e56d3882f04f49536e441149231c666c2ac` on `origin/main`.
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
| `bash scripts/test.sh` during implementation | Exit 0, `smoke ok (1 skipped)`; downgrade-gate check skipped because the source tree was dirty. Not a zero-skip verdict. |
| Full candidate build / extracted runtime | Pending clean-source build attempt; no candidate hash yet. |
| Clean unfamiliar Windows user / WebView2 / model task | NOT RUN. |
| Customer enrollment, two-customer isolation, revocation | NOT IMPLEMENTED / NOT RUN. |
| Live authority/concurrency concerns from baseline review | Read-only authority probes and source findings; not fixed by packaging. |

Local command logs are scratch evidence, not distributable user transcripts. A
final verification update must name the exact candidate source and archive hash,
or the precise build blocker; do not replace a pending gate with a success claim.

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
