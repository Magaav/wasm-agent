# graph-dormant

**Verdict. The graph is OFF by default on every node from G, and the switch is one row in the feature
resolver.** With nothing set, the `graph` tool is not in the catalogue a model reads, `host.graph_*` answers
`graph_dormant` (not an empty success, not a component error), the write path sends no hint, and no
scheduler entry, OS watch, index or store is created. `"graph": true` in the policy's `features` section (or
`WA_GRAPH_COMPONENT=1` for one process) turns all of it back on in the same process, one watch interval
later - today's behaviour, unchanged. The measured prompt change is **-76 bytes** of system prompt, exactly
the one catalogue line the graph owned, and nothing else.

## 1. Re-measured first: what the brief held, and what it did not

| the brief said | what this node shows (23/11, read-only first) |
|---|---|
| the worktree is `change/graph-dormant` on base `4ba1c3d9` | confirmed, `git rev-parse HEAD` = `4ba1c3d9`, branch `change/graph-dormant`, clean tree |
| item 5: "features registry: **mark graph's row** off by default" | **stale: there was no graph row.** `config/features/features.json` held 13 rows and none was the graph, so item 5 was not a marking but an addition - and, because `lua/core/feature_health.lua` counts a row with nothing recorded as `never` (which `M.red` counts), the row alone would have reported the graph as a broken feature for ever. That is why the sixth verdict word below exists |
| item 2: "docs/GRAPH.md: status: dormant, why, the table, how to switch it on" | the file existed (310 lines) and described the graph as the live behaviour, with no status line; the comparison table lives in `docs/missions/reports/graph-one-store-per-root.md` §6b and was copied from there, not re-invented |
| the graph tool is a schema among the shared ones | **it is in `M.admin`, not `M.shared`** (`lua/core/tools.lua:519`). The first filter written for this mission hid the shared list only, and the catalogue still carried the line (measured through `tools.catalog('master')`: 74 entries, graph at 34). The filter now runs once over the ASSEMBLED catalogue, so it also covers a plugin or a peer connector named `graph` |
| the one door for feature switches (`docs/FEATURES.md`) is enough for a default-off row | the resolver had one global `DEFAULT_ENABLED: bool = true` (`rust/wa-features/src/lib.rs:259`), so "off by default" needed a per-row field (`FeatureSpec::default_enabled`). That is a documented edit to the feature table: eight rows now say `true` explicitly and the ninth says `false` |
| `policies/default.json` names every feature | it named the eight, all `true`. It now names nine, the graph `false`, and the test that asserted "every shipped feature is true" was **tightened** (not loosened) to "every shipped feature equals its own default" |

## 2. What changed

**(a) One switch, default OFF (commit `0b30f247`).** The `graph` row of `wa-features`: `id: "graph"`,
`component: "graph"`, `env: "WA_GRAPH_COMPONENT"`, `default_enabled: false` (`rust/wa-features/src/lib.rs`).
A new reason, `REASON_DEFAULT_OFF = "default_off"`, keeps "nobody said anything" apart from "the operator
wrote `false`" (`feature_off`), and `wa_features::enabled(id)` is the one question a feature with no native
path asks (an unknown id answers `false`: a name the tree does not have is not permission to run something).

**(b) Every graph door refuses by name (same commit).** `rust/wa-capabilities/src/graph.rs`: `dormant()` is
called at the four entrances (`run`, `notify`, `graph_status`, `graph_snapshot`) and `watch_configured()`
returns before it resolves a root - so a dormant node registers no recursive OS watch, spawns no worker,
creates no store and answers nothing it cannot answer. `lua/core/tools.lua` drops the schema in `M.catalog`
and refuses `graph` in dispatch (`graph_dormant`, `effect: none`, the switch in `next`);
`lua/core/graph.lua`'s `available()` is false; `lua/core/patch_audit.lua`'s `enabled()` now needs the switch
as well as its own `WA_GRAPH_PATCH_AUDIT`; the write path's `graph_hint` returns nil, so a write carries no
`graph_index` field at all instead of a false one.

