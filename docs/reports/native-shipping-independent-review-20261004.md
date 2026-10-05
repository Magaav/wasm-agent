# Independent exact-source review — NEEDS_CHANGE

Reviewer session child:native-shipping-review-20261004-v1; own branch change/wa-session-childnative-shipping-review-20261004-v1. Original clean HEAD a14f0b4fd2caa8ca8e95e86cae1faee80ac12475, tree 60e4693155f6a98488263755102e90896bb82e98; base 3f54a90d9d23b105df93002a683135d62cde81e0. Producer branch still points at the exact HEAD. No producer file/ref changed.

## Blocking finding: normal regression wiring

scripts/test.sh:216 invokes test-wave-ship.mjs, not the new test-ship-wave.mjs. Existing test-wave-ship tests ESM filenames only. check-deploy-shipped.mjs:190-200,241-245 enumerates whatever the shipper emitted and checks manifest coverage, not required consumer closure. Replacing ship-wave.mjs with exact baseline bytes in a disposable copy leaves BOTH existing checks passing: 5 checks and 96 checks (41 shipped files instead of patched 43). Thus the causal missing test-verdict/proof-verdict regression is not retained in the requested normal path. Standalone 14-check success is real but must not be described as normal gate coverage.

Bounded requested producer repair: wire the actual staged consumer/deletion controls into existing test-wave-ship or check-deploy-shipped (or make the existing path invoke the standalone suite), then show baseline mutation fails that normal path. No general parser rewrite requested. Reviewer did not change production code/tests.

## What is verified

Actual private staged wave-entry check allocate emits typed ok:true isolated_local_fixture; invalid repo returns typed ok:false/status 1. Exact baseline ships but admission fails missing test-verdict.cjs. Staged conditional proof loads; deletion of proof-verdict causes refused proof, deletion of test-verdict prevents admission. These are executed assertions, not filename claims.

Scanner inspected directly: require binding from createRequire named require, multiline call, .cjs/.js transitives/cycles, side-effect ESM imports, dynamic literal import and export-from close successfully. Ordinary strings/comments/templates and assignment-position regex prose do not cause missing ship failure. Missing exact literals and relative root escape refuse. Existing realpath confinement precedes copying. Symlink creation test SKIPPED EPERM on Windows; no executed symlink proof claimed.

Limits: unescaped exact filenames only; computed names, extension/directory resolution, template interpolation closure, arbitrary renamed require bindings and all-JS regex contexts are not generally supported. Alias createRequire bound to the identifier require works; arbitrary require alias is not recognized. Current gate-check uses precisely const require=createRequire(import.meta.url) and exact calls, so limits do not break current normal consumer. Scanner is not a general parser; regex recognition after => is not comprehensive because punctuation is tokenized singly. No observed current-consumer causal scanner bug warrants widening scope.

Read AGENTS, parallel-evolution, graph-audit procedure, OPERATIONS shipped proof contract, installer consumer paths and manifest check. deploy.sh invokes ship-wave with native path conversion; upgrade.sh swaps binary/UI/self/skills and does not substitute the wave shipper contract. Graph audit not used as correctness certification for this report-only delivery.

## Executed checks and raw evidence

Original raw logs: C:/Users/Victor/.wasm-agent/scratch/native-admission-repair-20261004-home/.wasm-agent/operations/ (each operation directory contains stdout and stderr).

- op-1791136106711911-8764-43: original clean status, exact SHA/tree, instructions and diff stat.
- op-1791136139678603-8764-61: test-ship-wave exit 0, 14 checks/0 skipped; test-wave-ship exit 0, 5/0; check-deploy-shipped exit 0, 98 checks,18 rules,43 files (built artifact note, not skip); test-producer-admission exit 0,0 skipped,no numeric count emitted, browser logs contract only. test-gate-check exit 1: isolation/browser assertions completed before missing current Windows HTTP candidate assertion. HTTP DID NOT RUN; no installed substitute or build. Fresh git fetch origin exit 0; merge-tree origin/main exact producer HEAD exit 0 yields 60e4693155f6a98488263755102e90896bb82e98. No merge/rebase changes exact source.
- op-1791136212607610-8764-73: independent probes exit 0,13 checks; symlink EPERM skip separately. Pure checkVerdict proof success/bad exit/dropped count/failure evidence/unsubstantiated skip refusal and JS success/bad exit executed. Baseline mutation normal paths both exit 0, demonstrating blocking gap. Probe script tracked beside this report for reproducibility. git diff --check exit 0. Producer ref unchanged.

Full/release gate not requested or run: gate_verified:false; release_verified:false. LOCAL ONLY, no push/fake upstream. Finish CLI check/verify may refuse unpublished branch and absent full gate; those are intentional policy limitations, not reasons to bypass guards. No main move, merge, deploy/restart, live installation write, provider replay, registration/claims modification or cleanup. Live installation remains missing libraries until authorized publisher/sentinel activation and actual native admission probe. Coordinator acceptance remains independent source/test verification, not this report's self-certification.
