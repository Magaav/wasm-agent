# Reverification: REFUSED / hold

Same reviewer session c50fecea, recorded branch unchanged, original review259707b4 preserved. Exact producer `b16085ae5b904f14a3752a1255519eb68aa959b5`, tree `a5b869e80435692c5c722ef87a1d56fd0b90693c`. Read-only producer never edited. Tested git-archive private snapshot under own review-private/candidate, candidate-built wa-host debug executable, explicit source Lua root supplied by normal runner. Jobs2/threads2. No implementation repairs.

## Actual checks

Build exit0. `node review-private/candidate/scripts/test-session-workspaces.cjs rust/target/debug/wa.exe` exit0, integration13/dispatcher31/release37, executes long-command fixture status0/floor10 in private home/database. Candidate real Windows junction succeeds; escaped source file absent and cleanup asserted. Prior binding/scratch assertions retained. Short command, durable stderr9000/truncation and descendant cancel/settlement exercised by long fixture. Fresh archive portable checker exit0 without original artifact. Rust wa-host operations filter:3 passed/78 filtered; NOT operation package40 tests. Full release gate not run.

`node scripts/reverify-safety-b16085a.cjs`: preflight disabled exit1 (named refusal); stderr zeroed exit1 (output bound); canonical bypass exit1 (real link refusal). Restored exact candidate exit0 integration13/release37. Raw output operation op-1790990464475967-9804-6714. Private safety-results.json retained. Original heredoc instrument rerun, private heredoc-results.json retained; no broader boundary matrix rederived.

`node scripts/reverify-b16085a.cjs`: exit0-with-nine checks fails normal runtime floor (exit1); missing invocation replaced with empty successful receipt fails runtime floor (exit1), static grep disabled for that attack. Neutered floor plus nine checks passes normal runner exit0 when static grep is disabled. Thus producer's neutered-floor red relies on source-string assertion, NOT independent runtime floor enforcement. Current floor does work; no claim that source grep proves actual execution. This is a limitation of mutation proof, not absence of current invocation.

Portable checker attacks: absent index, empty excerpt, missing reporter, missing E3, missing exclusion E57 and unmatched E120 each exit1. **Nonempty corrupt excerpt E1='fabricated report' passes exit0.** This violates requested corruption-must-red acceptance. Checker only validates truthiness/coverage, not excerpt integrity. Hold pending producer integrity evidence/check; reviewer does not implement repair.

## Portable inventory audit

All119 raw artifact rows parsed. ALL index excerpt strings independently exact-substring matched their addressed raw report and reporter session; mismatches=[] (not merely top cases). Groups aggregate dates such as 2026-09-30/29/28: these are group date labels, not per-entry exact dates; original per-report date precision reduced. E3 command/E8 scratch/E17 steering/E19 schema exact preserved raw fragments inspected. Index text read in full: no credentials or unrelated private WhatsApp conversation content observed; route complaints only. No transcript/memory dump committed. `collect-harness-reports.cjs` only requires checker, not a collector. Report inventory remains honestly report-only, U labels retained; underlying call verification is unfinished and is NOT demanded as119 confirmed defects. Original session report rows were not newly retrieved from ledger in this second half; raw preserved report artifact used instead. Do not mislabel that as original tool-call verification.

Portable-path blocker largely closed for current exact inventory: archive contains sanitized exact report fragments. Integrity protection remains confirmed blocker under this assignment's explicit corrupt-excerpt acceptance criterion. Do not return green with that blocker.

## Limits and record

Windows only: POSIX ln-s and nonWindows case-sensitive equality NOT run. Source now lowercases canonical equality only when platform.os()==windows; no observed new branch-binding bypass. No OS sandbox/TOCTOU claim. Failed mutation descendants contained by enclosing tool jobs; successful fixture explicitly cancels/awaits settled descendants. No cloud, live store/install/provider/jobs/index edits, push, deploy or restart.

Local durable review CLI can record unpublished tip, but refresh insists remote producer ref. Preserve old record before-snapshot; use separate local new-tip record rather than overwrite/delete old history or fake upstream. Coordinator live store not edited. Closing check current/merge proof can pass while unpublished readiness refuses; no full gate/admission claim.
