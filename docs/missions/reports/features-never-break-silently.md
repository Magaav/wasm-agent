# features-never-break-silently

Base `4b314af5`, branch `change/features-never-break-silently`. Everything below was measured or run on
this node (avell) on 2026-11-23; nothing was deployed, no peer was called, no release was cut.

## 0. The premise, re-measured

| the brief said | what the tree says now |
| --- | --- |
| `wa health` is the place to show features | **it exists and means the node's own `/health` document**: `rust/wa-sentinel/src/main.rs`, `"health" => health_verb()`, which printed the body verbatim and failed when the node was down. The brief's `wa health` is therefore an EXTENSION of an existing verb, not a new one - done in `54266ec6`. |
| the release loop has a fleet read-back | `lua/core/land.lua:378`, `M.STEPS` = collect … deploy, linux, report. The deploy step asks each node and reads its record back (`impl.deploy`). The canary step is new, `35db7147`. |
| the release gate tests the tree | confirmed: `M.LANDING_STEPS`/`M.LANDING_GATE_STEPS` run rows in a scratch home; nothing exercised a feature on the installed node. |
| whatsapp-transcription-works gives the first case | read: `docs/missions/reports/whatsapp-transcription-works.md` (that mission is `done`). Its cause - the component starts with `post_transcripts` off and the operator's switch pointed at a removed connector - is what `whatsapp-copilot-reply` canary checks, by reading the component's own definition. |
| "a feature that ships without a line in this list fails a check" | new: `scripts/check-features-registry.mjs`, wired into `scripts/fast.sh` as the `features-registry` contract check (`35db7147`). |

One premise was WRONG and is worth recording: there is no `lua/commands.lua` at the top level (the CLI is
`lua/core/init.lua`) and no `%w+/status.lua`; `wa status` and the in-chat status page are the same module
`lua/core/status.lua`. The verb dispatch is a long `if/elseif` chain in `lua/core/init.lua`, which is where
`wa features` was added.

## 1. The one list - `ad7ca0f4`

`config/features/features.json`, 13 rows, each with `name`, `role`, `canary`, `last_success`,
`stale_after_s`. The five verdicts (`working`, `stale`, `failing`, `never`, `off-node`) are defined once in
`lua/core/feature_health.lua` and rendered by every surface.

What is TRUE about the rows today, stated rather than implied: **no hook records real traffic yet**. Eight
rows name the file whose code path would hold the hook; four name their canary explicitly
(`"canary: lua/core/canaries/… (no real-traffic recorder yet…)"`). Until the hooks land (section 8), a
feature's `last worked` is the last time its CANARY ran. The registry check refuses a `collector:` nobody
implements - it caught exactly that as soon as it was written.

## 2. The canaries - `4b46ef3e`, `50d852e8`

`lua/core/feature_canary.lua` runs `lua/core/canaries/<canary>.lua`. A loopback canary spawns a CHILD node
(this binary, its own `WASM_AGENT_HOME`, its own `--db`) and runs `lua/core/canaries/tasks/<name>.lua`, whose
exit code is the verdict, whose last `stage: <name>` line is where it got to, and whose `FAIL <stage>: …`
line is the detail. A read canary stays in the process and only reads.

| canary | mode | what it actually does | verified on this node |
| --- | --- | --- | --- |
| `chat` | loopback | one whole turn with the model stubbed at `host.http_stream`; the answer must be in the ledger | yes (`stage: readback… answered`) |
| `run-block` | loopback | the model's first answer is a `run` tool call; the block must write a file in the scratch home and the turn must finish | yes |
| `undo` | loopback | the write tool records a change; `/undo` restores the previous text and a second undo refuses `version_moved` | yes |
| `self-wake` | loopback | schedule → list → claim_due → finish → read back `delivered` | yes |
| `scheduled-jobs` | loopback | `host.jobs list` and `history` answer in the scratch store | yes (idle: no jobs defined) |
| `release-update` | read | `build_status.status()` names the binary's own commit and a known relation | yes (`stage: identity`) |
| `remote-calls` | read | the roster answers and an unknown peer is refused by name - **addressing only**, it does not prove a peer answered | yes (`stage: addressing`) |
| `whatsapp-index` / `-receive` / `-transcription` / `-copilot-reply` / `-send`, `mail` | read | index queries, the component's own `post_transcripts` + `post_allow`, the send route's named answer | **no** - this laptop has neither component, so they report `off-node`; their first real run is on the node that runs them |

`scripts/test-feature-canary.lua` proves the mechanism: the two shipping canaries above run for real through
the runner, and five fixture canaries prove each failure is NAMED (`canary_missing`, `canary_unloadable`,
`canary_malformed`, `canary_raised`, `child stage`), plus `binary_unknown` when no `wa` can be spawned, plus
`run_all` recording verdicts that the report reads back (56 checks).

