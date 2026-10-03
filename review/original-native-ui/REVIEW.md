# Independent review of original native UI delivery

Verdict: **request changes** on exact producer `18bc6bf05be9cdbd01a1e50a6a520e0e9e9a499b`, tree `8bd76bc322d2aebed1ffa4045f4945ea144ab9de`. This is a completed independent source review, not delivery admission, a full application gate, or source acceptance. No product files were changed. The immutable producer was merged into this allocated review branch with both parents retained; original `98e14c5` remains an ancestor. The replacement `b395de2` and old `16310ad` have identical trees and parents, as the producer's history explanation claims.

## Findings

**P2 — durable terminal fallback fails on an existing native view.** At `ui/app.js:4833`, `syncNativeSession` catches journal failure, displays an error and returns true, so `watchTurn` never reaches its ordinary ledger follow. At `ui/app.js:4908`, a previously attached pane returns on journal failure even though `paneMessages` has already fetched newer complete terminal rows. The independent real-node/browser probe held the native provider, attached the pane, froze only the observer's polling, allowed the child to complete, and preserved its journal under another private evidence name. The durable task was completed, but the main chat and retained pane omitted `NATIVE-B-COMPLETE`; a fresh pane reading the same session displayed it. The error is visible, but the available terminal answer is suppressed indefinitely while the journal remains unavailable. Reload/new mount restores it.

Removing only that pane return in a disposable UI copy changes the retained-pane result to true while main fallback remains false. This establishes causality; it is not a proposed repair, because removing the return alone could discard unsaved live evidence. See `adversarial.receipt.json` → `review.fallback` and `fallback-causality.json`. The producer's unavailable-journal assertion covers a fresh mount and therefore misses this failure.

**P3 — malformed native cursors silently reset.** `lua/core/subagents.lua:760` uses `tonumber(args.after) or 0`. Actual authenticated requests with `after:"garbage"`, `{}`, or `true` returned `ok:true` and the first cursor page instead of a validation error. Negative, fractional and unsafe numeric strings were refused. Ownership remains enforced: a forged body owner and an invalid bearer credential did not grant evidence. See `adversarial.receipt.json` → `review.cursor`.

## Independent evidence

The private source-bound build produced SHA-256 `cd2b3f43c73d013dfa407e8f2b7246b316a6346ea426c5b45950b972519c50c6`; `build.json` records the command, actual binary and source hashes. Its source binding was rechecked after the mutation runs, and `git diff 18bc6bf -- ui lua rust scripts` was empty.

| Check | Actual result |
| --- | --- |
| `scripts/test-ui.ps1`, explicit binary, dynamic ports, containing Job | All original assertions and four stages passed |
| Native child browser, explicit source Lua root | 76 passed, 0 skipped |
| Native child browser, embedded candidate Lua | 76 passed, 0 skipped |
| Review adversarial native extension | 78 passed assertions; separately records the two defects above |
| Selected `subagents::` Rust tests | 20 passed, 0 failed, 63 filtered |
| Selected `serve::journal::` Rust tests | 2 passed, 0 failed, 81 filtered |
| Actual high decimal run ID HTTP/restart/owner fixture | 36 passed, 0 skipped |
| Run ID JavaScript helper contract | 10 passed, 0 skipped; helper only |
| Original two-window recovery | First attempt failed at native-pane attachment with `read_capacity_busy`; rerun passed 22, 0 skipped |
| Independent main epoch, credential and node fence removals | Each failed its specific existing real-browser assertion |
| Pane terminal-fallback return removed in staged copy | Terminal answer appears on retained pane; main defect persists |

The source/embedded runs exercised genuine opaque native attempts, real owner/node/session/epoch rejection, checkpoint-before-tail attachment, 300 raw deltas across indexed pages, retained typed reasoning/commentary/tool/result/answer events, huge UTF-8 byte/version retrieval, real reload/offline reconnect, native node restart without inference replay, induced journal write loss settling failed with a durable error, and terminal ledger fallback on a fresh pane. The direct UI harness retained its original decision/phase, inspector, profile, reuse, parent buffer and shell/control assertions. Screenshot `wa-native-browser-i1Nstv/six-panes.png` was visually inspected: six panes at 1200×800 remain contained, with measured headers ≤44 and matching action/attachment controls. Growth tests preserved the actual raw-event segment anchor, reasoning inner scroll, folds and draft.

All five producer mutation receipts were read together with their actual raw assertion failures: tail-page-only, six-pane overflow, parent reasoning buffer loss, native owner bypass, and checkpoint replay. `producer-mutations-inspected.json` adds raw log hashes. These are inspected producer evidence, distinct from the three independently rerun staged identity mutants in `guard-mutations.json`.

## Limits and disposition

All fixture processes used private homes, DBs, repositories, ports, profiles and mock endpoints. Native and recovery receipts prove suspended creation, queried Job flags 8192, no breakaway, assignment, `IsProcessInJob`, actual exit and active-process count zero; fixture homes were removed after evidence export. Direct UI and high-ID HTTP were also contained by their own queried Jobs. This is process cleanup evidence, not an administrator-proof sandbox. No production node, window, account/provider configuration or paid inference was used.

The restart assertion compares the first 256 archived events and recovers the full terminal answer after restart; it does not compare every archived event throughout restart or simulate power loss. FULL SQLite commits and the global native task mutex may serialize writers; retained events and fully materialized history grow storage/memory without pruning. No throughput measurement or new performance default is endorsed.

The initial recovery overload is recorded, not hidden behind its successful rerun. Later background completion/read-control 503 and failed-task continuation work remains Root-owned and was not implemented. Source acceptance, current admission-required proof, the combined full gate, main integration and deployment remain with the sole acceptance/merge lane `ctx_50a3da02dcf1`. Findings were sent to Root and that lane. `report.json` carries machine-readable evidence, provenance and the current-origin merge proof; the review branch contains only review artifacts beyond the preserved producer source.
