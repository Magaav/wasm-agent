# Whole-response impact pagination

`graph impact` must budget ALL output, not only resolved impact rows. Previously
changed-symbol rows and twenty gap/unresolved-call records were fixed overhead;
a 12 KB request could refuse before even one caller fitted. This is presentation
cost, not proof of absence or permission to hide coverage gaps.

The repaired response pages four streams: resolved `impact.rows`,
`changed_symbols.rows`, `coverage.gaps`, and `coverage.unresolved_calls.rows`.
Each retains exact totals, returned counts, stream offsets and truncation.
The top-level `next_cursor` (also `impact.next_cursor` for existing clients) carries
all four offsets, bound to canonical root, patch, direction, depth and graph
generation. Follow it unchanged until absent. No section repeats, skips or loses
rows when the byte budget changes. A continuation can advance diagnostics after
resolved impacts are exhausted; inspect the top-level truncation, not impact
row count alone. Existing numeric-offset cursors are accepted for resolved-row
continuation; new cursors include all streams.

Rows are appended in round-robin order, starting with resolved impact, so useful
callers are not starved by metadata. The encoder measures the complete JSON after
cursor/count overhead. Identity, call provenance and gap details are not shortened.
An individually unpageable row or metadata frame refuses with minimum needed
bytes; no success cursor can loop without advancing. Counts and scope warnings
remain even when the corresponding row list is empty on a page.

This does not change code resolution, dynamic-call limits, audit policy, freshness
or test execution claims. Standalone audit retains its historical 20-row previews;
impact internally obtains complete diagnostics for lossless paging. Large patches
can cost more internal memory; transport bounds are not a whole-index memory cap.
Existing impact row shape and default depth/direction/budget remain unchanged.

Focused checks: Rust impact regression tests at 2/12/24 KB, full stream traversal,
no skipped/duplicated rows, Unicode identities, changed-budget continuation,
stale/mismatched cursor and too-large-single-row refusal; native host/workspace
regression checks exercise the Lua facade. These are not a full release gate.
