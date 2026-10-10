# Minimal chat readouts and commentary

Live run strip: `✦ 6s · ◈ ≥1.1M · ✧ 26 · ⚒ 82 · ◷ 2:24`. The growing glyph
and clock reuse the existing once-per-second ticker. Phase text stays in its
tooltip/debug history. Provider/tool totals retain their documented meanings.
`◈` is cumulative turn input + output, including cached input and summaries.
Each completed provider attempt updates the exact normalized reported total.
Pending or missing usage is a lower bound (`≥`), historical absent data is `?`.
No characters/4 or prepared-input estimate is mixed into the reported number.
Provider usage is not supplied for every streamed token; an exact live streaming
count cannot be inferred from text (hidden reasoning, tools and tokenizer differ).
The compact decimal formatter uses one fractional digit for k/M and promotes
rounded 1000k to1M. 1138787→1.1M, 1543336→1.5M; full exact integer appears in
the tooltip. Abbreviation changes precision of presentation, never accounting. No inference, tokenizer dependency, new
poll/timer or whole-ledger scan is added. Additive fields in existing version1
`run_counts` snapshots preserve exact known values at checkpoints/reload.

The footer trigger shows only `▤ 26%/1M`: occupancy of one task request versus
its own model capacity, not summed session spend. Two digits minimum; 100+
remains truthful, never clamped. One shared context-facts function feeds both
the footer and balloon: last provider-reported task input, same capacity/percentage,
exact raw integers and percent in the details. The capacity formatter is shared
and lossless (1050000→1.05M, 128000→0.128M), not the turn-total abbreviation.
Pending preparation/text estimates never overwrite the last measured prompt.
Summary requests never replace the task context with their smaller prompt/window.
Unknown/mismatched/foreign metadata remains `??`. Existing stream/metadata reads
update both at once; model/capacity/usage dependencies invalidate even without
cumulative spend changing, while unchanged balloon DOM/selection survives. Provider/model controls remain inside its balloon.
Resting trigger is transparent; hover/focus reveals its clickable surface.

All rounded noncircular components use `--radius:5px`; size aliases reference
it, including promoted shadow panels (no private radius fallback).
Square attachment previews retain filenames only as hover/accessibility metadata;
remove × is top right. Successful intake adds no run status/timer; refusal and
stale-read diagnostics remain. Circle icons/avatars and intentional square full-bleed regions are exceptions.
Visible Steer buttons are removed in main/child UI only; durable backend steering
and the existing keyboard path are not removed or redesigned.

Commentary with an explicit early item phase streams directly into an open
`wa-commentary`; header characters grow on each chunk. Native Responses preserves
its added-item phase. Pi omits it from text_start, so the bridge passively reads
only bounded added-item metadata before forwarding the original SSE bytes,
associating message phases in adapter message order. No Pi source is edited.
Unknown/oversized/malformed metadata remains provisional, never guessed from
stopReason or text. Completed signatures remain authoritative. Risk: a changed
adapter ordering requires revalidation; a 64KiB metadata frame cap can lose
presentation classification, never output/dispatch correctness.
Commentary stays outside automatic run folds. Manual closure survives resolution,
completion and same-thread checkpoint repaint; replay defaults open.

Transcript-read retry and known-active unfinished notices use independently
keyed entries in the shared `wa-chat-warning`, with existing liveness warnings.
It is pinned 5px below the chat header, outside transcript/run footer and without
moving the reader's position. Success/target switches clear only appropriate
causes. Original durable failures and explicit recovery controls remain retained.

Proof: `scripts/test-minimal-chat.cjs <fresh-evidence>` and `--post`, native Lua
run-count/wire fixtures and hermetic Pi bridge phase checks, then required
`scripts/test-ui.ps1`. Headless fixture proof is distinct from installation;
self-review, not an independent reviewer or full release gate.
