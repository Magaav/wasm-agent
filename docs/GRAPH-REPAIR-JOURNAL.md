# Graph staged/Go/provenance repair — 2026-10-16

Human-authorized repair, native task ownership; self-review, not independent review.
No nested/inference agents, paid probes, SDK installation, full release gate,
Sentinel, installation, restart or UI publication. WhatsApp/code-mode-owned files
were not edited; their landed tips were merged normally and the merged source
was rebuilt/rechecked. The original feedback remains in WHATSAPP-DELIVERY.md and
session `child:cloud-whatsapp-connector-20261016-2`, graph result seq457/message
`a5b52b60-9783-4ce5-a42a-55e925da8371` (104 staged files, zero lines/gaps).

## Root causes and delivery

* The old Lua collector trusted an exec preview. A private reconstruction of the
  **published** 476ccb75→fdc79bfc delivery produced 104 rename-aware changes
  (116 paths without rename detection), but a 24,576-byte tail of a 1,226,604-byte
  Git diff contained no usable headers and became `changes=[]`. Selected Git root
  and exec cwd matched. This diagnoses collection, not a root-binding failure in
  that reproduction; it is not a claim that the original mutable worker index
  was byte-identical to the later published commit.
* Net `diff HEAD` independently hides index edits cancelled by worktree edits.
  Complete retained output, NUL manifests and separate index/worktree/untracked
  records now preserve status, paths, additions/removals and source versions.
  Index identity is checked before/after capture without changing Git. Mapping
  uses stored graph snapshot bytes; mismatched index bytes and deleted source
  are gaps, not guessed offsets or anchors on unrelated remaining functions.
  Unsupported/large/binary/metadata/deleted/redirected paths keep facts/gaps.
  A fifth, cursor-bound `patch_facts` stream is losslessly paged.
* Go had no registered grammar. Official MIT tree-sitter-go0.23.4 is pinned in
  Cargo.lock with its archive checksum and retained upstream notice. Exact
  functions, receiver methods, types/interfaces/aliases and top-level var/const
  specifications are indexed; captured go.mod identity participates in freshness.
  Local package/import calls have explicit strategies; unknown selectors stay
  unresolved. A causal /v2-default-alias fixture caught an intermediate guessed
  local receiver edge; the guard and extractor stamp11 remove it, including from
  unchanged-byte v10 caches. No module-cache/type-checker lookup was introduced.
* Historical/evidence candidates lacked labels. Known repository-root prefixes
  now label domains, with a visible -400 discovery penalty unless history/evidence
  is requested. Active tests and business `src/archive`/test-history fixtures stay
  active. Caller-domain preference does not override explicit historical imports.
  Sole historical matches and exact path/version selectors remain available.
  Active already ranked first in the inspected old queries; no universal wrong-
  ranking claim is made.

## Source, binary and retained evidence

Owned worktree:
`C:/Users/Victor/.wasm-agent/wa-worktree-childgraph-staged-go-provenance-fix-20261016-1`.
Graph commits: cf287eba, 9449e393, d4478664. Fresh origin sync incorporated
code-mode e99788e6 and WhatsApp 9be5376e without conflicts. Tested merged code:
`209cff84d6ff378e8f3f51cc86cde56d9a24c538`, tree
`66ce612dc5b066f83935f8a933c072ee3e677170`.
This journal is a subsequent documentation-only commit; runtime-source postchecks
remain applicable, not a claim that the binary embeds the journal's later tree.

Candidate: `rust/target/release/wa.exe`, retained copy
`target/graph-merged-verified.exe`; SHA-256
`643cbdce576ff535a81e8a75fcab1708bd4ef0a7af954686fd705a2a96b51a0d`.
The documented non-installing codemode-build helper verified prepared asset/package/
notice hashes, a fresh snapshot, clean source and actual embedded VM readiness.
Build originals: own Git metadata `codemode-build-e4hDPB`, plus
`target/graph-merged-build.json` (SHA256
`37f129a6e801496fd102c18eb3be5b2f2ef6bf89513e03bd78e3200acdf1c043`).

Final native receipts (paths relative to owned worktree):

| evidence | SHA-256 |
|---|---|
| target/graph-repair-merged/receipt.json | 0542a9f77fc937fb11b2c55c711ad06c7904f4dbb352c7132b0b714720e97b41 |
| target/graph-workspace-merged/receipt.json | 2e2d1198a09380ae005756fdac6e2f2740d73f4362273d0a73ebed35e7820b1d |
| target/graph-paging-merged/receipt.json | a60e94140211ef9f965d9ec3bced938788ae14420ddb7e6b279f40fe51e11768 |
| target/graph-repair-baseline/negative-control.json | 45fea60fbd7268fdcdaef4789d29fa6fe8e57170753d6b8695ed266e6da6a359 |
| target/go-selector-negative/receipt.json | 6e1c419ca692e1dfe7e381a743131cc37926b5b53dd7859829d01fc9fef81529 |

