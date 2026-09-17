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

## Security

A skill can instruct the model to do anything its tools allow, and can ship code
the model then runs. Review skills before adding a directory of them, and
remember that a guest reading a skill still cannot act beyond its own tool
envelope.
