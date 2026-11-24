# ready-runid2

Branch `change/selfloop-ledger-upgrade-2` from `origin/main` `ffb5153e` (the fix that landed and was installed at
17:55Z). Two commits, clean, nothing pushed, nothing on the live node touched.

| commit | what |
| --- | --- |
| `98df9ebf` | (i)+(ii) the upgrade row covers EVERY table, and the released BINARY is its default |
| `60691c09` | (iii, memo half)+(v) a clean tick clears the once-per-error memo; dates corrected |

## (i) Every table, lazily created ones included - DONE

A serve does not create `access_events`, `access_requests`, `agent_control`, `done_checks`, `done_gates`,
`ledger_events`, `provider_serving` or `turn_notes`; each subsystem creates its own when it first runs. The row now
calls EVERY module's setup on BOTH sides (`selfloop`, `enrollment`, `agent_control`, `done_gate`,
`event_ledger`, `provider`, `turn_journal`), takes the table list from `sqlite_master` instead of a hard-coded
four, and compares the column set of every table.

Measured here: `every table's columns after the upgrade equal a fresh ledger's` and `a wake scheduled on the upgraded
ledger is claimed and dispatched by one tick` (`ROW {"attempts":1,"status":"dispatching"}`). The previous four-table
version's RED on main was `self_wakes: missing ["run_id"]`.

## (ii) The released binary's own setup is the default - DONE

`$WA_RELEASED_BIN`, else the published **v0.1.1 / node-2104a4d88a37** asset looked for under
`$WA_RELEASES_DIR`, `~/.wasm-agent/releases/v0.1.1|node-2104a4d88a37/wa` and `build/release/...`. The tag's
source under today's binary is the FALLBACK, and the row prints which of the two made the ledger
(`released ledger from: ...`). On this machine no published asset exists, so this run used the tag source and said
so - which is the behaviour asked for.

## (iii) The tick log line - HALF DONE, and named

* Done: a successful tick now CLEARS the once-per-error memo (`SELFLOOP_TICK_ERROR, SELFLOOP_TICK_LOGGED = "", ""`)
  and counts clean ticks, so an error that returns after a good tick is logged again.
* NOT done: **the red/green ROW asserting `selfloop_tick_failed`**. The line and `M.selfloop_tick_state()` are
  wired (previous round, `9c009cbb` on the landed branch), and the fixture that raises inside the tick is exactly
  what the upgrade row already builds (a ledger whose `self_wakes` has no `run_id`), so the row is a small next
  step: run that ledger, call `wa_orchestrator_tick()`, assert the log line and `selfloop_tick_state().error`.

## (iv) The /health wake facts - NOT DONE

Not started in this round. The five facts (last tick time and outcome, due and dispatchable counts, age of the
oldest dispatchable due row, last dispatch time) and the named rule ("oldest dispatchable due row older than 120 s
with an idle lane" is red by name) still need: a `selfloop.wake_facts()` that reads them, the field in the
`/health` body (whose Rust assembly is in `rust/wa-capabilities/src/serve.rs`), and the post-install check and the
watchdog reading that field. `M.selfloop_tick_state()` (at, error) is what the block would sit beside.

## (v) Dates - DONE

`25/11` -> `24/11` in `lua/core/selfloop.lua`, `lua/core/subagents.lua`, `scripts/test-ledger-upgrade.sh`,
`scripts/fast.sh`.

## Still owed on r8c (named by Fable, not started)

The install's release made a NEW "deploy ended: resumed now" row for `b7e90a52` while its old resume (`d1cd45bc`)
was still pending, so two dispatched together: the release must COLLAPSE (one resume row per session) as well as
re-arm. That is the next r8c item and is untouched here.
