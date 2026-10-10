# Minimal chat readouts and commentary

Live run strip: `✦ 6s · ◈ ~250k · ✧ 26 · ⚒ 82 · ◷ 2:24`.
Completed: `completed · ◈ 250k · ✧ 4 · ⚒ 3 · ◷ 0:45`. The growing glyph
and clock reuse the existing once-per-second ticker. Phase text stays in its
tooltip/debug history. Provider/tool totals retain their documented meanings.
`◈` is **net context added by the turn**, not billed provider usage or uncached
input. From a prior measured post-request boundary of600000 to a final measured
boundary850000 it shows250000→250k. Cached prompt rereads and intermediate full
requests are never summed. Original normalized provider/cache/billing totals stay
in harness accounting and the usage balloon, unchanged.

Additive `run_counts.context_growth` stores detached baseline/current/added,
model/source/known/partial/pending/complete/compaction markers. The baseline uses
one indexed last task-model end before the new user row; a genuinely empty session
starts0, prior unmeasured history/model switch staysunknown. Endpoints are provider
prompt+output (the measured post-request boundary including the final answer), not
a claim that encrypted replay/tool/image material uses identical tokenization.
Summary model billing never changes the task endpoint. Compaction can yield a
signed negative delta (net shrink), never a clamped success or cumulative spend.
Missing result/pending request shows`~` for incomplete observed boundaries;
missing/comparability/history shows`?`. No char/4 guess or cache-miss total fills it.
Historical billed-only snapshots stayunknown; no stored history is rewritten.
Compact decimal formatting is presentation only; exact integer and both endpoint
counts remain in tooltip. Terminal tokens precede✧/⚒/◷ in main and child footers. No inference, tokenizer dependency, new
poll/timer or whole-ledger scan is added. Additive fields in existing version1
`run_counts` snapshots preserve exact known values at checkpoints/reload.

Summary requests add one shared `wa-summary` topic inside the bubble: **Model is
summarizing**, with model details and elapsed seconds from the existing clock.
Provider-bound start/end snapshots survive reconnect/child replay; failure or
interruption never claims successful compaction. Completed summary evidence stays
in the run topic; summary request completion is not proof the summary was applied.

Queued steering is a shared `wa-steering` topic, dashed and kept immediately above
the bubble status as new output arrives. Exact receipt identity deduplicates it;
consumption changes it to **Steered** (entered context, not verified compliance).
The durable user row keeps its original text plus an additive steering trace,
rendered inside this turn rather than as a new bubble/turn boundary. Existing
session reads expose bounded unread inbox identities/state (not duplicated text);
accepted text remains in the durable inbox and later original user row. Small
child pages bound receipt metadata with explicit `steering_more` and a visible
notice pointing to the complete `steering_status`, never fail transcript delivery.
No new
polling loop or dispatch.
Deferred/unknown remains not placed. Original legacy rows are never rewritten.
`read_many` displays successful/failed counts and the first failed path, not a
generic `ok` when one range failed.

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
Resting trigger blends into the opaque composer; hover/focus reveals its clickable surface.

All rounded noncircular components use `--radius:5px`; size aliases reference
it, including promoted shadow panels (no private radius fallback).
Square attachment previews retain filenames only as hover/accessibility metadata;
remove × is top right. Successful intake adds no run status/timer; refusal and
stale-read diagnostics remain. Circle icons/avatars and intentional square full-bleed regions are exceptions.
Dedicated Steer and Cancel task buttons are removed in main/child chat; the shared
Send/Stop and dark button color are identical. Child panes use the full shared
status strip, topics, warnings and journal renderer, never a second raw preview/
running-duration row. See [SHARED-CHAT.md](SHARED-CHAT.md). Durable backend steering
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