**(c) The registry row, its canary and a verdict that can say "nobody asked" (commit `ecf31a86`).**
`config/features/features.json` gains the graph row (`role: component:graph`, `canary: graph`,
`"default": "off"`, a week's bound); `lua/core/canaries/graph.lua` answers the runner's third outcome,
`off`, while the switch is off (nothing proven, nothing broken) and, switched on, indexes one scratch file
and reads its symbol back through the component. `lua/core/feature_health.lua` and
`rust/wa-sentinel/src/feature_health.rs` both gained the same sixth word, `dormant`, decided by the same
resolver: a `default: off` row whose switch says off is dormant, is never counted red, and goes back to the
ordinary verdicts the moment the policy says true - so switching it on cannot be hidden by the word. The
row's `default` field is validated in both readers and in `scripts/check-features-registry.mjs` (a value
that is not `on`/`off` is refused by name).

**(d) The rows that drive the graph now switch it on themselves (same commit).** `scripts/lib/test-graph-on.lua`
writes `features.graph: true` into the row's OWN policy file and then asks the resolver until it answers on
(refusing if it does not, and refusing outright when the home is not a scratch one). Thirteen rows call it.
It is deliberately not a runner variable: `WA_GRAPH_COMPONENT=1` exported by the runner would also switch it
on for the row whose job is to prove the default.

**(e) A test seam for the switch, and the refusal held by its own test (commit `04d93e8e`).**
`rust/wa-capabilities/src/graph_tests.rs` had one test driving the gated hint; it now holds the switch on
through a guard (the same shape as the file's existing `TEST_CALL` seam for the component) and a new test
holds it off and asserts every door answers `graph_dormant` with `effect: none`.

**(f) What the narrowed run caught: a dormant node could not delegate `explore` (commit `685fa5ea`).**
Two built-in subagent profiles name the graph in `allowed_tools` (`lua/core/subagents.lua`), and a profile may
only name a tool the caller's catalogue offers - `profile_exceeds_caller:<tool>` - so on a node with the graph
off every `explore` child was refused over a tool the node simply does not have. It was invisible in the rows
I had run and loud in `scripts/test-esc-stops-pty.mjs`: measured on this branch, `subagent: Esc brings the
prompt back at once` and `subagent: the ledger records the interrupt as its own input row` failed twice in a
row (16 ok, 2 failed), against 18 ok on the base; after the fix, 18 ok on both. The profiles now carry the
graph's name and its one instruction sentence separately and add them per call when the switch says on - the
switch is live, so a copy is made per call rather than editing the shared built-in table. In the same commit,
the on/off question moved to one function, `lua/core/features.lua`'s `on(id)` (a feature with no native path
asks `on`, not `seam`), and the four callers that had written the same three lines now ask it.

**(g) The documents (commit `77333a08`).** `docs/GRAPH.md` opens with the status and the decision: the
table verbatim from `graph-one-store-per-root` §6b, the paragraph that reads it honestly, the one switch in
a two-row table (policy key, env), what "off" means in the code, and the point where the rest of the
document starts describing the graph as it behaves when switched on. `docs/ENVELOPE.md` is generated and
lost exactly the graph's two lines (`scripts/sync-prompt-docs.sh --write`).

## 3. The probe: base vs tip (item 3)

`scripts/probe-prompt-bytes.lua`, base `4ba1c3d9` (worktree `bs`) against this branch (worktree `wt`), each
with its own scratch home. The two roots are at paths of the SAME length on purpose: the first run compared
`.../base` with `.../wt` and the three workdir/project lines made the system prompt 6 bytes shorter for a
reason that has nothing to do with the graph.

**There are two prompt shapes, and the graph costs a different amount in each.** The probe forces
`WASM_AGENT_CODEMODE=native`; whether the code-mode block is actually there depends on the binary carrying
code-mode assets. So I measured both, with the same trees:

**(a) Code mode ON - the shipped node's shape (release binary with assets).**

| field | base | tip | change |
|---|---|---|---|
| `catalogue.master` | 74 | 73 | **-1** |
| `catalogue.guest` | 23 | 23 | 0 (the graph was always master-only) |
| `envelope` (declared array) | 1 item | 1 item | 0 |
| `envelope_bytes` | 786 | 786 | **0** |
| `system_bytes` | 20560 | 20560 | **0** |
| `system_wire_bytes` | 20912 | 20912 | **0** |
| `prompt_bytes` | 21346 | 21346 | **0** |
| `codemode_bytes` | 1388 | 1388 | 0 |

