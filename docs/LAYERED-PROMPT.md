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

<!-- generated:prompt-layers (scripts/sync-prompt-docs.lua) -->
- `<generic>`: `identity`, `work`, `style`, `language`, `time`, `memory`
- `<stack>`: `safety`, `tools`, `guidelines`, `skills`
- `<workflow>`: `orchestration`
- `<project>`: `project_instructions`
- `<session>`: `environment`, `role`, `workdir`, `keys`
<!-- /generated -->

- `<generic>`: who the agent is and how it works (identity, completion and verification, style,
  language, time, the on-demand memory protocol). `work` also carries the three long-work rules -
  supervised operations instead of a background shell command, the cheapest check that can fail first,
  and asking when a step keeps failing - because they belong to a *rule* the prompt states once rather
  than a procedure loaded on demand ([AGENT-LOOP.md](AGENT-LOOP.md), `skills/wasm-agent-dev`). A tool is
  named only in a form the envelope can
  call: declared as `name`, otherwise `tool_call(name="...")`, otherwise not at all
  (`scripts/test-prompt-tool-names.lua`).
- `<stack name="wasm-agent">`: the Sentinel-notice rule, the tool protocol (in progressive mode
  the generated on-demand index), capability-aware guidelines and the skill-use rule.
- `<workflow>`: `AGENTS.orchestrator.md`, inside `<orchestration mode="off|on">`. The file has one
  section per mode (`## Orchestration off` / `## Orchestration on`); only the active one is
  injected. A file without those headings is injected whole.
- `<project>`: pi-style project instructions, one `<project_instructions path="...">` frame per
  file: `<config>/AGENTS.md`, then every `AGENTS.md` from the filesystem root down to the
  session's workdir (its worktree when it has one), nearest last. `WASM_AGENT_AGENTS_MD` names one
  explicit file instead. Guests get `AGENTS.guest.md` only and never fall back to operator files.
- `<session>`: environment, `<role name="..."/>`, `<workdir path="..."/>` (the session worktree
  when one is bound) and the vault key names for a master.

Existing checkpoint summaries and unanswered-turn recovery notices get an explicit
`<onSessionStart_injection source="session.summary|resume_notice">` frame in their
existing separate context messages. There is no session-start hook, automatic memory
retrieval, scheduler or recurrent wake. Empty sections vanish. Attributes are escaped;
instruction bodies remain complete. Markup is an inspection boundary, not a security
boundary: native role/profile/workspace/effect checks remain authoritative.

The rendered prompt is what the provider sees, and it is **frozen per session**: the first turn's
system text and declared tool list are recorded and every later request sends exactly those bytes,
so a mid-session change (an orchestration toggle, an installed skill, a policy reload, an
instruction edit, a new platform line) is delivered as an appended `[session update]` note rather
than as new prefix bytes. A section's change is still named in the guard's words (`orchestration`,
`skills`, `policy`, …). See [PROMPT-CACHE.md](PROMPT-CACHE.md).

## Main-loop tools

<!-- generated:bootstrap-tools (scripts/sync-prompt-docs.lua) -->
New operator sessions declare 14 tools from the start (`lean`, the default): `bash`, `edit`, `read`, `read_many`, `recall`, `remember`, `session_worktree`, `skill`, `time`, `tool_call`, `tool_search`, `web_read`, `web_search`, `write`.
`codemode` is also declared when code mode is admitted for the run. Orchestration mode adds `route_task`, `subagent`.
`WASM_AGENT_BOOTSTRAP_MODE=classic` adds `capabilities`, `tool_result` (16 in all).
Every other permitted tool is called on demand with `tool_call`; the system prompt lists it with its cue.
<!-- /generated -->

Tagged structure costs bytes; measure actual system/schema sections and complete task paths
rather than calling a smaller prefix a saving. Serialized bytes are not billed tokens, cache hits
or model quality.

## Verification

`node scripts/test-layered-web.cjs <built-wa> <fresh-evidence> <baseline-wa>`, then
`--post`, captures before/after systems/declarations and proves section order/diffs,
policy and guest/profile boundaries, no memory injection, immediate read_many, and
native source/embedded web handoff/pending reconstruction through actual MCP/SQLite.
The upstream HTTP in this proof is labelled fixture data, not a live CAPTCHA solve.
Also run the existing envelope, full skill-body, read-batch/native reconstruction,
MCP no-replay, batching and subscription socket tests. Only a supported Sentinel
installation and fresh exact-source verifier establish live promotion.
