# Reviewer-authored attack fixtures

Run from the reviewer's worktree (`C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch8077a6cf-…`),
which is also what `test-wave-public.mjs` needs for `path.resolve('.')`. `$S` below is a scratch dir
outside every checkout; the live wave store was only ever copied into it.

```text
# 1. live lane, copy of the live store, real activity source (needs the pre-change code too)
git archive 2f02b4c scripts | tar -x -C $S/old
cp -r <repo>/.git/wa-waves $S/wa-waves                 # read-only source
node .review-scratch/attack1.mjs  "$PWD" "$S/old" "$S/h1/repo"     # the copy placed at $S/h1/repo/.git/wa-waves
node .review-scratch/attack1b.mjs "$PWD" "$S/old" "$S/livecopy2/wa-waves" "$S/h2b"
# 2. make ON/OFF lie
node .review-scratch/attack2-lie.mjs
# 4. absent / broken / LYING third party (orca-lie.cjs is loaded via NODE_OPTIONS --require from the cwd)
node .review-scratch/attack4-liar.mjs
# 5/6. migration reversibility and the index removal
node .review-scratch/dump-store.mjs <store> <out.json> && node .review-scratch/diff-store.mjs a.json b.json
node .review-scratch/attack6.mjs  "$PWD" "$S/h6"
node .review-scratch/attack6b.mjs "$PWD" "$S/h6"
# 3. mutations (pristine = git archive HEAD | tar -x)
node .review-scratch/mutate.mjs  "$S/pristine" "$S/mut"  "$S/mutations.json"
node .review-scratch/mutate2.mjs "$S/full" "$S/mut2" <repo>/rust/target/release/wa.exe
```

These files were run from `.review-scratch/` during the review and are kept here as the evidence
artifacts; the paths in the invocations above are the ones that were used. `attack1b.mjs`,
`attack6.mjs` and `attack6b.mjs` edit **only copies** of a store; `attack1b.mjs` discloses the single
edit it makes to a copy (redirecting the copied row's manifest at a private fixture so the OFF branch
can be exercised). `indexcheck.mjs` was written at the scratch root and is included here unchanged.