In this shape the graph never had a line in the system prompt: the prompt declares the code-mode tool and the
model reaches the rest through `searchTools`, so removing the graph from the catalogue costs **no bytes at
all** - what it removes is the on-demand schema and the `searchTools` hit (`tools.catalog` is what both read).

**(b) Code mode OFF - a node whose binary has no code-mode assets (the debug build here).**

| field | base | tip | change |
|---|---|---|---|
| `catalogue.master` | 74 | 73 | **-1** |
| `catalogue.guest` | 23 | 23 | 0 |
| `envelope` (declared tools) | 12 tools, unchanged | 12 tools, unchanged | 0 |
| `envelope_bytes` | 8059 | 8059 | **0** |
| `system_bytes` | 21379 | 21303 | **-76** |
| `system_wire_bytes` | 21766 | 21689 | **-77** |
| `prompt_bytes` | 29438 | 29362 | **-76** |
| `codemode_bytes` | 1388 | 1388 | 0 |

The whole text difference between the two system prompts, from `diff`:

```
99d98
< - graph: Retrieve symbol source, trace relationships, or audit patch impact
```

One line: 75 bytes of text plus its newline = **76**, which is the system and prompt delta exactly. The wire
delta is 77 because JSON encodes that newline as two bytes (`\n`) where the raw content paid one. Nothing else
in either prompt mentions the graph, so the brief's "ONLY the catalogue line(s) for the graph tools are gone"
is true to the byte in the shape where the tool had a line at all.

**The correction to note.** My first measurement used the debug binary and reported the -76 as THE change.
That is the code-mode-off shape; a node running this tree's release build has code-mode assets and pays 0
prompt bytes. Both numbers are in this report because a reader would otherwise take the flattering one for the
shipped one; the honest summary is "**-76 bytes of system prompt where the tool had an index line, and 0
where the prompt is the code-mode one - and -1 catalogue entry either way**".

## 4. Tests that fail on main (item 4)

`scripts/test-graph-dormant.lua` (new, 16 checks, one row): with no policy file - the graph is not in the
catalogue a role may use, not in the list the prompt declares, `graph.available()` is false, a by-name
`graph` dispatch answers `graph_dormant`/`effect: none` with the switch in `next`, a `write` succeeds and
carries **no** `graph_index` field, and `find <state> -name 'graph.db*'` is empty after all of it; with
`features.graph: true` - the tool is in the catalogue and in the prompt declaration, `available()` is true and
the dispatch is no longer refused as dormant; with `false` again, in the same process - both are gone again.

**It fails on the base**, with the same binary, at its first assertion:

```
lua error: [string "scripts/test-graph-dormant.lua"]:73: no policy file: the graph is not in the catalogue a role may use
```

Wiring: the fast path runs every `scripts/test-*.lua` that `scripts/fast-path.exclude` does not exclude, so
the row is in the fast path by existing; it is also a row in `scripts/test.sh`, next to the other graph rows, so main-health runs it too.

Rows for existing behaviour that my change would otherwise have broken were changed to opt in, never
loosened: thirteen graph-driving rows call `scripts/lib/test-graph-on.lua` (which refuses if the switch did
not take), the `graph` hint test in `rust/wa-capabilities` holds the switch on through a guard, and
`scripts/test-features-defaults.lua` now states nine rows and asserts the graph's own default
(`enabled: false`, `reason: default_off`, `active: native`) beside the eight that stay on - every existing
assertion kept, plus the exception named.

## 4a. What ran, and what it said

| suite | result |
|---|---|
| `cargo test -p wa-features` | **17 passed**, including `the_graph_is_off_by_default_and_either_switch_turns_it_on` and `the_shipped_default_names_every_feature_at_its_own_default` |
| `cargo test -p wa-capabilities graph::` | **42 passed**, including `a_dormant_graph_refuses_every_door_by_name_and_touches_nothing` |
| `cargo test` (wa-sentinel, `feature_health`) | **5 passed**, including `a_row_that_defaults_off_is_dormant_until_the_policy_switches_it_on` |
| `node scripts/check-features-registry.mjs` | `features-registry ok (14 rows, every one with a canary and a last-success source)` |
| narrowed `scripts/fast.sh`, the rows for the files this mission touched | **`fast path FAILED (4 of 144 checks, 0 skipped, 550 s)`** on commit `685fa5ea`, and the four are the ones named below, none of them this mission's: `47/49` Lua rows passed (the two `test-land-*` rows), the one `wa-capabilities` failure is the TLS test, and `esc-stops-pty`'s `bash` case is the load-sensitive timing row - run alone on base it failed once too (17 ok, 1 failed), and on this branch alone it passes 18/18. |

