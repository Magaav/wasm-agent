# Spells — deterministic, verified automation

A **spell** is a named, parameterised sequence of **deterministic** steps with
declared preconditions and mandatory postconditions. A step is any deterministic
execution - a shell command or script, a client action, a wait, an assertion, or a
supervisor verb - and the agent *crystallizes* a task into a spell once it has
worked it out, then replays it later **without the model in the loop**. A macro is
one shape a spell can take, not what a spell is.

> **Naming.** "Spells" always means these deterministic, verified executions. The tool that
> lists what an account may call is **`capabilities`**, never `spells`. The two
> used to share the name, which was a defect: it made the envelope read
> `capabilities → spells` and `spells → spell_save`, two different things under
> one word.

This document is the contract. It exists because the old v8 orchestrator failed
in ways we are not repeating.

## Why — the v8 failure modes, and the rule that prevents each

| v8 failure | Rule in `spells.lua` |
| --- | --- |
| A "repair" reported success while doing nothing | **`post` is required.** A spell only succeeds when its postconditions are *observed* after the steps (`settled: true`). |
| Tools acted on a world that had moved on | Optional **`pre`** conditions fail fast before any step runs. |
| Hardcoded values that broke on the next run | **`params`** with types + defaults; steps reference `{{name}}`; unknown/missing params are errors. |
| Blind retries that doubled an effect | Retries are **only allowed on steps marked `idempotent: true`**; otherwise `spell_save` rejects the spell. |
| Silent partial failures | **First failure stops the run** with a typed error, the failing index and a trace. |
| No evidence of what happened | Every run returns a **trace** with per-step timing, attempt count and observed values. |
| Drift between recording and replay | Spells are **versioned** (each save bumps `version`) and record their `target` (node/app/profile). |

## Contract

```json
{
  "name": "invoice-first-row",
  "description": "Open the newest invoice",
  "target": { "node": "client", "app": "chrome", "profile": "AgentBrowserChromeProfile" },
  "params": {
    "folder": { "type": "string", "default": "Invoices" },
    "row":    { "type": "number", "default": 1 }
  },
  "pre":   [ { "script": "location.hostname", "equals": "mail.colmeio.com" } ],
  "steps": [
    { "kind": "client", "action": "click", "x": 40, "y": 120, "idempotent": true, "retries": 1 },
    { "kind": "wait",   "ms": 400 },
    { "kind": "assert", "script": "document.querySelectorAll('.read').length", "gt": 0 }
  ],
  "post":  [ { "script": "document.title", "contains": "{{folder}}" } ]
}
```

Required: `name`, `steps`, `post`. `params`, `pre`, `target`, `description`
are optional.

### Step kinds

| Kind | Shape | Notes |
| --- | --- | --- |
| `client` | `{action, ...}` where action ∈ `click move type key shell cdp frame` | `retries` needs `idempotent: true` |
| `run` | `{script, expect?, timeout_seconds?}` | a node-side deterministic command; success is settled execution, exit 0 **and** a JSON object on stdout, and `expect` compares named fields of it. Timeout is 1–86400 seconds. Never exportable as a sentinel plan (see below) |
| `wait` | `{ms}` | bounded to 10s by `host.sleep` |
| `assert` | `{script, <operator>}` | mid-run checkpoint |
| `sentinel` | `{verb, binary?}` | a plan for the supervisor, executed outside the node |

### Deterministic, or it is not a spell

A spell may not contain inference. The moment a step calls a model the plan is a `wake`/`subagent`, and
it has lost the two properties that make a spell worth having: no model in the loop, and a replay with no
variance. A job's pipeline may mix deterministic and inference steps (`docs/PIPELINES.md`); a spell may
not. `spell_save` refuses a step that is not deterministic.

A `run` step executes in the node's worker, where a turn is already running - never in the process that
can restart this node. That boundary needs no new code: `M.export` refuses any step whose kind is not
`sentinel`, and `rust/wa-sentinel/src/spell.rs` refuses a plan containing one, so a step kind added today
cannot reach the supervisor tomorrow.

### Assertion operators

`equals`, `not_equals`, `contains`, `matches` (Lua pattern), `gt`, `lt`,
`truthy`. An assertion reads a value with CDP `Runtime.evaluate` and compares.
A failed assertion is an error, never a warning.

For node workflows, `pre`/`post` may use `{ "kind": "run", "script": "...",
"expect": { "ready": true } }`. These observational commands use the same JSON
contract as a run step; `expect` must be non-empty. They do not need a browser and
cannot be exported as sentinel checks. Step traces retain their observed JSON, and
an adopted/unsettled command is not successful spell evidence.

