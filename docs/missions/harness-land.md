# Mission change/harness-land — one landable branch from harness-fixes (2 rounds) + harness-fixes-rust

Base: change/harness-fixes (62c3c064 + round 2). Bring in change/harness-fixes-rust (3 commits on 62c3c064:
2d2c0e2d, e658eebf, 91bd2380) with `git cherry-pick`; both edited REPORT.md - merge the two reports into one
(sections per item 1-9 plus round 2), never drop content. Then:
1. Run every test either branch named (Lua rows, node .mjs, cargo -p wa-sentinel, -p wa-mesh-core, -p wa-mesh)
   and quote results; pre-existing failures named by stashed-base comparison.
2. Register scripts/test-runtime-binding-preflight.mjs with the harness (it is orphaned: fast.sh never runs it).
3. Run scripts/fast.sh once; classify every failure as introduced / pre-existing (with the base result).
Nothing new beyond integration and the orphan fix. Commit locally; never push.