## 3. `wa features`, `wa status`, `wa health` - `1f5e9d18`, `54266ec6`

* `wa features` prints one line per feature with `last worked: <ISO time>`, exits 1 when anything stopped;
  `wa features json`; `wa features canary [name]`.
* `lua/core/status.lua` gained one `features` line with the first stopped feature named.
* `wa health` prints the node's `/health` document and then the same rows, computed in Rust from the same two
  files (`rust/wa-sentinel/src/feature_health.rs`, 4 unit tests green) - so it answers even when the node is
  down; the exit code and message for a down node are unchanged.

Run, verbatim, against a scratch home (`7865a08e` binary):

```
features:  13 listed  0 working  2 stale  1 failing  5 never  5 off-node
  chat                    stale     last worked: 2023-11-14T22:13:20Z  (last worked 1104d ago (2023-11-14T22:13:20Z), past its bound of 86400s)
  run-blocks              failing   last worked: 2023-11-14T22:13:20Z  (last failed at 2023-11-14T22:15:00Z (stage readback); last worked 2023-11-14T22:13:20Z)
```

and after `wa features canary` on this node: `features: 13 listed 8 working 0 stale 0 failing 0 never 5 off-node`.

## 4. The release step - `35db7147`

`M.STEPS` is now `… publish, deploy, canaries, linux, report`. `impl.canaries` runs the canaries after the
deploy read-back, writes `evidence/canaries.log`, and on a failure returns `error=canary_failed` with the
feature and stage in `detail`, the evidence path, and a `next` line carrying
`wa update <node> --commit <the sha the release installed>` - the node goes back on the previous release
unless Fable says otherwise, and the step does not roll back on its own word. A docs-only round skips it
saying nothing was installed; a Lua round runs it. It also calls the notice, so the operator hears it once.
`scripts/test-land-canary-step.lua` (26 checks) proves the position in the loop, the docs-only skip, the red
by name, the evidence lines, the rollback line, the green path, and that an unreadable registry is a refusal
rather than a green step.

**This step is the part Fable reviews (release path).**

## 5. The notice - `1f5e9d18`

`lua/core/feature_notice.lua`: one notice per INCIDENT (the identity is the sorted set of stopped features
and their verdicts), the node log always, the operator's channel when the node has one, and a send that
failed is never recorded as sent. `scripts/test-feature-notice.lua` (30 checks) covers once/silence, a changed
set speaking again, recovery clearing the incident, a refused send being retried, and an off-node feature
never waking anybody.

## 6. The "never silence" rule (brief item 5)

Partly done and honestly partial: the RULE is implemented for canaries - a feature that cannot be exercised
says so by name to the operator (`wa features`, `/status`, `wa health`, the release report) - and for the
notice. A test per feature that REMOVES its dependency and asserts a visible message exists only for the
canary classes (the five fixture failures in `scripts/test-feature-canary.lua`). Per-feature
"fails-for-the-user" tests are section 8 work.

## 7. Tests and where they are wired

| test | wired |
| --- | --- |
| `scripts/test-feature-health.lua` (96 checks) | fast-path row by name (auto-discovered `scripts/test-*.lua`, not in `scripts/fast-path.exclude`) |
| `scripts/test-feature-canary.lua` (56 checks) | same |
| `scripts/test-feature-notice.lua` (30 checks) | same |
| `scripts/test-land-canary-step.lua` (26 checks) | same, and its subject row is one of the never-dropped `test-land-*.lua` rows |
| `rust/wa-sentinel → feature_health_tests` (4 tests) | `cargo test -p wa-sentinel` |
| `scripts/check-features-registry.mjs` | `scripts/fast.sh` contract check `features-registry` (`35db7147`) |

Each lua test refuses to run outside its own scratch home (`scripts/lib/test-home-guard.lua`) and each of
them errors on the base commit (the modules they test do not exist there), so they discriminate.

## 8. Not done, named

1. **Real-traffic hooks.** No code path calls `feature_health.record(...)` yet. The next item, one hook per
   feature, is what turns `last worked` from "when the canary ran" into "when a user's request succeeded".
2. **`remote-calls` end to end.** No background-spawn capability exists (`capabilities.rs` has no
   spawn/serve), so a canary cannot stand up a second serving node. The honest next step is the release step
   starting a scratch peer on a scratch port and calling it through `nodes.remote_call`; until then the
   canary proves addressing and refusal only, and says so in its own file.
3. **The six WhatsApp/mail canaries have never run on a node that runs those components.** They are written
   against the real capabilities (`whatsapp_search/read/contacts`, `whatsapp_send_status`, `email_search`, the
   component definition) and answer `off-node` here.
