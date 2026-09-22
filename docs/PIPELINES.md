# Pipelines, spells and jobs — a proposal

**Status: proposal. None of this is implemented.** It records a design the operator asked for: a job
should be a *chain*, a spell should carry a node-side deterministic step, and the whole thing should be
shareable as a portable artifact. It also records the two boundaries that must not move while we do it.

Today's contracts are in `docs/JOBS.md` (a job is one trigger + one action), `docs/SPELLS.md` (a spell is
a parameterised chain of client actions with mandatory postconditions) and `docs/ARTIFACTS.md` (a portable
artifact is an intent with every machine binding replaced by a named slot).

## The shape

A job action becomes a **pipeline**: an ordered chain of steps, each of which is deterministic or an
inference step, with one construct for fan-out.

```json
{
  "id": "whatsapp-copilot",
  "name": "WhatsApp Copilot",
  "trigger": { "kind": "schedule", "every_seconds": 300 },
  "action": {
    "kind": "pipeline",
    "steps": [
      { "kind": "run",     "script": "<install>/scripts/whatsapp-ingest.sh", "returns": "events" },
      { "kind": "foreach", "from": "events", "key": "message_id", "max": 8,
        "step": { "kind": "subagent", "profile": "whatsapp-responder", "prompt": "..." } },
      { "kind": "run",     "script": "<install>/scripts/whatsapp-report.sh" }
    ]
  }
}
```

| step kind | is | notes |
| --- | --- | --- |
| `run` | deterministic | a script; success is exit 0 **and** a JSON object on stdout (the contract `run` already has) |
| `spell` | deterministic | a saved spell by name + params, run in the node's worker |
| `wake` / `subagent` | inference | unchanged; the only steps that may cost a model call |
| `foreach` | fan-out | one child per item, keyed by the item's stable id |
| `wait` / `assert` | glue | bounded sleep; an assertion is an error, never a warning |

This is the whole point of the design: **a step that can be decided without judgement must not cost a
token.** The chain makes that visible — deterministic → inference → deterministic — instead of hiding it
behind an event seam.

## What a spell gains: a `run` step

A spell today runs `client` (including `shell`), `wait` and `assert` steps, and its assertions read a
value with CDP `Runtime.evaluate` — page-shaped. A skill's deterministic half is often a *node-side*
script, so a spell gains:

```json
{ "kind": "run", "script": "{{script}}", "expect": { "status": "ok" }, "idempotent": true }
```

`expect` compares fields of the step's JSON result, exactly as the `run` action's contract is already
defined, so there is one outcome shape rather than two. That makes a spell the deterministic
half of a skill: prose for the judgement, a spell for the part that never needed a model.

## The two boundaries that must not move

1. **A spell must not contain inference.** The moment a "spell" calls a model it is a `wake`/`subagent`,
   and it has lost the two properties that make a spell worth having: no model in the loop, and replayable
   with no variance. A pipeline may mix both; a spell may not. `spell_save` refuses a step that is not
   deterministic.
2. **The sentinel's plan whitelist stays narrow.** `spell_export` → `wa-sentinel request spell` runs a
   plan *outside* the node, and its `sentinel` steps are limited to `wait-idle | upgrade | restart |
   wait-health`. `run` is deliberately absent: *"a plan that could reach it would be a shell, and the thing
   which can restart your agent must not be something your agent can talk into anything."* Once a spell can
   carry a `run` step, a spell that contains one must be **refused by the sentinel path** — otherwise this
   design builds the exact shell that rule exists to prevent. The node's worker may run it; the supervisor
   may not.

## Sharing it: artifacts already have the mechanism

`docs/ARTIFACTS.md` already slots out machine bindings and requires approval:

| installed field | artifact slot | kind |
| --- | --- | --- |
| `trigger.path` (file) | `trigger_path` | `file_directory` |
| `trigger.websocket_url` (cdp) | `page` | `cdp_page` |
| `action.script` (run) | `script` | `script_path` |
| `action.session` (wake/subagent) | kept as a logical name | — |

Import installs **disabled**, needs `--bindings` + `--approve`, refuses an unknown/future
`schema_version`, refuses credentials and page bindings in the export, and refuses a guest subagent
import outright. So the pipeline inherits all of that, with three additions:

1. **A spell travels inlined.** Spells are local (`~/.wasm-agent/spells.json`) and master-only, so a job
   referencing a spell by name would export as a dangling reference. The artifact must carry the spell's
   steps, `pre`, `post`, `params` and version, and install it on import.
2. **Its bindings become slots too.** A spell's client profile, page and script paths are machine
   bindings: the same slot treatment, or the artifact is not portable.
3. **`requirements` must tell the truth.** A spell that drives a machine adds `client: true`; one that
   needs elevation adds `elevation: true`. A guest must be refused a spell-bearing job for the same reason
   it is refused a subagent import: a profile name is not a principal binding.

## What the fan-out step must preserve

The `foreach` step replaces the event seam the copilot uses today, so it has to carry the three
guarantees that seam provides. Each has a test today; each needs one after:

| guarantee | today | in a pipeline |
| --- | --- | --- |
| no double wake for one item | `UNIQUE(job_id, revision, event_id)` | the item's `key` is the child's idempotency key; a re-run reconciles, never spawns twice |
| bounded work | the job queue's own bound | `max`, plus the subagent service's reserved capacity |
| stopping means stopping | a disabled/revised job cancels its running child | the revision is re-checked between steps and between children |
| an unknown outcome is never replayed | a timed-out child is `unknown` | unchanged: the step settles `unknown` and the pipeline stops there |

## Slices

1. **`run` step for spells** (+ `expect`, + the refusal of a non-deterministic step). Small, additive, and
   it is what makes a spell the deterministic half of a skill. `spell_save` / `spell_run` / tests.
2. **`pipeline` job action with `foreach`.** The job schema, the sentinel runner, the artifact export /
   import, and the four guarantees above with tests. This is the change that makes the copilot one job.
3. **The copilot migrated to it** — `whatsapp-ingest` + `whatsapp-message` become one `whatsapp-copilot`,
   with the reader printing its new eligible messages as JSON instead of a one-line report.

Slices 1 and 2 are independent; 3 depends on both. The existing two-job form keeps working throughout, so
nothing migrates by force.
