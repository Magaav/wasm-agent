# HANDOFF — stream C1: graph as a WASI component (branch change/graph-component)

Status 2026-11-05 ~19:25: WIP, not pushed, not deployed. Base: origin/main 0ac3c606.

## Design (shim, not direct)
Lua is untouched: the 14 `host.graph_*` capabilities stay, but `rust/wa-host/src/graph.rs` is now a
thin kernel shim that forwards each call to the `graph` component through `components::mcp`
(MCP over stdio, one run per call). Chosen because it has the smallest blast radius: no Lua, tool
schema or test changes, and `wa` drops `wa-graph` (tree-sitter + 7 grammars) completely.
- Component `rust/components/graph` (wasm32-wasip2, ~8.2 MB, needs wasi-sdk because tree-sitter and
  SQLite are C). Stateless per call: capture root → compare with committed manifest → index changes
  as revision committed+1 → read one snapshot. Tools: index query search source sources explain
  path caps stats overview impact patch_audit status.
- Mounts via a new `dirs` grant in `components.rs` (manifest declares guest paths):
  root read-only at `/graph/root`, db directory read-write at `/graph/db`.
- DB location: explicit `db` option used exactly (its parent dir is mounted); configured/derived
  dbs live in a private `P.d/graph.db` (so ~/.wasm-agent itself is never mounted). Old graph.db is
  ignored and rebuilt once.
- Kernel keeps scheduling only: per-(root,db) entry, in-process mutex + `<db>.lock` file lock
  (std `File::lock`, rustc 1.98 ok), one background worker that calls tool `index` on hints
  (`native_write`, `graph_notify`) and on `notify` OS events, status overlay (queued/active/
  dirty_hint/watch_registered). `serve` calls `graph::watch_configured()`.
- Host passes `_display_root`/`_display_db` so answers, byte budgets and impact cursors use host
  paths (wa-graph audit.rs reads `_display_root`). Absolute paths in `changes[]` are rewritten to
  `/graph/root/...` (`guest_changes`). `host_paths` maps any leftover guest path strings back.
- `components.rs` also got a disk compile cache (`~/.wasm-agent/cache/components/<sha>-<engine>.cwasm`,
  `WA_COMPONENT_CACHE=0` disables): without it every `wa` process recompiles the 8 MB component
  (seconds; graph tests took 10–30 s each).
- wa-graph: feature `native` (default) gates coordinator/watch/notify; `canonical()` replaces
  `canonicalize` (WASI std has none: lexical normalize + exists check).

## What compiles / passes (wasm_the_first)
- Component builds (commit f50fbd13 tree): 1m58s cold, graph.wasm 8,186,801 B.
- Host builds (commit 9a685181 + verbatim-prefix fix): cold 6m16s, wa.exe 29.0 MB vs 35.4 MB before.
- Lua tests on that build (before the last commit's fixes): PASS graph-tool, graph-automatic,
  graph-watch, graph-index-failure, patch-audit, patch-audit-agent, batch-tools.
  FAIL graph-freshness (expected exact explicit db file → fixed in last commit),
  graph-workspace (absolute changeset paths → fixed: guest_changes), impact-paging (budget grew
  from host overlay/paths → fixed: overlay only on full snapshots + _display_root).
- The LAST commit (exact db, display paths, changeset paths, compile cache, cjs env filter) is
  NOT built or tested yet. cargo tests (wa-graph, wa-host graph::tests, components::tests) not run.

## Remaining steps
1. Build component + host on the last commit; run tests (scripts below). Fix fallout.
2. Run cargo tests: `-p wa-graph`, `-p wa-host graph::tests`, `-p wa-host components::tests`.
3. Measure latency native vs component: `benchmarks/graph-component/bench.lua` (usage in header;
   native binary: C:/Users/Victor/wa-build/a2-host-target/release/wa.exe, same base 0ac3c606).
4. Docs: HOST.md and COMPONENTS.md done; add "C1 results" + mark `graph_*` done in the carve-out
   map in docs/KERNEL.md; mention the `dirs` grant and compile cache in docs/COMPONENTS.md.
5. Distribution: deploy.sh does NOT install components. After the new core deploys, a node without
   `graph.wasm` in ~/.wasm-agent/components answers `graph_component_unavailable:
   component_not_installed:graph`. Install the pinned component (wasm + .sha256 + .json) on
   openclaw, wasm_the_first and the work sandbox BEFORE deploying the core (nextcloud gets it with
   a release). Longer term: registry/OCI or deploy.sh step.
6. Rebase on origin/main (stream w3 touches components.rs and Cargo.toml/Cargo.lock: expect a
   conflict around `compiled()`/Grant and in Cargo.lock; regenerate the lock), check
   `git diff --stat origin/main` for unexpected deletions, ff push as Magaav from
   C:/Users/Victor/orca/projects/wasm-agent, then sentinel deploy and verify on openclaw
   (graph tools work, wa-whatsapp CONNECTED / health ready).

## Gotchas
- scripts/test.sh now builds the graph component (required, needs wasi-sdk) and exports
  WA_COMPONENTS_DIR (cygpath -w on Windows) for the whole run; the two graph .cjs harnesses
  keep WA_COMPONENTS_DIR through their env filter.
- Windows canonical roots are `\\?\C:\...`: `mountable()` strips it for the preopen.
- build-components.sh looks for output in `$crate/target`: do not set CARGO_TARGET_DIR for it.
- test-graph-repair.lua needs WA_REPAIR_ROOT (run via scripts/test-graph-repair.cjs only).
- WASI 0.3: a request tool needs nothing async; the stdin/stdout MCP run would become a typed
  `wa:mcp/server` export later.

## Commands (wasm_the_first, Git Bash)
    # component
    SDK=/c/Users/Victor/wasi-sdk-34.0-x86_64-windows
    cd /c/Users/Victor/wa-build/gc/rust/components/graph && CC_wasm32_wasip2=$SDK/bin/clang.exe \
      AR_wasm32_wasip2=$SDK/bin/llvm-ar.exe WASI_SYSROOT=$SDK/share/wasi-sysroot \
      CARGO_TARGET_DIR=/c/Users/Victor/wa-build/gc-guest-target cargo build --release --target wasm32-wasip2
    # (or: WASI_SDK=$SDK WA_COMPONENTS_DIR=<dir> bash scripts/build-components.sh graph)
    # host
    cd /c/Users/Victor/wa-build/gc/rust && WA_CODEMODE_ALLOW_EMPTY=1 \
      CARGO_TARGET_DIR=/c/Users/Victor/wa-build/gc-host-target cargo build --release -p wa-host
    # tests: /c/Users/Victor/wa-build/gc-test1.sh (installs the built component into gc-comp,
    # runs the graph Lua tests + impact-paging.cjs; CARGO_TESTS=1 adds the cargo tests)
    # scripts: gc-bg.sh (component), gc-host.sh (host), logs gc-guest.log / gc-host.log / gc-test1.log