Retrieval originals are in the authorized session-scratch directory, whose final
component is the hex encoding of this session id, subdirectory `r4`. Receipt SHA256:
`3d00805cc4c7b8d5d780a27fdd1677b11c3b3743c2855088a28302c44cb8f934`.
Receipts preserve source hashes, binary hashes and full stdout/stderr; --post passed.
Original staged-zero packet/full retained output, old Lua source and old executable
are in target/graph-repair-baseline. Baseline executable SHA256
`7d8ee69781fab213253b905206c354aec7f1963530c26fa6a64269358464a83c`;
its compiled commit is unknown. Full original diff SHA256
`09eca834639336c5804d377a2e9056e217c72f66b65f54a9dcc94efbda290c08`.
The intermediate /v2 control binary is retained as
`target/graph-before-unknown-selector.exe` (9c61f6a35f754d23e98946eb0766228496f8d54c98ed8801cc4629beda1fe4c5).
Its falsely resolved edge became explicit unresolved after an unchanged-byte
v10→v11 migration (committed revision1→2).

## Actual verification and limitations

* 56 wa-graph tests passed, none ignored; 4 focused host graph tests passed,
  110 other host tests deliberately filtered. Raw logs: graph-crate-v11.log and
  graph-host-v11.log under target. Graph source was unchanged by the later merge.
* Merged native retrieval: all14 source/embedded runs passed, including automatic
  native writes, OS events, freshness, intentional index failure, projection and
  session-view regressions. Root/workspace proof:37 checks. Paging proof:202 checks.
* Merged repair proof:275 source checks (including pagination-loop assertions),
  69 embedded checks, no skips. Private linked/nested roots, staged-only,
  unstaged-only, mixed/shifted/cancelled index edits, rename/delete/binary/untracked,
  unsupported paths, Go exact Unicode/hash/version fences and historical retrieval
  were exercised. The published104 replay retained104 facts, 13,161 stage-specific
  changed-line counts, 443 explicit gaps and199 pages at6KB. These are **partial
  static coverage** facts, not net/unique lines, executed application tests or risk.
* Self-review corrected a stray range-edit `end`, initial globally widened Lua
  var/const mapping regressions, and a private-test-helper visibility compile error.
  All failed logs are retained. An initial parallel run hit an existing coordinator
  wait timeout while a build ran; load contribution is an untested hypothesis.
* First plain candidate lacked embedded code-mode assets and retrieval refused
  visibly. No fallback/disabled-code-mode test was substituted: the supported
  helper and complete embedded proof subsequently passed. That plain binary's
  hash a800daab21849fc8840809de2b262c1d5eeb2467dcf0cb6d3e8c7ff4c8326e09
  remains in raw receipts; its physical bytes were overwritten by the supported
  build and were not retained. Baseline/intermediate/final binaries above are kept.
* An early proof correctly refused source changes made during its run; its CLI
  passes are not certified delivery. Fresh immutable generations passed later.
* Retrieval evidence under target suppressed OS hints through the existing
  absolute-component ignore filter. It was moved to permitted session scratch,
  not repaired by a query or weakened assertion. A long scratch run's ping wrapper
  failed before its wait; the assertion did not retain the underlying JSON cause.
  A short fresh scratch basename passed. A Windows path-length cause is hypothesis,
  not established diagnosis. Ancestor-name watcher filtering remains a limitation;
  content admission still reconciles missed hints.
* Dynamic/interface/receiver/method-expression/generic/external calls, default Go
  import aliases not inferable from captured local evidence, workspace/replace
  semantics, deleted/old rename source and non-indexed paths remain incomplete.
  Go local-name scanning can over-report shadowing. Domain labels are path heuristics,
  not deployment identity. Legacy non-Go name/alias resolution remains approximate.
  Non-UTF-8 Git output and configured capture limits refuse, never certify clean.

## evaluation:

* harness: **used**. Private real104 negative control exposed the exact tail-loss
  cause; source/binary/hash postchecks caught mutating-source proof and missing
  assets. Focused fixtures caught the /v2 selector guess and migration. Friction
  and failed generations are disclosed above. Improvement idea (opinion): refuse
  watcher proofs under excluded ancestor directories up front and retain the full
  failed wait-command packet, rather than only an assertion label. No benchmark,
  timing/quality/billing advantage is claimed; no full gate was run.
* graph: **used**. `search_symbols(git_changes)` found the active Lua collector
  and its undifferentiated review duplicate, helping identify the seam and confirm
  live-first ranking in that query. Source and private Git packets, not static
  relationships, proved the defect. Static/dynamic uncertainty remains explicit.
* code mode: **used**, native rust-wasmtime-quickjs-wasi. Awaited reads/serial edits
  retained exact originals and edit receipts; an ambiguous edit_many preflight
  applied nothing. The first multi-document JSON-text output clipped its view;
  originals were hash-addressed and relevant ranges were inspected separately.
  Range echo exposed the stray end. Improvement idea (opinion): inspect compact
  structured receipts and emit bounded selected content, not escaped whole JSON.
  No code-mode/helper source was repaired or recursive feedback chain started.

Routine delivery: gate_verified:false, release_verified:false. Integration and
remote readback are reported separately by the task owner; publication is the
coordinator's action, not performed by this task.
