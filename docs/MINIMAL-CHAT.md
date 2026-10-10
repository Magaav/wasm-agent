# Minimal chat readouts and commentary

Live run strip: `✦ 6s|◈ ~13000|✧ 26|⚒ 82|◷ 2:24`. The growing glyph
and clock reuse the existing once-per-second ticker. Phase text stays in its
tooltip/debug history. Provider/tool totals retain their documented meanings.
`◈` is cumulative turn input + output, including cached input and summaries.
Each completed provider attempt replaces the live estimate with normalized
reported usage; missing usage is unknown (`≥`), historical absent data is `?`.
During streaming `~` adds the prepared request input estimate plus visible
text/argument characters divided by four;
this is not a tokenizer or provider billing measurement. Hidden reasoning and
lost internal transport usage cannot be measured live. Integer token readout
keeps increments visible even at millions; it is never rounded into a static `M`.
Totals may correct
downward when the provider reports. No inference, tokenizer dependency, new
poll/timer or whole-ledger scan is added. Additive fields in existing version1
`run_counts` snapshots preserve exact known values at checkpoints/reload.

The footer trigger shows only `▤ 26%/1M`: occupancy of one task request versus
its own model capacity, not summed session spend. Two digits minimum; 100+
remains truthful, never clamped. Request preparation provides an estimate,
streamed output a marked tail estimate, and completed usage its measured prompt.
Summary requests never replace the task context with their smaller prompt/window.
Unknown/mismatched metadata remains `??`. Existing stream/metadata reads update
it, including children. Provider/model controls remain inside its balloon.
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