The narrowed run was `flock -o ~/Work/missions/.suite.lock env WA_FAST_ROWS=... bash scripts/fast.sh` (the
G-wave rule), and the row list is the rows this mission's files touch: the fourteen graph rows, the five
feature rows, and the catalogue/prompt rows (`test-host-return-docs`, `test-prompt-tool-names`,
`test-email-absent`, `test-envelope`, `test-tool-cues`, `test-refusal-contract`). Four rows I first asked for
are in `scripts/fast-path.exclude` (the repair and watch rows, the index-failure row and `test-prompt-layers`)
and the runner REFUSED by name rather than skip them, which is correct.

**Its four failures, and where each comes from.** Two are documented pre-existing rows on this machine, and I
ran both on the base commit with the same binary to prove it: `test-land-linux` (`the channel step comes right
after the deploy (got 14, want 13)`) and `test-land-until` (`a later release runs on its own, and deploys the
ring (got 1, want 0)`) fail **identically** on `4ba1c3d9`. The third is
`host::tls_anchor_tests::a_provider_call_refuses_a_private_ca_that_no_bundle_names` in `wa-capabilities`: it
fails on the base too (400 passed, 1 failed on both trees), in a file this mission does not touch. The
fourth - `esc-stops-pty`, the `subagent` pair - was MINE, and §2(f) is its fix.

Operator view, measured on a scratch node with the installed graph component copied in:

```
features: 14 listed  0 working  0 stale  0 failing  8 never  5 off-node  1 dormant
  graph                   dormant    last worked: never  (graph is off by default on this node and nobody switched it on (default: default_off); nothing is broken and nothing is proven - docs/GRAPH.md)
```

and with `WA_GRAPH_COMPONENT=1`, the same node:

```
features: 14 listed  0 working  0 stale  0 failing  9 never  5 off-node  0 dormant
  graph                   never      last worked: never  (nothing has been recorded for it on this node)
```


## 5. Texts to approve (verbatim, new or changed model- and operator-facing strings)

Model-facing:

1. The refusal the `graph` tool answers when it is dormant (`lua/core/tools.lua:2251`, and the same sentence
   from the host at `rust/wa-capabilities/src/graph.rs:1546`): `error: graph_dormant`, `effect: none`, and
   `next`: `The code graph is OFF by default on this node (docs/GRAPH.md). Read with read/grep, or switch it on: WA_GRAPH_COMPONENT=1, or "graph": true in the features section of policy.json.`
2. The two lines REMOVED from the model's world, `docs/ENVELOPE.md` (generated):
   `- graph: Retrieve symbol source, trace relationships, or audit patch impact` and the table row
   `| graph | action aspects? byte_offset? commit? critique? cursor? cwd? depth? direction? evidence? force? from? grade? hours? kind? limit? line? max_bytes? name? offset? outcome? path? prefer_implementations? reason? run_id? source? source_version? to? | Retrieve symbol source, trace relationships, or audit patch impact |`

Operator-facing:

3. The feature row's own words, in `wa features --json` and its table:
   `the code graph: the `graph` tool, host.graph_* and the indexer (OFF by default)` and its native answer
   `nothing - the graph is dormant and read/grep answer (docs/GRAPH.md)`.
4. The reason a dormant row is off: `default_off` (distinct from `feature_off`, which says an operator wrote
   `false`).
5. Both readers' summary line gains the sixth count:
   `features: %d listed  %d working  %d stale  %d failing  %d never  %d off-node  %d dormant`
   (`lua/core/feature_health.lua:345`, `rust/wa-sentinel/src/feature_health.rs`).
6. The dormant row's detail (`wa features`, `wa health`):
   `<name> is off by default on this node and nobody switched it on (<source>: <reason>); nothing is broken and nothing is proven - docs/GRAPH.md`
7. A registry row whose `default` is neither `on` nor `off`, refused by name in both readers and in the check:
   `the feature <name> declares default <value>, which is not on or off`
   (`scripts/check-features-registry.mjs` words it `the feature <name> declares default <json>, which is not on or off`).