## Compose verified sequences

`spell_compose({name, parts:[{name, params?}, ...]})` saves one node-side spell from
two or more existing, verified spells with the same target. It snapshots their
steps and versions, preserves every intermediate pre/post check and each original
retry policy, and exposes parameters as `p1_name`, `p2_name`, etc. Supplied component
parameter values become defaults. The final source postconditions are observed
again at composite settlement. Trace `origin` identifies the source spell, version,
phase and index. `composed_from` records source versions in the saved spell.

Composition never inserts inference or retries the whole sequence. Decide with
inference whether the sequence and its bindings are repeatable; source changes do
not silently update a saved composition. Rebuild and verify it after source repair.
On failure, inspect the trace and reconcile effects before choosing manual completion,
repair/reverification or retirement. See [SKILLS.md](SKILLS.md).

### Results

Success: `{ ok, spell, version, params, settled: true, ms, trace }`
Failure: `{ error, step, detail, trace, spell, version, params }` where `error` ∈
`unknown_spell | invalid_spell:* | missing_param:* | unknown_param:* |
bad_param:* | precondition_failed | step_failed | postcondition_failed`.

## Recording guidance (for the agent)

1. Work the task interactively first.
2. Replace every literal that varies with a `{{param}}`.
3. Add a `post` assertion that is true **only if the task actually happened** —
   the goal state, not the last click.
4. Prefer `cdp evaluate` assertions over pixel or coordinate checks.
5. Mark a step `idempotent: true` only if running it twice is safe.
6. Save with `spell_save`. If an assertion later fails in the field, **re-record**
   the spell; do not silently patch coordinates.

## Security

Spells are arbitrary automation on a real machine, so `spell_save` / `spell_run`
are **master-only** tiers (`DESIGN.md §8`). A guest node can never save or run a
spell. Spells are stored locally at `~/.wasm-agent/nodes/<node_id>/spells.json`
(with the old flat file as a read fallback); nothing is
uploaded.

## Self-update — plans the sentinel must run

Some plans are *about the node itself*, and those cannot run on it. A spell is
executed by the node's Lua worker, which is one thread a turn occupies: a plan that
replaces the binary stops the worker, so the turn running it dies with the thing it
changed, and its `post` assertions — the effect settlement that makes a spell a spell —
never run. A plan that restarts its own host cannot satisfy its own contract.

The `sentinel` step kind exists for that:

```json
{
  "name": "self-update",
  "params": { "binary": { "type": "string" } },
  "steps": [
    { "kind": "sentinel", "verb": "wait-idle" },
    { "kind": "sentinel", "verb": "upgrade", "binary": "{{binary}}" }
  ],
  "post": [ { "script": "/health ok:true" } ]
}
```

`spell_run` on such a spell **refuses** with `needs_sentinel` — it does not skip the
steps, because skipping them would report success for a plan whose point never
happened. Instead:

```bash
# 1. from a turn, export the plan (resolved, portable JSON — no model, no node)
spell_export(name: "self-update", binary: "rust/target/release/wa")

# 2. ask the process that outlives the node to run it
wa-sentinel request spell --file <path from the export> --reason "picking up the build"
```

The sentinel executes the plan **outside** the node and settles it with its own
`/health` check — the assertion an in-turn agent cannot make about itself. The turn
that asked dies as `unfinished`; that is expected, and the request is already on disk.

### Why a JSON plan and not a WASM module

The plugin ABI is a *core module with no imports*: a guest gets `memory`, `alloc`,
`describe`, `call` and nothing else — no filesystem, no clock, nothing to ask with.
Such a module can compute a plan and hand it back; it cannot execute one step of it.
Packaging spells as modules would therefore **remove** capability, not add it, and put
a compiler on the upgrade path. A plan is a sequence, and a sequence is data.

### The whitelist

A plan file is written *by the agent*, so it is untrusted input to the sentinel. A
`sentinel` step therefore names a verb from a fixed list — `wait-idle`, `upgrade`,
`restart`, `wait-health` — and the sentinel refuses anything else before running a
single step. `run` (the operator's script escape hatch) is **not** in the list: a plan
that could reach it would be a shell, and `SENTINEL.md` requires that the thing which
can restart your agent must not be something your agent can talk into anything.

**A spell chooses which step, never how it runs.**

The list is enforced twice, deliberately: once at `spell_save` (so a bad spell is
refused where it is written) and once in `rust/wa-sentinel/src/spell.rs` (so a plan
edited on disk is still refused). `tests/spell-sentinel.lua` asserts they agree.
