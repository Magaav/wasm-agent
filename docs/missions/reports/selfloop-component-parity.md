# selfloop-component-parity - one field, on the wrong side of the seam

Branch `change/selfloop-component-parity` from `origin/main` `d452b20c`. One commit, built and run HERE on avell.
Nothing pushed.

The red: `scripts/test-selfloop-component.lua:115`, `PARITY: schedule a time wake differs`. Reproduced with
`scripts/test-selfloop-component.sh` (it builds `rust/components/selfloop` for wasm32-wasip2 and sets
`WA_SELFLOOP_COMPONENT_WASM`, which is what makes the component half run at all):

```
native:    {"inherited":false,"ok":true,"wake":{"attempts":0,...}}
component: {"ok":true,"wake":{"attempts":0,...}}
```

**The field is `inherited`.** The native `M.schedule` answered `inherited = <bool>`, the component's answer is the
contract's `wake` and nothing else, so the two disagreed on the key alone - every wake field matched.

## Which commit broke parity

NOT one of `ffb5153e, fe108a8c, 42507780, d452b20c`. The seam carried TWO keys the contract does not have, both
added on the LUA side before the last green:

| key | commit | path |
| --- | --- | --- |
| `replaced = true` | `82cbc693` (r6: one pending resume per session) | the pending-row replace answer |
| `inherited = <bool>` | `c90b129f` (r6b: only a pending resume is replaced) | the new-row answer |

Evidence: `git log -S inherited -- lua/core/selfloop.lua` names `c90b129f` and nothing later;
`git log d2fbd140..d452b20c -S inherited -- lua/core/selfloop.lua` is EMPTY, and both commits are ancestors of
`d2fbd140` (`git merge-base --is-ancestor`). The contract has no such field: `wit/selfloop/selfloop.wit`'s
`schedule` answer is the `wake` record, and the wit does not mention a resume at all.

## The brief's premise, re-measured

"The last green main-health was d2fbd140" is stale. `~/.wasm-agent/main-health/fast-d2fbd140934e.log` carries the
SAME failure on line 11 (`FAIL lua scripts/test-selfloop-component.lua (exit 1): ... component: {...`) and closes
with `fast result FAILED (469 checks, 3 failed)`. Ten earlier health runs carry it too. So this red is PRE-EXISTING
(it became visible when `scripts/fast.sh` began installing the component into the row's own home, so the parity
comparisons stopped skipping); it is not a regression from the landed stack, and it was listed among d452b20c's
four only because it is red there as well.

## The fix, on the right side

The COMPONENT carries the contract, and it cannot know these keys: the r6/r6b resume collapse is a Lua-side rule
over `self_wakes` rows (`resume_chain`, `created_at` inheritance) that the component's `schedule` does not implement
and the wit does not describe. So a key the component cannot produce is a defect in the NATIVE view, and the native
view drops them: `M.schedule` returns `{ ok = true, wake = view(...) }` on both of its resume-collapse paths.

No behaviour changed - both keys were written, never read: nothing in `lua/` reads `schedule(...).replaced` or
`.inherited`, and which row won is in the answer's own `wake.id` and in the ledger's superseded rows.

Two assertions in `scripts/test-selfloop-pause.lua` DID read `replaced`; they now assert the same facts from the
row instead of from a non-contract key (neither is loosened):

* `arming B REPLACES A` (line 565): `second.wake.id == first.wake.id`, on top of the assertions that already follow
  it (one row, A's id, the oldest `created_at`, the largest chain, pending with B's words);
* `a DISPATCHING row is not replaced` (line 526): the answered wake is a different id AND is `pending`, which is the
  fact the flag was standing in for.

## Rows

| row | before | after |
| --- | --- | --- |
| `scripts/test-selfloop-component.lua` (the real seam, component built) | RED: `PARITY: schedule a time wake differs`, native has `"inherited":false`, component has none | GREEN: `selfloop seam: 54 checks, 54 parity comparisons (ran), 0 skipped`, `selfloop seam ok` |
| `scripts/test-selfloop-pause.lua` | RED after the code change (it asserted the dropped flag) | GREEN: 200 checks |
| `scripts/test-selfloop.lua` (native) | - | GREEN: 119 checks |
| `test-selfloop-no-starve` 174, `test-deploy-pause` 116, `test-deploy-wait` 59, `test-deploy-resume` 25, `test-deploy-release-honest` 81, `test-resume-window` 41, `test-kept-message-one` 36 | - | all GREEN |

No new row was written: the parity row already discriminates this defect (red on `d452b20c`, green here), which is
what `/scripts/test-selfloop-component.sh` shows above.

## Named, not fixed (out of this round)

1. The r6/r6b resume collapse exists ONLY in `lua/core/selfloop.lua`: `rust/components/selfloop` has no
   `resume_chain` and the wit has no resume concept, so a `schedule` routed to the component would arm a second
   resume row where the native path replaces the first - the thing r6 was measured to prevent. Not reachable while
   the seam is off for `schedule`, and its own round when it is.
2. AN EXTRA KEY ON AN ANSWER IS A CLASS, NOT ONE BUG: the parity row only compares the calls it exercises, so a future
   extra key on another verb will fail it rather than be caught here. The rule this round leaves behind (a native
   answer is the contract's record and nothing else) is written in the comment at the trim.

## Texts to approve

None: no model- or operator-facing string is added or changed. The trim removes two fields from a Lua answer.