8. The graph canary's `off` verdict label and detail: `off (switched off)` and
   `the graph is off by default on this node (<source>: <reason>); switch it on with WA_GRAPH_COMPONENT=1, or "graph": true in the policy features - docs/GRAPH.md`;
   its pass line: `one scratch file was indexed and its symbol read back through the component`.
9. The registry row's provenance prose (`config/features/features.json`):
   `canary: lua/core/canaries/graph.lua (the graph is OFF by default: nothing is proven while it is off, and a switch-on indexes one scratch file and reads it back)`.
10. The docs: `docs/GRAPH.md` opens with `**Status: DORMANT - OFF by default on every node from G (23/11).**`
    and the two-row switch table (`"features": { "graph": true }` in `<state>/policy.json`, or
    `WA_GRAPH_COMPONENT=1` for one process).

## 6. Verified, and not verified

Verified on this node, this tree (`04d93e8e` and the commits listed in §2):

* the probe numbers in §3, base and tip, same binary, equal-length roots;
* `cargo test -p wa-features` 17/17, `cargo test -p wa-capabilities graph::` 42/42, `cargo test` on
  `wa-sentinel` restricted to `feature_health` 5/5, `node scripts/check-features-registry.mjs` 14 rows ok;
* `scripts/test-graph-dormant.lua` passes on this tree (16 checks) and fails on base `4ba1c3d9` at its first
  assertion, with the same binary;
* the operator view in §4a, on a scratch node with the installed graph component copied in, off and on;
* the narrowed `scripts/fast.sh` run named in §4a (its verdict line is there).

Not verified, and named as such:

* **the full suite and the full gate were not run** (the G-wave suite rule: a landing runs no gate). The
  narrowed run covers the rows this mission touched; main-health runs the whole check on main after the
  landing, and a red there comes back to this branch.
* **`wa health` was not run end to end**: the sentinel binary was not rebuilt for this check, so the sixth
  word is proven by its own unit tests (`a_row_that_defaults_off_is_dormant_until_the_policy_switches_it_on`)
  and by `wa features`, which shares the registry and the resolver, but not by a live `wa health` print.
* **a graph canary run was not made on this node**: the graph is off here, so the row answers `off` (proven by
  its code path and the runner's own `off` branch), and the switched-on half of the canary (index one scratch
  file through the component) needs a node whose graph is on. It is the one part of item 5 with no
  measurement behind it, and it is why the half is small and self-contained.
* **the graph component tests that need a built component** (`test-graph-freshness`, `-workspace`,
  `-automatic`, `-impact-paging`, `test-patch-audit` and the two `.cjs` rows) are covered by the narrowed
  fast run, which builds its own components; they were not run by hand against a component built separately.
* the invariant "nothing calls into the graph when off" is proven for the paths this tree has (tool catalogue,
  dispatch, `available()`, the write hint, patch audit, the four capability entrances and the boot watcher).
  A caller outside this tree (a pinned older Lua tree, a hand-written plugin) can still NAME a graph
  capability; it is refused by name, and that refusal is what the new Rust test holds.

## 6a. One harness defect found on the way (reported, not fixed here)

`scripts/fast.sh:288` is `exec 8>>"$work/lock" 2>/dev/null || true`. `exec` with only redirections applies
them to the shell itself, so that line redirects the RUNNER'S STDERR to `/dev/null` for the rest of the run:
every diagnostic after it - `fast: FAIL ...`, `fast: narrowed run REFUSED by ...`, the final tally - is
invisible, and the process exits with a code and no words. Measured here: the run refused my first row list
(`fast_narrow:unknown_row: scripts/test-graph-watch.lua`) and said so only inside the silenced stream; three
runs ended in `exit=2` with `wc -l` = 12 lines of log and nothing that named the cause. It cost this mission
four runs and a false "exit 0" (the pipeline's status was `tail`'s). The fix is to keep the redirection off
the shell: `exec 8>>"$work/lock" || true`. It is not fixed here because the runner is not this mission's
file and its own rows would have to be re-run around it; it is named so the next round can measure it.

## 7. Deliberately not done

* No release, no fleet, no deploy: the landing is a branch, and the switch is left OFF on every node by
  default, which is the point.
* No change to the graph's own indexing, storage or retrieval behaviour: switched on, this branch is today's
  code. The 76 % unresolved edges and the "cannot index 2,654 files in one call" limit measured in
  `graph-one-store-per-root` are untouched, and are named in `docs/GRAPH.md` as the reasons it is dormant.
