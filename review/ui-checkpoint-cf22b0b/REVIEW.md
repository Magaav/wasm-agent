# Independent review: refused as a complete delivery

Reviewer: child:dispatch:366a7144-3381-43ea-b7dd-d5ad7ac3adbd (not producer).
Producer tip cf22b0be2f3e432abb5ee14b6e73496f261c3df7, tree 05ea236f9fb6aeb283d794fded573245f2f39384. Own managed branch change/wa-session-childdispatch366a7144-3381-43ea-b7dd-d5ad7ac3adbd, base 898a9a238c89c5f64b83cfa219f8c17840b441f9.

## Method and observed passes

Archived exact tip into review-snapshot within own worktree. No producer/canonical/installed UI edits. Read AGENTS.md, DESIGN.md, SESSION-FIRST.md, FABRIC.md and relevant Rust runtime/route implementation. Focused commands executed from snapshot, private headless profiles/servers only:
- node scripts/gate-check.mjs run ui-browser: exit 0. Actual reload/startup-recovery/inspect/view stages validated by DOM results before final marker (test-ui.ps1 lines 3410–3465), not just a hardcoded unguarded sentence. Held stream delta after alive/foreign POST /chat watchdog poll is exercised in lines 3253–3279.
- node scripts/test-gate-check.mjs: exit 0, 0 skipped.
- node scripts/test-producer-admission.mjs: exit 0, 19 checks, 0 skipped; synthetic admission proof, not browser execution.
- powershell scripts/probe-ui-subagent-chat.ps1: exit 0, 26 checks. Headers 41px, controls 30px, six readable panes, shared renderer/action plumbing/lane grouping. This is not full history or retrieval proof.
- Existing coverage probe and screenshot: exit 0. Opened controls.png: dark shared footer controls visible; white frame and overlaid JSON belong to probe styling, so this is limited appearance evidence, not a polished full-window acceptance screenshot.

## Confirmed blockers

1. Unknown health still kills a live stream. Exact runStanding source returns `over` for {}, worker alive without arrays, an accepted scheduler row without state, or an alive foreign POST /node/chat label without matching run_ids. Watchdog treats that as terminal and aborts. Modified only snapshot harness health answer at held-stream poll to {}; browser fails `alive poll must not announce death` (unknown-health-stream.log). This is a behavior reproduction, not just source opinion. Requirement forbids abortion without authoritative terminal evidence. Existing test intentionally treats alive + empty lists as terminal; that does not justify incomplete answers. Route source serve.rs:494–496 includes /chat and /node/chat; health labels derive actual request labels. POST /runs is status/cancel, not itself proof of executing agent work: tested its shape without claiming it is a chat run. Scheduler running/queued records do keep stream alive.

2. Repaint preserves numeric scrollTop, not visible anchor under earlier/prepended rows. Real browser probe uses actual pane.transcript = shell.content; computed overflow auto, no nested wrapper is the scroll owner here. Nonbottom append: top 200, anchor unchanged, delta 0. Bottom append: distance 0. Prepend: same top 200 but old visible anchor shifts 241px (scroll.log). Thus append-only preservation is proven; earlier paging/prepend preservation is not. Live reasoning height/fold state changes remain untested, not silently accepted.

3. Stage parser accepts malformed/ambiguous evidence: same valid line followed by `false`, second `[stages: false]`, or duplicate required token all pass checkVerdict. Absent stages, duplicate complete marker lines and FAIL guard correctly refuse. This is a contract hardening blocker for the requested malformed/double/false rule, not an accusation that current browser stages were skipped.

## Identity caveats

Rust run ids are u64 (serve.rs, scheduler.rs), emitted as JSON numbers; scheduler increments or uses journal admission id. Number coercion loses precision above JS safe integer range; no production collision observed or asserted. threadOfRun trusts matching numeric id across conversations (decision-attacks foreignreuse => running) while accepted scheduler record checks conversation. Actual durable id uniqueness reduces ordinary reuse risk; node restart/reuse and stale terminal row precedence need dedicated verification. activeRun is restricted to POST /chat labels, not /node/chat; complete scheduler run_ids masks that gap. These do not upgrade missing health into terminal proof.

## Mutations (isolated snapshot only, restored)

- watchdog busy-unknown -> over: ui-browser exit 1, alive/busy preservation checks fail.
- final stage list -> false: underlying suite exit 0 but focused checker exit 1. Parser detects absent valid stages.
- pane-only ::before content MUTATION/color red: ui-browser exit 1, actual browser rule and computed-width differences reported. Not a source-only grep.
- scroll restoration -> scrollTop=0: browser measurement changes nonbottom anchor to false/top0 and bottom gap to 3356px. Measurement probe intentionally emits data, not correctness verdict; its process exit 0 is not counted as a passing scroll contract.

Original reviewed app.js/style.css/test-ui.ps1 restored byte-for-byte. Only copied probe runner exposes refreshAgentPane and substitutes paneMessages to feed rows; renderer/repaint under test unchanged. Snapshot excluded from review commit; reconstruct via git archive of exact tip. Stored runner is copied from its original snapshot location and must be invoked there (paths resolve relative to runner).

## Scope and closing limits

Full entering-midrun history and oversized-original retrieval are unfinished, exactly as original evidence states. Dedicated scroll proof is narrowed to append; prepending visibly fails anchor preservation. No full release gate, provider calls, push, main move, deploy, restart, or live UI/client interaction. Original review/ui-residues evidence was read, not rewritten. Closing CLI readiness cannot pass the mandated no-push boundary; report its refusal rather than bypass publication. Delivery record verdict is refused for exact tip, subject to CLI identity/publication checks.
