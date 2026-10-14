# Layered system prompt

The operator requested an inspectable generic foundation with the current stack,
workflow and session data injected separately. This is a format/architecture change,
not a JavaScript code mode or a claim of Pi-quality parity.

## Reused foundation

`lua/core/prompt_sections.lua` is a Lua adaptation of Pi1.2's ordered section renderer
and section-diff algorithm (`buildSystemPromptSections` and
`diffSystemPromptSections`, upstream b9ab2a6238d2). The original MIT notice is retained
in the module (and therefore the embedded binary) and `licenses/pi-MIT.txt`.
It has no memory loading, event hooks, tool execution or permission authority.

`agent.system_sections` supplies native content; `agent.system_prompt` renders it.
The generic renderer knows neither Git deployment nor the current workflow. Its diff
is available for diagnostics; provider serialization still renders the system text,
not a new incremental provider protocol.

## Order and ownership

- `<generic>`: identity, style, language and explicit-memory protocol.
- `<stack name="wasm-agent">`: Sentinel-notice safety, tool protocol, capability-aware
  guidelines and shared skill-use policy. Optional metadata remains discovered in
  progressive mode; full-mode metadata stays compatible.
- `<workflow source="...">`: the role-scoped execution file, inside
  `<orchestration mode="off|on">`. The actual session selector supplies the mode.
- `<project source="...">`: complete role-appropriate project instructions, retaining
  the existing `<project_instructions path="...">` frame.
- `<session>`: environment, `<role name="..."/>`, `<workdir path="..."/>`.

Existing checkpoint summaries and unanswered-turn recovery notices get an explicit
`<onSessionStart_injection source="session.summary|resume_notice">` frame in their
existing separate context messages. This does not add a session-start hook,
automatic memory retrieval, new scheduler or recurrent wake. Empty sections vanish.
Attributes are escaped; instruction bodies remain complete. Markup is an inspection
boundary, not a security boundary or a general XML document: native role/profile/
workspace/effect checks remain authoritative. External web/tool data remains data.
Guests never gain an operator workflow or fall back to operator AGENTS.md. Child
profile declarations and mandatory child system-boundary construction stay separate.
AGENTS.md remains10,389 bytes, delta0.

## Main-loop tools

The new-session progressive bootstrap is now eleven: remember, recall, skill,
tool_search, tool_call, read, read_many, write, edit, bash, session_worktree.
The operator explicitly selected read_many as a main-loop capability. It needs no
discovery round. Capabilities and tool_result remain discoverable. Existing full
sessions keep their full catalogue; bootstrap classic restores thirteen.

Tagged structure and restoring read_many may increase initial bytes. Do not call
that a saving. Measure actual system/schema sections and complete task paths;
serialized bytes are not billed tokens/cache hits or autonomous model-quality proof.
Current native captures and focused source/embedded checks are recorded under the
session's fresh layered-web proof generation. Earlier envelope measurements remain
immutable historical evidence rather than being rewritten to describe this code.

## Verification

`node scripts/test-layered-web.cjs <built-wa> <fresh-evidence> <baseline-wa>`, then
`--post`, captures before/after systems/declarations and proves section order/diffs,
policy and guest/profile boundaries, no memory injection, immediate read_many, and
native source/embedded web handoff/pending reconstruction through actual MCP/SQLite.
The upstream HTTP in this proof is labelled fixture data, not a live CAPTCHA solve.
Also run the existing envelope, full skill-body, read-batch/native reconstruction,
MCP no-replay, batching and subscription socket tests. Only a supported Sentinel
installation and fresh exact-source verifier establish live promotion.