* The graph component and its pin are untouched (`components.lock` unchanged), so switching on needs no
  install step beyond the one that already ships it.
* `scripts/fast-path.exclude` is untouched: the graph rows still run, they just switch the feature on first.

## 8. Proposed FACTORY.md / HANDOVER.md text (proposed only, never written)

For `FACTORY.md`, under the feature list:

> **The code graph is dormant.** It is OFF by default on every node (`docs/GRAPH.md`): not in the catalogue,
> no component loaded, no store created, and a write sends no hint. The switch is the `graph` row of the
> feature resolver - `"features": { "graph": true }` in the node's `policy.json`, or `WA_GRAPH_COMPONENT=1`
> for one process. The decision is measured in `docs/missions/reports/graph-one-store-per-root.md` §6b and
> `docs/missions/reports/graph-dormant.md` §3: -76 bytes of system prompt while off, and 150-400x grep's
> time with 10 of 23 call sites missed when on. A row that declares `"default": "off"` reports the verdict
> `dormant` in `wa features`/`wa health` instead of `never`, so a feature nobody switched on is never counted
> as a broken one.

For `HANDOVER.md`, in the graph paragraph:

> The graph is dormant from G: off by default, code kept, one switch (`features.graph` in the policy file, or
> `WA_GRAPH_COMPONENT=1`). While off it costs the prompt one line and the node no store, no worker and no
> watch; the rows that exercise it switch it on in their own home (`scripts/lib/test-graph-on.lua`), and the
> row that proves the default is `scripts/test-graph-dormant.lua`.

## 9. The preflight round: the merge with main `c618da4f` (merge `2258f800`)

The gate refused this branch on one row: `land-quick: merge conflict with main c618da4f in:
docs/ENVELOPE.md lua/core/tools.lua`. Both conflicts are the same shape - **two independent additions at
the same seam**: main added `STDIN_MAX_BYTES` (the stdin ceiling behind `bash {stdin=...}`) exactly where
this branch added `graph_offered()`, and `docs/ENVELOPE.md` is generated, so its conflict was main's new
`stdin`/`node`/`context` columns against this branch's removed `graph` row. Resolved by keeping BOTH blocks
in `lua/core/tools.lua` (neither line of either change was dropped) and by REGENERATING the generated doc
(`WA_BIN=... bash scripts/sync-prompt-docs.sh --write`), never by hand: against main `c618da4f` the
regenerated `docs/ENVELOPE.md` differs by exactly one line, the graph's own catalogue row.

Main changed none of this mission's other files between `4ba1c3d9` and `c618da4f`
(`git diff --stat 4ba1c3d9..main -- rust/wa-features rust/wa-sentinel lua/core/feature_health.lua
lua/core/features.lua lua/core/graph.lua lua/core/patch_audit.lua lua/core/subagents.lua
config/features/features.json rust/wa-capabilities/src/graph.rs` is empty), so the Rust and Lua evidence in
§4a still describes this tree.

**The rows, after the merge** (narrowed `scripts/fast.sh`, 151 checks): every land row passes -
`scripts/test-land-quick.lua`, `-tests`, `-components`, `-main`, `-install`, plus `test-land-plan`,
`-rows`, `-gate-rows`, `-sign`, `-review`, `-marks`, `-resume`, `-until`, `-release`, `-linux` and the two
contract checks `landing-queue`/`landing-baseline` - and every graph and feature row passes, mine included.
Five checks were red, and **all five are red on main itself with the same binary**, measured here:

| check | on this branch | on main `c618da4f` |
|---|---|---|
| `scripts/test-edit-aliases.lua` | `:37: an unknown option is refused by name: {"error":"unsupported_edit_option"...` | the same line, the same error |
| `rust wa-capabilities` (`host::tls_anchor_tests::a_provider_call_refuses_a_private_ca_that_no_bundle_names`) | 400 passed, 1 failed | the same test fails (and on the base `4ba1c3d9` too) |
| `tui-chrome-pty` | `a click on the icon cell reports Copied N characters...` | the same |
| `run-block-pty` | `the interactive half FAILED - timed out waiting for the run to settle` | the same |
| `esc-stops-pty` | `bash: Esc brings the prompt back at once (300 ms idle, 120 ms per unit of load, never over 2000)` | the same |

