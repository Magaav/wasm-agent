# Spells — deterministic, verified automation

A **spell** is a parameterised sequence of client actions with declared
preconditions and mandatory postconditions. The agent *crystallizes* a task into
a spell once it has worked it out, and replays it later **without the model in
the loop**.

> **Naming.** "Spells" always means these crystallized macros. The tool that
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
| `wait` | `{ms}` | bounded to 10s by `host.sleep` |
| `assert` | `{script, <operator>}` | mid-run checkpoint |

### Assertion operators

`equals`, `not_equals`, `contains`, `matches` (Lua pattern), `gt`, `lt`,
`truthy`. An assertion reads a value with CDP `Runtime.evaluate` and compares.
A failed assertion is an error, never a warning.

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
spell. Spells are stored locally at `~/.wasm-agent/spells.json`; nothing is
uploaded.
