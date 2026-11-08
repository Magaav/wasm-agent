# The agent loop: long work, and when to stop and ask

The 08/11 incident: asked to move an update notice, an agent spent 248 steps and 40 minutes on a
2-core container — it rebuilt the whole Rust workspace (one `cargo test` on two cores is fifteen
minutes), started `cargo build &` inside a `bash` call (killed by that call's containment cleanup when
it returned), and then polled a log that would never finish. Nothing in the prompt said how work is
run here, what to verify first, or when to stop and ask. This is what now says it.

## The three rules, in the frozen prefix

They live once, in the `<generic>` layer's `work` section (`lua/core/agent.lua`, `generic_sections`),
which is part of the session's frozen prompt prefix: they cost their bytes on the first request of a
session and nothing afterwards (`docs/PROMPT-CACHE.md`). They are rendered from the tool catalogue, so
a name is only mentioned in a form the envelope can actually call (`scripts/test-prompt-tool-names.lua`).

1. **Long work goes in an operation.** A build, a test suite or a migration is an `operation` you
   start, read and cancel — never a background `&` shell call, whose process dies with the call that
   started it and whose log the next `bash` call cannot see.
2. **Verify with the cheapest check that can fail first**, before a whole suite or a rebuild, and say
   what you ran and what you could not.
3. **When a step fails the same way twice, or the work is blocked, say what is blocking it and ask**,
   instead of repeating the call.

The procedure behind rule 1 — which change needs no rebuild, which test covers which area, and how to
hand a Rust change back instead of compiling it on a weak node — is the `wasm-agent-dev` skill
(`skills/wasm-agent-dev/SKILL.md`), loaded on demand rather than paid for in every prompt
(`docs/SKILLS.md`).

Focused checks: `scripts/test-prompt-tool-names.lua` (every role and envelope can reach every
name the rules mention), `scripts/test-prompt-cache.lua` and `scripts/test-prefix-stability.lua`
(the prefix stays frozen), and `scripts/test-skill-wasm-agent-dev.lua` (the skill behind rule 1
still agrees with the tree).
