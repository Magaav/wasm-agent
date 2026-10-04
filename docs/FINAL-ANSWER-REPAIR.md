# Bounded independent-review repair

Reviewer exact 66296cf reproduced child wheel -> scrollTop 0 -> delta jumping to 4975. Original reviewer report/probe remains read-only in reviewer evidence; no failure erased.

Repair: child follow/pinning state is container-keyed; main retains its own follow/jump controls. Manual anchor release disables only that container's follow. Child native scroll returning to bottom restores that child's follow. Pin callbacks capture the selected container/state rather than borrowing main pinning. Shared rendering is unchanged.

Callsite review: handleEvent delta/pending, flushDecision, reasoning/tool append and replay pin all select current transcript; paintChildTranscript temporarily selects child then restores main. Main jump/send setFollow remain main-only. ResizeObserver is main-only and no longer modifies child follow. Evidence scroll-callers.txt records pin/setFollow sites. Child regression now checks actual pixel position after delta, reply and browser timer turn, plus unchanged main/sibling positions.

Normal coverage: scripts/test-ui.ps1 invokes test-final-answer-suite.mjs, which runs source-root wire9 + actual loop55 (0 skips), actual embedded Pi bridge against private fake package/AuthStorage/model exports, and captured production events in real shared browser renderer. Pi fixture tests late signature begin, commentary provisional resolution and mutable global stopReason not classifying text. No paid inference, credentials or installed package writes.

Normal-suite private child regression assertion mutation failed with final-answer focused suite failed; restored normal test-ui passes all four original stages plus focused suite. Raw logs, hashes, captured events, screenshot and mutation remain in owned Git metadata repair-evidence/. Screenshot inspected: Race heading/long evidence remain readable and composer stays visible. This image does not independently prove settled-collapse appearance.

Remaining review boundaries: exact-source independent re-review, complete Pi malformed/duplicate-stream adversarial cases and combined native backend lookup integration are not certified here. Early native phase timing remains conditional, Pi text_end late; no live provider timing claim. gate_verified:false; release_verified:false. No activation/deploy/main/push.