The last three are the pty rows, and they failed **sequentially, one at a time**, on both trees while this
machine carried `main-health`'s full suite: load average 14.3 on 16 cores during the branch run and 28.3
during the main run. So the branch is as green as main is on this machine, and these five are named rather
than quietly inherited.

**A second merge, and two of the five reds went away with it (merge `f057e138`, main `4425f670`).** Main moved
again while this round was being read: `change/esc-stops-now` and `change/tool-args-honest-and-same-on-peers`
landed, and they fix exactly two of the rows named above - `scripts/test-edit-aliases.lua` (the handler takes
its aliases back) and the `esc-stops-pty` measurement (the row now reports what its own probing costs). That
merge was clean, with no conflict at all: this branch's seam in `lua/core/tools.lua` and main's are in
different places, and the graph's five gate call sites are unchanged (`rg -c graph_offered lua/core/tools.lua`
= 5).

## 10. The G blocker: the deploy's proof must not depend on an optional feature

The landing of `ad3fb3c5` made every install refuse:

```
component: lua error: [...]/scripts/check-graph-component.lua:16: graph_index: graph_dormant
deploy: refused(component_proof_failed): the candidate binary did not answer a graph call through the staged
component; nothing installed
```

The deploy proved the staged `graph` component on the candidate binary before installing anything (step 3e,
`scripts/check-graph-component.lua`), and with the graph off by default that proof answered `graph_dormant`
before the component was touched. My first repair set `WA_GRAPH_COMPONENT=1` for the proof - and Fable's
steer ruled exactly that out: **a deploy proof must not depend on an optional feature at all**. The final
shape, on `change/deploy-component-proof`:

* `scripts/check-component-proof.lua` (new, and the deploy now runs it instead of the graph proof) proves two
  properties, with no feature switch anywhere:
  1. **the candidate binary answers a call through a staged component** - through `memory`, and not by taste:
     its feature is on by default on every node (`rust/wa-features` FEATURES, `default_enabled: true`),
     `components.lock` pins it for every install kind (the deploy stages exactly `wa_components_shipped`),
     and its seam is one capability call with a JSON answer, so it needs no runtime assets, no model and no
     network. (`codemode` is default-on too, but proving it means proving a JS guest *and* its assets - a
     second subject for one question.) The call goes through `lua/core/memory.lua`'s own seam, so a staged
     set that is missing, unpinned or built for another engine falls back to the native path and the proof
     refuses instead of passing;
  2. **a dormant feature refuses BY NAME** - the graph is off by default, and the proof asserts
     `graph_dormant` with `effect: none` (and the `next` that names the switch) comes back from THIS binary.
     That is the state every node ships in; the enabled branch of the same check answers instead, so the
     proof does not depend on the graph being dormant either way.
* `scripts/deploy.sh`: `WA_GRAPH_COMPONENT` is gone from the proof, `WA_SCRIPT` points at the new proof, and
  the two refusals and the success line now name a *call through a staged component* and the dormant refusal
  rather than a graph call.
* `scripts/check-graph-component.lua` stays in the tree and stays shipped, and is **no longer part of the
  deploy**: what it adds is the graph component's own answers (index -> query -> explain -> status), which a
  broken `graph.wasm` would otherwise only fail in the gate's graph rows. It cannot be switch-free, so it
  runs only where a node uses the graph: `scripts/test-deploy-component-proof.lua`'s last direction.

`scripts/test-deploy-component-proof.lua` (renamed from `test-deploy-graph-proof.lua`, 21 checks, wired in
`scripts/test.sh` and picked up by the fast path) holds all four directions in its own scratch homes with its
own staged copies: **passes with the graph dormant** (the deploy's own invocation) and **passes with it
enabled** (a policy file in the proof's home), **fails when the staged component's bytes are not its pin**,
and **the dormant refusal is by name** (`graph_dormant` asserted on the output, not inferred from an exit
code). Its first version passed a proof that never ran - `env -u WA_GRAPH_COMPONENT ... true` ran `true` -
which is the same class of mistake the proof exists to prevent, and why the row asserts the verdict text as
well as the exit code.

Measured, the deploy's proof line run verbatim (no switch, staged components, fresh home):

```
component proof ok: memory answered through the staged component (bf469e8ce4af), and the dormant graph
refused by name (graph_dormant, effect none) from this binary
exit 0
```
