# Re-verify fixtures (reviewer-authored)

Run from the reviewer's worktree. `$S` is a scratch dir outside every checkout; the live wave store
was only ever COPIED into it (sha256 of `waves.sqlite` unchanged: `f65b11dc…`).

```text
git archive 6a61338 scripts | tar -x -C $S/old          # the reviewed code, for "before" lines
cp -r <repo>/.git/wa-waves $S/h1/repo/.git/wa-waves     # copy; fixreg.mjs points registration.repo at the copy
node $S/fixreg.mjs $S/h1/repo/.git/wa-waves/registration.json C:/…/rwv2/h1/repo
node .review-scratch/r1-live.mjs  "$PWD" "$S/old" C:/…/rwv2/h1/repo          # 1: live lane, copy of the live store
node .review-scratch/r1b-matrix.mjs "$PWD" "$S/old" <live store> $S/m       # 1b: the full admission matrix
node .review-scratch/r34-claims.mjs                                          # 3+4: three-valued answer, claims, resolution
node .review-scratch/r4b-holder.mjs                                          # 4b: a real process; the steering_runs staleness
node .review-scratch/r567.mjs                                                # 5/6/7: migration, multi-row, transient index
node .review-scratch/r6b-fence.mjs C:/…/rwv2/old                             # 6b: the newest-complete fence, vs 6a61338
node .review-scratch/live-read.mjs <live store>                              # read-only live facts
git archive 6b30ca7 | tar -x -C $S/full && node .review-scratch/r-mutate.mjs "$S/full" "$S/mut" <repo>/rust/target/release/wa.exe
```

`r1b-matrix.mjs` and `r567.mjs` mutate **copies** only; `r1b-matrix.mjs` reverts and re-applies the
migration on a copy. `live-read.mjs` is read-only.
