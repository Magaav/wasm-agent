# Feature health: every shipped feature proves itself

Victor, 23/11, after finding WhatsApp transcription, the copilot reply and the auto indexer all broken for
days with nobody knowing: *"that should never happen anymore"*. This is the machinery that makes that
true, and the reason it did not exist is worth keeping: the release gate tests the TREE in a scratch home,
and the fleet read-back asks a node which COMMIT it runs. A feature that installs perfectly and then cannot
do its work answers PASS on both.

## The one list

`config/features/features.json` - one row per user-facing feature:

| field | what it is |
| --- | --- |
| `name` | the feature, in the words an operator uses (`whatsapp-copilot-reply`, not `posting.rs`) |
| `role` | `any`, or `component:<name>` for a feature that only a node running that component can exercise |
| `canary` | the module under `lua/core/canaries/` that proves it (see below) |
| `last_success` | where its last real success is recorded: a HOOK in the code path that does the work, a CANARY (named as such, where nothing records real traffic yet), or a `collector:` |
| `stale_after_s` | how old a success may get before the feature counts as stopped - per feature, never a global |

`node scripts/check-features-registry.mjs` (a fast-path contract check) refuses a row without a field, a
row whose canary file is not there, a `last_success` that names a file the tree does not have, and a feature
from the operator's 23/11 list that is missing entirely. That is what makes *a feature that ships without a
line in this list* fail a check instead of drifting.

## The verdicts (one vocabulary, five words)

| verdict | what it means |
| --- | --- |
| `working` | the last event succeeded and is inside the feature's bound |
| `stale` | the last event succeeded but is older than the bound |
| `failing` | the last event failed - its stage and time are named - and nothing newer has succeeded |
| `never` | nothing has ever been recorded for it on this node |
| `off-node` | this node does not run the feature at all (its component is not installed here) |

`never` is not `working` and `off-node` is not `failing`: the first is a feature nobody has proven works
on a node that should run it, the second is a fact about the node. Every renderer prints all five.

## Where you see it

* `wa features` - the whole table, one line per feature with `last worked: <time>`, exit 1 when anything
  has stopped. `wa features json` for a script, `wa features canary [name]` to run the exercises.
* `wa health` - after the node's own `/health` document, the same rows: `rust/wa-sentinel/src/feature_health.rs`
  renders the two files, so a node that will not start still answers which features last worked.
* `wa status` and the in-chat status page - a summary line, with the first stopped feature named.

## The canaries

A canary is a synthetic end-to-end exercise that touches nothing of the user's and answers pass or fail with
**the stage that failed**. `lua/core/feature_canary.lua` runs each module `lua/core/canaries/<canary>.lua`:

```lua
return { mode = "loopback"|"read", run = function(ctx) return ok, stage, detail end }
```

* **loopback** canaries exercise the feature in a CHILD node - this binary, its own scratch home, its own
  ledger (`lua/core/canaries/tasks/*.lua`). A turn, a run block, an undo, a self-wake and a slice of the
  jobs store are all proven that way; the model is stubbed at the host's stream boundary, so no provider
  is ever called.
* **read** canaries only read: the WhatsApp index, a component's own configuration, the install identity.

A canary that cannot run is not a pass: `canary_missing`, `canary_unloadable`, `canary_raised`,
`binary_unknown`, `spawn_failed` are each a named failure, because "unknown" rendered as "fine" is the bug.

## The release step

`wa release cut` runs `canaries` immediately after `deploy` (the fleet read-back). It runs them on THIS node
through `lua/core/feature_canary.lua` and asks every deployed node its own question,
`wa features canary json` (`lua/core/land.lua`, `ask_node`), which must therefore work from an
INSTALLED build - embedded modules, no checkout, no `--db` - not only from a tree (Fable 24/11,
change/canary-verb-installed; `scripts/test-features-canary-installed.sh` is the row that keeps it true). A failed canary stops the
run BY NAME - the feature, the stage, and the evidence file - and the step's `next` line carries the
rollback command for the commit the release installed, because a release that reverts a node on its own
word would hide the failure instead of reporting it. A docs-only round skips the step, saying nothing was
installed.

## The notice

`lua/core/feature_notice.lua` speaks ONCE per incident: the set of stopped features is the incident's
identity, a second call while that set is unchanged sends nothing, and a set that changes speaks again. The
node's log is always written; the operator's own channel is used when this node has one, and a send that
failed is never recorded as sent - the next call tries again.

## What is not here yet

* Hooks that record real traffic exist for nothing yet: `last_success` names the canary for six features
  (`scheduled-jobs`, `mail`, `whatsapp-*`, `release-update`) and a hook file for the rest, and the hooks
  themselves are the next item. The table therefore reflects **the canary's** success until then, which the
  rows say in words.
* `remote-calls` proves the addressing half (the roster answers, an unknown peer is refused by name). A
  two-node loopback needs a second serving process on a scratch port, which the canary runner cannot start
  from inside the node - the release step starting that peer is the next step.
* The six WhatsApp/mail canaries have never been exercised on a node that runs those components (this
  laptop has neither), so their first real run is on `openclaw`/the mail node.
