# Normal shipping regression wiring repair

Continuation on change/wa-session-childnative-shipping-producer-20261004-v1, node 8b47de58bb47a330379aff5213d35fa9, session child:native-shipping-producer-20261004-v1.
Original producer a14f0b4fd2caa8ca8e95e86cae1faee80ac12475 / tree 60e4693155f6a98488263755102e90896bb82e98 retained. Independent review 405304bc6e16b0bede9604a40eeb518eb48d03c2 and its probe were read; reviewer branch unchanged. NEEDS_CHANGE identified that the normal test.sh:216 shipping entry did not reach the causal staged consumer suite.

Only test wiring/fixtures/report changed. Existing test-wave-ship now synchronously executes test-ship-wave, forwards raw output, asserts child success and the counted verdict before printing its own terminal success. No recursive invocation, test.sh hot-path edit or shipping implementation change. Normal aggregate verdict is 21 assertions (5 original, 14 consumer, 2 wrapper), zero skipped. Consumer deletion controls still run through this entry.

Baseline is now tracked at scripts/fixtures/ship-wave-baseline.mjs with its exact source SHA provenance comment. Bytes after that comment were compared to git show 3f54a90d9d23b105df93002a683135d62cde81e0:scripts/ship-wave.mjs and match exactly. Test execution no longer depends on Git history/clone access: it still requires successful private git init for normal admission, never silently skips it.

scripts/test-wave-ship-mutation.mjs copies scripts into an owned disposable directory without Git history. Patched NORMAL entry exits 0 with 21 checks. Replacing only its shipper with tracked baseline bytes makes that SAME normal entry exit 1 at normal staged allocate JSON success; the wrapper also fails its child-exit assertion and never prints wave shipping ok. The baseline itself still stages successfully and normal admission proves missing test-verdict.cjs, as preserved by the nested consumer test. No operator install/state touched.

## Actual checks

All commands explicitly cd to the managed producer checkout and assert pwd/branch.
Raw stdout/stderr: private candidate .wasm-agent/operations/op-1791138759324721-24376-31.

- node scripts/test-wave-ship.mjs: exit 0, 21 checks, 0 skipped; nested 14-check normal staged allocate/proof, library deletion and static closure controls passed.
- node scripts/test-ship-wave.mjs: exit 0, 14 checks, 0 skipped.
- node scripts/test-wave-ship-mutation.mjs: exit 0, 3 checks, 0 skipped; patched child exit 0, baseline child exit 1 causally expected.
- node scripts/check-deploy-shipped.mjs: exit 0, 98 checks, 18 installer rules, 43 emitted files. Existing built-plugin note, not a skip.
- node scripts/test-producer-admission.mjs: exit 0, 0 skipped; numeric check count not emitted, browser logs validate contract only.
- git diff --check: exit 0.

op-1791138784771501-24376-37 records baseline-byte comparison, missing Windows current-source candidate (false), fresh strict-host-key fetch/sync exit 0 and precommit merge-tree exit 0. HTTP gate-check portion was NOT rerun: required current Windows candidate remains absent. No installed substitute/build/full gate used.

Local repair commit only, no upstream fabrication or push. Final tip/tree/clean/current merge proof are reported in the completion packet and raw commit operation. Independent reviewer must recheck the new exact tip; this is not self-acceptance. No main move/merge/deploy/restart, live DB claims or installation writes. Live admission still unverified until sanctioned activation and actual native worker probe. gate_verified:false; release_verified:false.
