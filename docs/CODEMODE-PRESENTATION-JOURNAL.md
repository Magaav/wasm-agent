# Native presentation implementation journal

Task branch: `change/wa-session-childcodemode-budgeted-reads-receipts-fix-20261016-1`.
Fresh initial sync: `476ccb75` → `fdc79bfc8bd78ab5e04ab3e925bb92a7dd8fffa5`.
Implementation commit: `99e2205d076f2279f824e895e9ad7c7f1f79ff17`, tree
`36e0e67c0ffbef4e183685e2912183ec9faf1f52`. Self-review, not independent review.
No changes to tools.lua, host.rs, graph, Cargo files, WhatsApp, UI or AGENTS.

## Design and bounded findings

The actual problem is a second JSON-string layer in `text(nativeResult)`, not a
missing read cache. `showCall({version:1,call:N})` refers to an already-admitted
native call, retaining exact typed bytes once in structured presentation. Selection
is opt-in; no metadata/receipt safety fields are declared unnecessary. Whole-item
packing measures the encoded outer tool-content JSON. Existing read_many cursors
remain the later-page path. Unread boundary items use exact existing original byte
ranges, not a competing cache, script rerun or changed-source refetch.

High-boundary output can still need artifact retrievals; retained originals do
not equal model awareness. Script success does not certify effects, complete batch
coverage or document EOF. The formatter route is deliberately explicit fresh
read → inspect → new exact edit; no whitespace repair/replay automation.

## Original evidence (local, private fixture data)

All paths below are relative to the owned worktree unless stated otherwise.
Failed generations are retained, never overwritten.

- Build receipt/raw Cargo and embedded checker logs:
  common Git metadata `worktrees/wa-worktree-childcodemode-budgeted-reads-receipts-fix-20261016-1/codemode-build-2VUxAS`.
  Pinned VM/prelude hashes unchanged. Built artifact SHA256
  `2b6c4ab7b1a3dbc2a94817e24a751e0018a4670d5f28d2200774a7c878e18177`.
  Retained copy: `rust/target/presentation-artifacts/99e2205-wa.exe`;
  committed source snapshot: `rust/target/presentation-artifacts/99e2205-source.tar`.
- `rust/target/presentation-proof2/receipt.json`: actual Rust backend source43 +
  restart1 and standalone embedded43 + restart1, Node ENOENT in both child PATHs.
  All four authored documents and consequential final caveat/receipt frames were
  checked; changed live sources did not alter cached continuation. Role/account/
  profile/workspace/corrupt-cache refusal, exact typed/null originals, native
  original retrieval, stale formatter refusal/fresh edit, earlier-success/later
  refusal or unknown/no replay passed. Later fixture additions cover nontext
  references and snapshot retention; rerun with the documented collector.
- Source tool-content JSON43,458 bytes; serialized tool-message fixture55,710
  bytes. Old text path54,264 bytes before projection, omitted view41,160 bytes,
  serialized tool-message65,941 bytes. Embedded paths differ slightly:
  new43,478 /55,730; old54,278 /41,158 /65,933. New has complete captured first
  page (3/4 docs) plus cached fourth-document continuation; old view is omitted.
  These are exact bounded mechanism fixtures, not complete provider requests,
  tokens, paid benchmark results, speed, quality or general default-promotion proof.
- `rust/target/presentation-default1/receipt.json`: source36 + embedded36 and
  expected old-source failure, all Node absent. Actual deterministic agent loop.
- `rust/target/presentation-native1/receipt.json`: source44 + restart2 passed;
  embedded failed the existing 1000-delivery assertion. `presentation-native2`
  then hit the existing collector90s timeout in source. Both failures retained;
  the broad suite is NOT reported passing.
- `rust/target/presentation-stress-control1/receipt.json` and original journals:
  private causal isolation on the same binary/current catalogue, exact original
  fdc79bfc codemode.lua vs candidate, unchanged30s deadline/fuel. Original timed
  out after716 reads; candidate completed1000. This reproduces deadline sensitivity
  without the patch; one sequential pair does not establish performance or prove
  all broad-suite failures unrelated. No runtime deadline or stress test weakened.
- `presentation-source1`: wrong older private binary failed DB setup;
  `presentation-source2`: too-small overflow fixture failed its assertion;
  `presentation-source3/4`: source passed, installed old embedded runtime refused
  the missing helper as expected. Raw logs/hashes remain. Early collectors retained
  source hashes rather than complete source-byte snapshots; this limitation is
  explicit. Final collector now retains tested binary and exact source copies.

## Evaluation

- harness: used. New source/embedded/restart collector and existing default proof
  helped verify real dispatch, typed originals and no Node. Existing stress collector
  exposed a90s outer limit despite a fixture allowing300s; its1000-call case also
  depends on the unchanged30s script deadline. These are observed limits, not a
  request to change runtime budgets. Snapshot copying was added to this task's
  dedicated collector; prior failed generations were not rewritten.
- graph: used (`impact`, inbound depth1,6000-byte view). Verified the owned root,
  but the result was truncated and had many unresolved/builtin calls and module-level
  gaps. It did not materially improve the implementation reasoning; direct source
  inspection and runtime proofs carried the review. Not a coverage certificate.
- code mode: used. Native `read_many` attempt1 retained exact original
  `54d5edd116e4980c6bb13787f8ed7e9a91fe9fa7e21053f753e3a61d5eaba368`
  (7984 bytes), and the two text items visibly demonstrated extra escaping while
  preserving receipts. Tools currently executing this session are installed old
  code, so the new helper was tested in private source/built embedded runtimes,
  not claimed installed in this session.

No live account reads, external agents, paid inference, installation, service
restart, UI publication or full release gate. `gate_verified:false`,
`release_verified:false`. Final delivery must report the final rebuilt artifact,
focused retained postchecks, integration/readback and any unresolved failures.
