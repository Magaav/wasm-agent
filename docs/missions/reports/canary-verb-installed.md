# canary-verb-installed - the canary verb works from the installed build

Branch `change/canary-verb-installed` from `origin/main` = `53bb69b1`, worktree
`/home/victor/Work/missions/deploy-hold-r8a4/canary-verb`. Built and tested HERE on avell (x86_64, 16
cores) with `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-canary-verb`. Committed locally, **never
pushed**.

## What was measured before any code was written (Fable 24/11, G)

On this laptop's INSTALLED build (`wa --version` -> `wasm-agent v0.1.2 · v53bb69b1`, lua tree
`/home/victor/.local/bin/lua-core`, 212 files):

| command | answer before the fix |
| --- | --- |
| `wa features canary self-wake` | the feature TABLE, no verdict line, exit **3** |
| `wa features canary json` | the feature TABLE (the release step parses JSON from this) |
| `wa --db <scratch>/t.db features canary self-wake` | `canaries: 1 passed ... self-wake PASS delivered` - i.e. the verb worked only when `features` was NOT the first argument |
| the same, from a directory that is not a checkout | every loopback canary died: `read lua/core/canaries/tasks/chat-turn.lua: No such file or directory` |

Three separate defects, all on main, all in the path the release step uses:

1. **The Rust fast path swallowed every verb.** `rust/wa-host/src/main.rs` answered `features` before the
   interpreter booted and printed the table for anything that was not `--json`. The verbs are the Lua
   core's (`lua/core/features_cli.lua`), so they never ran.
2. **A canary's child could not read its task file on an installed node.** `WA_SCRIPT` was read with
   `std::fs::read_to_string` only (`main.rs`), and a loopback canary passes
   `WA_SCRIPT=lua/core/canaries/tasks/<name>.lua` - a path inside the Lua tree, which on an installed
   node lives in the binary (or in `lua-core/`) and nowhere on disk. Every loopback canary panicked.
3. The registry itself was fine: `scripts/deploy.sh` step 6b installs `config/features/features.json` to
   `<home>/.wasm-agent/features.json`, which is exactly `feature_health.installed_registry_path()`
   (`lua/core/feature_health.lua:116`). Measured present on this node (4312 bytes, 10:43). A scratch home
   needs the same copy, which is what the row below installs.

## The fix

* `rust/wa-host/src/main.rs` - the `features` fast path now answers ONLY the shapes it implements:
  `let features_verb = args.iter().skip(1).any(|arg| !arg.starts_with('-'));` and the block runs only when
  that is false. `wa features` and `wa features --json` keep their pre-interpreter answer (the property
  that makes them safe on a node whose core will not start); `wa features canary …`, `wa features json`,
  `wa features <anything>` fall through to the interpreter, where the verbs live. An unknown verb gets the
  Lua usage text instead of the table.
* `rust/wa-host/src/main.rs` - `WA_SCRIPT` is read from disk when it is there (so a test editing `lua/`
  still runs its edit) and otherwise, when the name is a `lua/…*.lua` tree name
  (`is_lua_tree_name`), from the tree this binary carries (`core_source`: the installed `lua-core/` tree,
  else the compiled-in modules). A name that is in neither still panics, saying which path.

## Item 3: the release step's canary list and its rollback - verified, no change needed

* The list is the registry: `lua/core/feature_canary.lua` `run_all` walks `config/features/features.json`,
  and `self-wake` is a row there with `"role": "any"` (so `feature_health.applies` always says yes) and a
  canary module that exists (`lua/core/canaries/self-wake.lua`). `scripts/check-features-registry.mjs`
  refuses a tree where self-wake is missing.
