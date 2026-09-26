# Skills

A skill is a procedure the agent loads on demand: a directory with a `SKILL.md`,
plus whatever scripts, references or assets it needs. This follows the
[Agent Skills standard](https://agentskills.io/specification) that pi implements,
so the same skill directory works in either harness — including the shared
`~/.agents/skills` that Orca already populates.

```md
---
name: see-your-output
description: How to verify work whose result is visual. Use before claiming a UI change works.
---

# Seeing your own output
…instructions…
```

## Why on demand

Only the `name` and `description` of each skill sit in the system prompt, inside
an `<available_skills>` block; the body loads only when a task matches. That is
progressive disclosure, and it is the point: a technique needed occasionally must
not cost context every turn, and must not have to be explained twice. The model
loads one with the `skill` tool (`wa skills` lists them from the CLI).

## Where they are found

Scanned in order, first match per name wins:

| Scope | Location |
| --- | --- |
| explicit | `$WASM_AGENT_SKILLS` (paths separated by `;` or `:`) |
| global | `~/.wasm-agent/skills`, `~/.agents/skills` |
| project | `<dir>/skills`, `<dir>/.agents/skills` for the working directory and each ancestor |

Directories are scanned recursively for `SKILL.md`, skipping `.git`,
`node_modules`, `target` and `.wasm-agent`. A `SKILL.md` without a non-empty
`name` and `description` is ignored rather than half-loaded.

## Frontmatter

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | lowercase a-z, 0-9, hyphens |
| `description` | yes | what it does **and when to use it** — this is the only part always in context, so it carries the trigger |
| `disable-model-invocation` | no | `true` keeps it out of the prompt (the human loads it by name) |

## Writing one that works

- Put the **trigger** in the description ("use before claiming a UI change
  works"), not the summary — that is what decides whether it gets loaded.
- Write it as instructions to follow, not documentation to read; the agent acts
  on it directly.
- Reference other files by relative path, because the loader resolves them
  against the skill directory.
- Keep it short. A skill that is not read is worthless, and a long one does not
  get read.
- Add a test to `scripts/test.sh` when the skill encodes something the repo
  depends on. There is one for discovery, the prompt block and loading.

## Evolve the procedure while using it

When executing any skill, identify segments with repeatable inputs, deterministic
steps and observable success. Work out the sequence, parameterize changing values,
save it with `spell_save`, execute it and verify its mandatory `post`. Refactor the
editable skill to point to that spell, its inputs, and its fallback. Keep the original
inference procedure available until the replacement is proven. Stay within the current
task's authorization and tool/file scope; do not install or edit someone else's skill.

If spell A succeeds in one turn and spell B follows in the next, crystallize their
verified sequence with `spell_compose` when it will recur. Preserve A's postconditions,
B's preconditions, step retry limits and final settlement. Parameter bindings and the
decision to run B must be deterministic; any intervening judgment stays outside the
composition. Test the combined spell before making it the skill's preferred path.
Composition snapshots source versions; after a source repair, rebuild and reverify
affected compositions instead of assuming they inherited the fix.

**Failure recovery always starts with inference.** Inspect the failing step and trace,
reconcile effects already performed, then decide whether to finish the remaining work
manually, repair/refactor and reverify the segment, or retire it with `spell_forget` and
restore inference in the skill. A valid refusal (dirty work, failed tests, missing
preconditions) means fix the work state, not the spell. Never weaken a check to obtain
success or replay a non-idempotent effect blindly. If the segment inherently requires
judgment, remove its spell preference and record why it stays inference-driven.

The built-in skill prompt carries this rule for every loaded skill; `AGENTS.md` carries
it for external repo agents. The reusable closing example is `parallel-evolution`.

## Security

A skill can instruct the model to do anything its tools allow, and can ship code
the model then runs. Review skills before adding a directory of them, and
remember that a guest reading a skill still cannot act beyond its own tool
envelope.

## Skills that ship with the node

A skill is only knowledge if it is *installed*. `skills/` in this repo is the source, and both
installers copy it into `<install>/skills` — the node-scoped location `skills.lua` scans
(`paths.config() .. "/skills"`). A skill that is not shipped is a procedure a fresh node has to
rediscover at cost, which is exactly what happened with self-update: an agent that cannot restart
itself, no built-in knowledge of the sentinel, and nine failed upgrade attempts to work it out.

| skill | why it is a skill and not a paragraph in `AGENTS.md` |
| --- | --- |
| `self-update` | the procedure is long (the command, the whitelist, the deadlock, the recovery) and needed rarely. The description is written to match the *moment* — "use it whenever a change requires restarting or replacing this node" — so it is loaded when it matters and costs nothing when it does not. |

### The economics, measured

| | cost |
| --- | --- |
| the whole `<available_skills>` block in every prompt | ~3,930 chars (≈980 tokens) for all 5 skills |
| `self-update`'s own body | 4,894 chars (≈1,220 tokens) — **zero** until loaded |
| `AGENTS.md` (the alternative, injected every turn) | 13,924 chars (≈3,480 tokens) |

So the body is free until used, and even the always-present block is a quarter of `AGENTS.md`. A
skill is the right home for a procedure; `AGENTS.md` is the right home for a *rule*.

**The one thing a skill cannot cover:** it is only found if the scan sees it. If the installer does
not ship it, the agent is blind to it — which is why shipping is part of the skill, not a follow-up.
