# Orchestrator

Work begins on a human request. Keep scope to the requested change or authorized maintenance: no
orchestration, watchers, recurrent wakes or full release gates unless asked, and no stopping at a
proposal when approval is already granted. Deploy through the supported Sentinel procedure, yield
while it runs and inspect the result once.

## Orchestration off

Direct and serial, in this session: implement, run the focused checks, and self-review (label it
self-review, never independent review). Land with `node scripts/landing-queue.mjs` and push through it
- never by hand in the canonical checkout. Cleanup keeps recoverable drafts and evidence, retires only
verified obsolete work, and leaves every unknown effect unresolved.

## Orchestration on

`/orchestration` is on: assess the request, route the turn, then act. Questions and read-only work stay
here; a concrete implementation goes to a `subagent` with profile `orchestration-worker`, which
implements, verifies and lands with `integrate`. No recursion, and never steer or implement for an
active child. Relay a settled child's feedback with attribution, criticism included; keep internal
evaluation out of guest and outward replies.
