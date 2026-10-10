# One chat renderer, two hosts

Main, tiled subagent and promoted subagent chats use `wa-chat-shell` for composer,
attachments/5px radius/paste/file intake/Send-Stop/context balloon/warnings. Child
header and task routing differ; node/account menu is main-only. No child-only
Cancel task or Steer button. Stop is the same sole submit control; it cancels only
on an explicit click, never on a clock/read/refresh. Busy Enter preserves drafts
and report-only task-owner followups remain blocked until settlement.

`paintChildTranscript` binds a per-container renderer snapshot and uses the exact
main `repaintMessages`/`handleEvent`/run-status/markdown/topics/final-answer paths.
The pane's existing clock ticks this renderer through `chat-render-tick`, never a
separate raw `running 5:11` row or preview. Main globals/timers stay untouched.
Journal replay owns task/attempt/node/account identity; counts replace snapshots,
not sum repeated rows. Existing child poll reads authenticated durable rows plus
verified native event tail. No execution request, new wake, poll or inference.

Historical terminal rows settle normally; active tails retain same run bubble,
phase/cumulative tokens/provider/tool/time strip and exact shared context facts.
Unknown usage remains unknown. Repeating the same journal does not restart a
phase clock. Commentary manual closures survive checkpoint/tail reconstruction,
default open topics stay outside automatic run folds. Scroll/draft anchors stay
container-scoped. Preview text is never duplicated outside its actual phase topic.
A missing/unavailable journal uses the shared pinned warning and retained original
view, not guessed completion or raw preview masquerading as authoritative output.

No child-specific transcript/topic paint overrides. Orchestrator management button
selectors exclude all chat-shell descendants; shared Send/Stop uses the operator's
preferred old child dark `--panel-2` fill, text/border/radius/size once. Main/child
parity probes compare computed styles, not just matching class strings. Promoted
panes outside the orchestrator inherit the identical styles.

Risk: child input transports still differ: the child message API has no structured
picture part and visibly refuses pictures rather than dropping them. UI parity does
not invent backend sending authority. Main-only menus/model selection remain only
where their host owns them; child context/model balloon is read-only.

Verification: `test-shared-chat.cjs <fresh-evidence>` then `--post`, same-panel
main/child computed style/state/clock/topic/draft/Stop isolation, existing recovery,
reading, high-ID native event identity and UI suites. Live observation uses a
disposable browser with read-only task history/event requests or a screenshot,
never instruments/steers/reloads the operator's page or changes a child's execution.
Publication defers JS reload when *any* child pane or main chat is active,
not merely while the main composer owns a stream. CSS still swaps in place.
No node/window restart. Candidate browser
proof and exact installed served hashes are distinct; self-review, no release gate.