* Rollback on FAIL exists and is asserted: `lua/core/land.lua` `impl.canaries` returns
  `error = "canary_failed"` with a per-node `next` built by `rollback_line` (the previous release's tag and
  commit, never this run's), and `scripts/test-land-canary-step.lua:149-155` pins exactly that
  ("the rollback names the previous release's commit for that node", "does NOT name the commit this run
  shipped"). That row is green on this branch.
* What was MISSING for self-wake's canary to protect the fleet was the command the release step asks each
  node - `wa features canary json` (`lua/core/land.lua:4179`, parsed by `canary_answer`) - which no installed
  node could answer. That is defect 1+2 above, and the row below proves the answer.

## Item 2: the row, through the installed CLI path

`scripts/test-features-canary-installed.sh` (new; wired into `scripts/fast.sh` beside
`check features-registry`), and it is deliberately NOT a tree run:

* `WA_BIN` must be an installed-style binary; the row runs it with **no `--db`** (a `--db` made the old
  binary work by accident, because then `features` is not the first argument) and with
  `WASM_AGENT_LUA_ROOT` unset, so the Lua comes from the binary or its `lua-core/` tree.
* It runs from a scratch directory that is **not** a checkout, installs the registry the way the deploy
  does (`install -m 0644 config/features/features.json <home>/.wasm-agent/features.json`), and fences off
  the vault and provider variables.
* Assertions: `wa features canary self-wake` exits 0, prints `self-wake PASS`, and prints the
  `canaries: N passed` summary; then `wa features canary json` must parse (as JSON, not as the table), carry
  a `features` array, and contain a self-wake row with `ok: true` and a named stage - the exact shape
  `canary_answer` parses. The JSON run's EXIT CODE is not required to be zero: it runs every feature, and a
  bare scratch node honestly cannot prove run-blocks (no effect file), release-update (no install record) or
  the WhatsApp rows (no component) - that is the node's verdict, and the row says so in its own comment.

Red and green, same row, same command:

```
WA_BIN=/home/victor/.local/bin/wa                                 (installed 53bb69b1, unfixed)
  FAIL canary-verb: 'wa features canary self-wake' answered exit 3 on an installed-style build
  row exit=1

WA_BIN=/home/victor/wasm-agent/target/m-canary-verb/release/wa    (this branch)
  canaries: 1 passed, 0 failed, 0 off, 0 off-node
    self-wake              PASS  delivered
  canary-verb ok (installed build: 'self-wake PASS', json ok stage=delivered)
  row exit=0
```

## The four `features` shapes after the fix (measured, one scratch home)

```
features (no verb)   -> the table                        (Rust fast path, unchanged)
features --json      -> {"features":[{...}]}              (Rust fast path, unchanged)
features json        -> the Lua core answers it           (feature-health report; asks the registry)
features <unknown>   -> "wa features canary [name] ..."   (Lua usage, not the table)
```

## Rows run here, in scratch homes, this tree's binary

| row | result |
| --- | --- |
| `scripts/test-features-canary-installed.sh` (new) | RED on the installed 53bb69b1 (`exit 3`), GREEN here (`canary-verb ok ... json ok stage=delivered`) |
| `scripts/test-feature-canary.lua` | `feature-canary ok (62 checks)` |
| `scripts/test-features-gate.lua` | `features gate: 41 checks passed` |
| `scripts/test-features-defaults.lua` | `features defaults: 65 checks passed` |
| `scripts/test-land-canary-step.lua` | `land-canary-step ok (49 checks)` |
| `scripts/test-selfloop-no-starve.lua` (main's, as a `WA_SCRIPT`-path regression) | `selfloop no-starve ok: 174 checks` |

## Unknowns, stated

* The full fast path was not run for this branch (the row is a check row and the touched code is two
  hunks in one file); the rows above are the ones that exercise `WA_SCRIPT`, the canary runner, the feature
  resolver and the release canary step.
* The release step itself was not run (it deploys a ring). Its per-node command was run, by hand, on this
  machine's installed binary - that is the half that was broken.
* `wa features json` (the verb) now answers from Lua, where before it answered the Rust table by accident.
  `docs/FEATURES.md` documents both shapes; no caller in the tree used the verb form
  (`scripts/test-deploy-components-shipped.sh:222` uses `features --json`, which is unchanged).