4. **The registry reaches a node only through `scripts/deploy.sh` (6b).** A *Lua-only* deploy to a peer does
   not carry `config/features/features.json` unless the payload includes `config/`; a node without it answers
   `features: unreadable - … (named)`, which is a red, not a silence - but it is a gap.
5. **Per-feature "removes its dependency, asserts a visible message" tests** (brief item 5), as above.

## 9. Texts to approve (model- or operator-facing, verbatim)

1. `features: %d listed  %d working  %d stale  %d failing  %d never  %d off-node`
2. `  %-Ns  %-9s  last worked: %s  (%s)` (one line per feature; `never` when nothing was recorded)
3. `usage: wa features` / `       wa features canary [name]     run the canaries (all, or one) and record the verdicts` / `       wa features json              the same rows as JSON`
4. `wa: %d feature(s) stopped: %s` (the notice's first line)
5. `wa: %s failing (last failed at %s (stage %s); last worked %s)` (per feature in the notice)
6. `canaries: %d passed, %d failed, %d off-node`
7. `  %-22s PASS  %s` / `  %-22s FAIL  %s: %s` / `  %-22s SKIP  %s (%s)` (the canary table)
8. `release is RED by name: %s` (the release step's `detail`)
9. `put the node back on the previous release (wa update <node> --commit %s), unless Fable says otherwise; then fix %s before cutting again`
10. `the node does not answer %s (is it down?)` (unchanged; `wa health` now prints the features first)
11. `feature-health: wa: %d feature(s) stopped: …` and `feature-health: operator channel not used - %s` (the node log)
12. `canary_missing` / `canary_unloadable` / `canary_malformed` / `canary_raised` / `spawn_failed` / `binary_unknown` / `off-node` (the named failure stages)
13. `nothing has been recorded for it on this node` / `last worked %s ago (%s), past its bound of %s` / `last failed at %s (stage %s); last worked %s` / `last failed at %s (stage %s); it has never worked` (the verdict details)

## 10. Proposed FACTORY.md / HANDOVER.md text (NOT written)

> **Feature health (23/11).** Every user-facing feature has a row in `config/features/features.json` (role,
> canary, last-success source, staleness bound). `wa features` prints the table, `wa health` prints it after
> the node's own document, `/status` summarises it, and `wa features canary` runs the exercises - each in a
> scratch child node or read-only, never against the operator's data. `wa release cut` runs the canaries
> right after the deploy read-back and stops the release RED BY NAME with the rollback line when one fails.
> A feature that has not succeeded inside its own bound raises ONE notice per incident. New rule: a feature
> that ships without a line in that list fails `scripts/check-features-registry.mjs`, and a canary that
> cannot run is a named failure, never a pass. Still open: real-traffic hooks (rows currently record the
> canary's run), a two-node loopback for `remote-calls`, and the WhatsApp/mail canaries' first run on the
> nodes that own those components.

## 11. Verification runs (commands, on this node, with the tree's own binary `54266ec6`)

```
node scripts/check-features-registry.mjs                  -> features-registry ok (13 rows, every one with a canary and a last-success source)
WA_SCRIPT=scripts/test-feature-health.lua  wa --db …      -> feature-health ok (96 checks)
WA_SCRIPT=scripts/test-feature-canary.lua  wa --db …      -> feature-canary ok (56 checks)
WA_SCRIPT=scripts/test-feature-notice.lua  wa --db …      -> feature-notice ok (30 checks)
WA_SCRIPT=scripts/test-land-canary-step.lua wa --db …     -> land-canary-step ok (26 checks)
WA_SCRIPT=scripts/test-land-rows.lua       wa --db …      -> land ok (137 checks)          <- lua/core/land.lua row
WA_SCRIPT=scripts/test-land-plan.lua       wa --db …      -> land ok (109 checks)          <- lua/core/land.lua row
bash scripts/test-deploy-policy-order.sh                  -> deploy policy order: ok (8 checks)   <- scripts/deploy.sh row
cargo test --release feature_health (wa-sentinel)         -> 4 passed
wa features canary (scratch home, this node)              -> canaries: 8 passed, 0 failed, 5 off-node
wa health (scratch home, this node's binary)              -> "features:  13 listed …" + one row per feature with `last worked: <ISO>`
```

**The narrowed fast-path run is NOT in that list, and the reason matters.** It was started twice
(`WA_FAST_ROWS` over the rows above, under `flock -o`); the first was piped through `tail -40`, whose exit
code hides the run's own, and the second was queued behind the orchestrator's `main-health` on this node's
suite lock and then **killed by a node install mid-run** (`FAST_RC=2`, twelve lines of build output and no
rows). So the rows above were run DIRECTLY, one process each, with the tree's own binary and a scratch
`WASM_AGENT_HOME`: that is not a weaker check for these files (the fast path would spawn the same binary
with the same fence), but it is not the runner's own verdict either, and the bridge's full run will be the
first time the `features-registry` contract line executes inside `scripts/fast.sh`.

## 12. Fable's review, the four fixes (`8409562b`)

### 1. The fleet runs its own canaries

The canaries step no longer proves only the machine that cut the release. `impl.canaries` asks **every node
the deploy INSTALLED ON** - `steps.deploy.nodes`, written by the deploy step as each node settles as
`installed` or `unknown`, never the configured ring (a ring names what a round WOULD touch) - to run
`wa features canary json` over the peer plane, and collects the answers into the evidence file, one section
per node.

| outcome | verdict |
| --- | --- |
| every node answered, nothing failed | green, with the count asked/answered |
| a node's canary failed | **red**, naming `node feature (stage)` |
| a node could not be reached or answered nothing parseable | **red** as `canary_unproven`, naming the node and the peer's own reason (`unknown_node:work`, `relay_timeout`, ...) |
| the deploy recorded no per-node outcome | nobody is asked, and the step says so in its evidence and in `observed` |

The ask is turned on by a RELEASE (`M.run` sets `fleet_canaries` when `options.release`), so a plain landing
and every fixture that runs the loop leaves it off. Tests (`scripts/test-land-canary-step.lua`, 49 checks):
both ring nodes are asked with exactly `wa features canary json`; an unreachable node is `canary_unproven`
and never green; a peer's failing canary is red with `scratch-b whatsapp-transcription (no_transcript)`; the
evidence keeps a section per node. No live peer is ever called: the peer call is `options.remote_call` (the
test's stub) or `impl.canaries_remote` (a fixture's).

### 2. The rollback names the PREVIOUS release, per node

The old line printed `run.journal.main_sha` - **the commit that just failed**. `M.previous_release(run)` now
reads the published journals under the run root newest-first and takes the first one that is not this run
(`publish.tag` + `tree_commit`), and the `next` line is

```
scratch-b: wa update scratch-b --commit 1111... (back to v0.2.9)
```

per node. When no previous release is recorded the line says so by name and points at the node's own install
record (`wa call <node> bash 'cat <install>/installed.txt'`) instead of printing a commit that is not a
rollback target. Tested: the line carries the fixture's previous commit and tag and does **not** contain this
run's sha.

### 3. What each WhatsApp canary touches, and the guarantee it cannot post

| canary | what it touches on a live node |
| --- | --- |
| `whatsapp-index` | one read: `host.whatsapp_contacts('{}')` (`lua/core/canaries/whatsapp-index.lua:16`) |
| `whatsapp-receive` | one read of contacts + one `host.whatsapp_read` of the newest message (`whatsapp-receive.lua:15-20`) |
| `whatsapp-transcription` | one read: `host.whatsapp_search({kind="voice", limit=5})` (`whatsapp-transcription.lua:16`) |
| `whatsapp-copilot-reply` | one read of `<state>/components/wa-whatsapp.json` (`whatsapp-copilot-reply.lua:19-25`) |
| `whatsapp-send` | one read: `host.whatsapp_send_status({id="canary-no-such-send"})` (`whatsapp-send.lua:19`) - no send exists to read |

**None of them can message anybody**: every one runs its body inside `guard.no_send`
(`lua/core/canaries/whatsapp-send.lua:17`, `whatsapp-copilot-reply.lua:29`, `whatsapp-index.lua:13`,
`whatsapp-receive.lua:12`, `whatsapp-transcription.lua:13`), which replaces `host.whatsapp_send` and
`host.whatsapp_approve` with functions that RAISE and restores them afterwards
(`lua/core/canaries/guard.lua:16-33`). A canary that grows a send fails as `send_attempted` instead - proven
in `scripts/test-feature-canary.lua` (a fixture canary that calls `host.whatsapp_send` is refused, and the
node's real door is verified restored).

**Posting off is not a failure.** With `post_transcripts` off the copilot canary answers
`off (posting disabled)` - the reader switched it off. Posting ON with an empty `post_allow` is a real
misconfiguration and still fails (`posting_unscoped`). `off` is a third outcome: printed as `OFF`, counted
separately, and **never recorded** as a success (so an off feature does not read as "last worked").

### 4. A canary's time is labelled

`feature_health.lines()` and the Rust renderer print `last worked: <ISO>  [canary]` when the snapshot's
`last_ok_source` is `canary`, and nothing when a real code path recorded it. So `wa features`, `/status` and
`wa health` cannot show a synthetic pass as real use. Tested in `scripts/test-feature-health.lua` (a
canary-sourced row is labelled, a hook's is not) and in the crate's tests (the rendered line carries the
marker).

