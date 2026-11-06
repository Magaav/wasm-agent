# The prompt prefix is frozen for a session

A provider's prompt cache matches from the **first byte** of the request: the declared tool list and
the system prompt. Rewriting either one mid-session makes the provider re-read the whole conversation
at full price. The rule (Victor, 07/11): *we should not allow never the cache to break.*

Known breakers, before this rule: toggling orchestration mode added `subagent`/`route_task` to the
declared tools (`envelope.lua`, `ORCHESTRATION_FIRST_CLASS`) and flipped the orchestration section of
the system prompt (`agent.lua`, `workflow_for_mode`); a skill installed or an instruction file edited
changed the skills/instructions blocks; a policy reload (`WASM_AGENT_GUIDELINES`,
`WASM_AGENT_CODEMODE`, `WASM_AGENT_TOOL_SNIPPETS`), a new platform/time-zone line, or a node update
changed the environment and guideline text.

## The rule

`lua/core/prompt_cache.lua` is the whole mechanism.

1. **First turn freezes.** On the first request of a session the built system prompt and the declared
   tool list are recorded in `meta` under `prompt-cache.v1:<sha256(session,user,role)>`, with the exact
   bytes and a `sha256` of each. The record lives in the ledger, not in module state, so a restart, a
   new pooled interpreter or a node update keeps sending the same bytes.
2. **Every later request sends those bytes.** `agent.build_context` applies the record after building
   the prompt: the frozen system text and the frozen tool list replace the current ones. The tool list
   is the frozen one for the rest of the request too, so argument parsing, context estimates and the
   `round` event describe what was actually sent.
3. **A change is delivered as an appended note.** When the current build differs, the difference is
   classified (`orchestration`, `skills`, `tools`, `policy`, `instructions`, `platform`, `keys`,
   `prompt`) and delivered **once** as a durable user-role row at the end of the conversation:

   ```
   [session update] Automated node state, not a message from the reader and not a new task. …
   - Orchestration mode is now ON for this conversation. …
   ```

   The row is written to the transcript, so it is where it was appended from then on, it survives a
   restart, and the next request carries it in its natural position. Nothing is repeated: the record's
   `noted` marker names the state the model was last told about.
4. **The guard.** Before every provider call of the run loop the request's system-prompt hash and tool
   list hash are compared with the frozen ones. A mismatch is a *bug in this process*, not a policy
   change: the frozen bytes are sent anyway (fail safe), the fact is logged as
   `prefix_changed reason=<what>` in the harness ledger, counted in the run's `run_counts`
   (`prefix_changes`) and shown as a status line. A policy change never arrives by this path.

## Orchestration mode, toggled mid-session

Toggling does not touch the prefix. The mode's instructions stay frozen, so the mode change is
delivered as a note that says the mode is now on (or off) and what that means for this turn. On: the
`subagent` and `route_task` **definitions travel in the note** and are pinned into the session's
envelope loadout, exactly as a `tool_search` hit would pin them (`envelope.pin`), so
`tool_call(name="route_task", …)` and `tool_call(name="subagent", …)` work without a search and still
re-check authority at dispatch. A session that *starts* in orchestration mode declares both up front,
as before.

Toggling off again returns the request to the exact frozen bytes (the mode-off build is the one the
session froze), so it does not report a changed prefix - it still owes a note, because the last note
told the model the mode was on.

## What this does not do

- Compaction still rewrites the conversation prefix (a new summary system message and a shorter
  window). That is a measured, deliberate cost (`docs/CONTEXT-COMPACTION.md`), not a cache defect, and
  it is not suppressed. The frozen prefix is the *instructions and tool list*.
- The note names the change and how to see the current state; it does not re-send whole sections
  (an edited `AGENTS.md`, a new skills listing). The transcript is the source of truth and the tools
  (`read`, `skill(query="*")`, `capabilities`, `tool_search`) read the current state.
- A frozen tool list is not a grant. Permission, workspace binding and effect class are rechecked at
  every call, and a tool the node no longer offers fails visibly with `tool_not_available`.

## Where the record is read

- `agent.build_context` - freeze, apply, and deliver the owed note.
- `agent` run loop - the guard before `provider.complete_with`.
- A child session freezes its own prefix; the summary call a compaction makes carries its own fixed
  prompt and is not a session prefix.

## Proof

`scripts/test-prompt-cache.lua` (in the fast path) drives the real agent loop through a mock provider
that captures the raw request bodies: a scripted session with a `tool_search` load, orchestration
off/on/off/on, a memory write, an instruction edit, a policy reload and a platform change, plus a
full-envelope session where a skill is installed mid-session. It asserts that every request carries
the session's first system-prompt and tool-list bytes, that the message list only grows (an
append-only chain), that each change is one appended `[session update]` note in both the request and
the transcript, that the mode tools are pinned and callable without discovery, and that a fresh
session starts in the new state. It also covers the guard directly: a drifted system prompt or tool
list is repaired to the frozen bytes and reported.

Run it alone:

```
WASM_AGENT_LUA_ROOT=<checkout> WA_SCRIPT=scripts/test-prompt-cache.lua wa --db /tmp/x.db
```
