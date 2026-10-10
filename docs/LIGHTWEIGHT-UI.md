# Lightweight, responsive UI

Idle should not mean continuously drawing or rereading history. This is local
resource work, not token/context reduction or a transcript-retention policy.

## Rendering and interaction

The resting avatar is static; hover/press uses a short transform transition.
The panel uses opaque tonal depth instead of full-viewport backdrop blur. Controls
retain the existing spacing, contrast, keyboard/focus and popover contracts, with
brief color transitions only during interaction. Reduced-motion users get no
spatial/decorative animation; the explicitly requested 10px live-status indicator
uses a gentle 2.5s opacity pulse (.65–1) instead of rotation. This narrow functional
exception is removed at settlement; it is not an idle decoration or a flash.
Hidden/compact surfaces pause status animation and decorative clocks;
stream data and durable state are never paused or discarded.

Long transcripts (60+ rows) use browser-native `content-visibility:auto` only after
ResizeObserver has measured each bubble; intrinsic height uses that measurement. This suppresses off-screen layout and paint,
not stored history or DOM. Find-in-page, copy, selection and accessibility keep the
original text. Short transcripts and the newest/live bubble are exempt so streaming
and synchronous recovery remain observable. Risk: expanded content can change
measured height as a reader scrolls; scroll-anchor, large-history and search tests
must cover it. This
is render virtualization, not a claim of bounded DOM memory or deferred markdown
construction. Unsupported browsers retain ordinary rendering.

## Targeted status work

Clocks change only elapsed text when the displayed second changes. Status metadata
compares each view's dependencies; unchanged replies do not replace options,
diagnostic disclosure state or the text being selected. Live SSE, local settings
acknowledgements and run settlement drive immediate changes. Same-origin windows
send invalidation-only BroadcastChannel messages, never credentials or settings.
Failure/unavailability falls back to authoritative reads, not optimistic state.

Model metadata fallback is 5s during a run/open status panel, 30s visible idle,
and 60s hidden. Health follows at 1s during observed work, 5s visible idle, 15s
hidden, with immediate reconciliation when visible/focused again. UI version and
shell heartbeat remain bounded (3s visible, 5s hidden) for reload/error recovery.
Existing request deadlines, single-flight, epochs, lower-revision refusals and
exponential failure backoff remain. Risk: background activity begun elsewhere can
be discovered at the fallback interval; this is not a global push subscription.
Opening controls, returning to the window and own stream changes remain immediate.

## Exact telemetry, no repeated payload scans

`telemetry.snapshot` retains a per-interpreter, eight-session LRU accumulator.
A covering-index count/min/max and mutation revision are checked on every read.
Only new payloads are fetched. SQL update/delete triggers invalidate repairs;
imports below the cursor invalidate through count mismatch. Public snapshots are
detached, context/summary coverage and dropped-write counts refresh each call.
Exact totals, unmatched spans, latest ten errors and percentile samples remain;
missing usage/pricing/transport-attempt cost is never turned into zero.

No ledger pruning, approximate percentiles or elapsed-time freshness shortcut.
Restart/reader retirement rebuilds once. Risk: the accumulator keeps exact duration
samples and distinct tool/span identities in memory; LRU bounds sessions, not the
size of one session. Storage inventory counts are separately sampled at most once
per minute and return `stats_sampled_at`; they are not live usage accounting.

## Verification

- `scripts/test-telemetry-incremental.lua`: actual private SQLite, 2,000 events,
  unchanged payload-read count, append/repair/delete/restart/session isolation,
  detached reports, LRU rebuild/import handling, context index/bytes and explicit
  read/malformed-evidence failures.
- `scripts/test-observability.lua`, `test-efficiency-report.lua`, model-route tests.
- `scripts/test-ui.ps1`: full real-Chromium UI contracts, including recovery.
- `scripts/test-lightweight-browser.cjs <evidence>`: two real pages, cross-window
  invalidation, measured long-history containment, search/selection, stable reading
  anchor, reduced-motion and visibility return; never the operator's browser.
- `scripts/probe-lightweight-ui.js` through `agent-benchmark-ui-observe.mjs`:
  no blur/perpetual avatar motion, unchanged DOM identity, idle reconciliation,
  synchronous stream, render containment and retained evidence; screenshot retained.

The interactive-only two-window regression uses the actual node and two real
Chromium contexts: reload/stream failure, draft preservation, exact one tool effect,
settings conflict and immutable in-flight/next-run settings. Its native-child
journal-host phase is explicitly skipped: the broader fixture currently receives
`unknown_session` for a native child in the HTTP transcript route. This unrelated
native recovery boundary is not claimed fixed by lightweight UI work.

Physical disk, process I/O, GPU engine utilization, GPU temperature and CPU busy
percent are distinct metrics. Measure after actual installation, and never call
one small fixture a universal power/fan-temperature guarantee.
