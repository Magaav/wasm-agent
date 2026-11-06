# Hooks: every point the node can be told about, and the one protocol they all speak

A hook is a **user-owned** command (or Lua function, or later a component) that the node runs at a
named boundary. It is not a tool, not a job, not an approval: it observes a fact the node already has,
and its answer can add context, refuse a call, or ask a run to continue. The engine is
`lua/core/hooks.lua`; this file is the contract.

Read [HOOK-EVENTS.md](HOOK-EVENTS.md) first if the question is *what events exist as jobs* versus
*what boundaries the harness can be hooked at*. Jobs remain the only management surface for installed
trigger/action definitions; a hook point is a boundary, and `/hooks` lists the ones that are active.

```
~/.wasm-agent/hooks.json          node config: hooks + mods
<project>/.wasm-agent/hooks.json  project config: hooks + mods
~/.claude/settings.json           Claude Code hooks, opt-in (hooks.claude_compat)
<project>/.claude/settings.json   Claude Code project hooks, same opt-in
```

Config is read in that order and hooks run in that order. A later hook cannot undo an earlier refusal:
**a deny wins over an allow**. `/hooks reload` rereads the files; `WASM_AGENT_HOOKS=off` disables the
engine entirely.

## The file

```json
{
  "hooks": {
    "claude_compat": true,
    "PreToolUse": [
      { "name": "no-prod-writes",
        "matcher": "bash|write|edit",
        "command": "~/.wasm-agent/hooks/guard.sh",
        "timeout_ms": 3000,
        "on_ask": "deny" },
      { "name": "log-reads", "matcher": "^read$", "command": "hook-log read" }
    ],
    "Stop": [ { "name": "continue", "command": "hook-stop" } ],
    "bus:session.message": [ { "name": "on-message", "command": "notify" } ],
    "bus:*": [ { "name": "everything", "command": "audit-topic" } ]
  },
  "mods": {
    "statusline": [ { "name": "branch", "command": "hook-status", "timeout_ms": 5000 } ],
    "commands": [ { "name": "/hello", "description": "say hello", "command": "hook-hello" } ],
    "keybindings": [ { "key": "ctrl+g", "command": "git status", "description": "working tree" } ]
  }
}
```

Every field but `command` is optional. `timeout_ms` defaults to 5000 and is capped at 60000; a hook
cannot grant itself more. `matcher` is a Lua pattern against the tool name (or the profile for
subagent events, the component name for install events); a plain word matches case-insensitively
anywhere in the name, so `bash` names `bash`, and `^read$`, `bash|shell`, `.*` also work. An unknown
event name is reported in `/hooks` rather than silently dropped - a typo must be visible.

Claude Code's shape is accepted too, including a `matcher` wrapper and a `timeout` in **seconds**:

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Bash",
  "hooks": [ { "type": "command", "command": "~/bin/guard.sh", "timeout": 30 } ] } ] } }
```

Those files are read **only** when this node's own config says `"hooks": {"claude_compat": true}` (or
`WASM_AGENT_CLAUDE_HOOKS=1`). Hooks written for another harness are not re-used behind the operator's
back; they were written for different events.

## The protocol (Claude Code compatible)

A command hook receives the event as one JSON object on **stdin** and answers with an exit code and,
for a decision, one JSON object on **stdout**.

| exit | meaning |
|---|---|
| 0 | its answer is the JSON object (if any) |
| 2 | **blocks**: the reason is its stderr, and the caller shows it |
| other | a visible failure that changes nothing (recorded, logged, never blocking) |

The object may carry:

| field | effect |
|---|---|
| `hookSpecificOutput.permissionDecision` | `allow`, `deny`, `ask` (PreToolUse) |
| `hookSpecificOutput.permissionDecisionReason` | the sentence the model/reader sees |
| `hookSpecificOutput.updatedInput` | an object **merged** over the call's arguments (PreToolUse) |
| `hookSpecificOutput.additionalContext` | text added to the model's context at that boundary |
| `hookSpecificOutput.hookEventName` | must match; a mismatch is recorded and ignored |
| `decision` | `approve` / `block` (the older, flatter shape) |
| `reason` | the sentence shown for a block |
| `continue` | `false` keeps the answer and stops the run (Stop only) |
| `stopReason` | why the run stopped |
| `systemMessage` | one line the reader sees (the mods surface, never a decision) |
| `reschedule_seconds` | `SelfWake` only: veto this wake and try again in N seconds |

Differences from Claude Code, deliberate and small:

* `updatedInput` is **merged** over the arguments rather than replacing the object, so a hook that
  narrows `path` cannot accidentally drop `requests`.
* `ask` is answered by policy, because this node has no interactive per-call prompt: the entry's
  `on_ask` (`deny` by default, `allow` to accept) decides, and the refusal says how to change it.
* A hook that fails, times out or prints garbage is recorded and the call proceeds. Only exit 2 or an
  explicit `deny`/`block` stops anything.

Claude Code's `$CLAUDE_PROJECT_DIR` is set for compatibility; `WA_HOOK_EVENT`, `WA_HOOK_NAME` and
`WA_HOOK_SESSION` are set as well.

## Events and their payloads

Every payload carries `hook_event_name`, `version`, `session_id`, `cwd` and, when known, `run_id`,
`node_id`, `user_id`, `role`. Payloads are ids, names, counts and lengths; a hook is not handed the
transcript, a credential or a whole tool result.

| event | fires | extra fields | may |
|---|---|---|---|
| `SessionStart` | a run's context is built, before the first request | `source`, `resume` | context, systemMessage |
| `UserPromptSubmit` | the reader's text is known, before the model sees it | `prompt`, `prompt_len`, `images` | block, context, systemMessage |
| `PreToolUse` | arguments decoded, before the tool runs | `tool_name`, `tool_input`, `tool_call_id` | allow, deny, ask, updatedInput, context, systemMessage |
| `PostToolUse` | a tool returned, before the result is recorded | `tool_name`, `tool_input`, `tool_response`, `tool_response_bytes`, `ok` | context, systemMessage |
| `PostToolUseFailure` | a tool errored or raised | `tool_name`, `tool_input`, `error`, `ok=false` | context, systemMessage |
| `PreCompact` | a compaction is about to rewrite the prefix | `tokens_before`, `limit`, `keep`, `trigger`, `reason`, `forced` | block, systemMessage |
| `PostCompact` | the rewrite landed | `tokens_before`, `tokens_after`, `through`, `trigger`, `summary_model` | context, systemMessage |
| `Stop` | a completed no-tool candidate is identified as the answer, before it is committed | `message_id`, `text_len`, `stop_hook_active`, `phase` | continue, stop, context, systemMessage |
| `SubagentStart` | a child is admitted, before its first request | `subagent_id`, `profile`, `parent_session_id`, `prompt_len` | context, systemMessage |
| `SubagentStop` | a child settled (completed/failed/cancelled/unknown) | `subagent_id`, `profile`, `state`, `settled` | context, systemMessage |
| `Notification` | a fact for the reader that is not the answer | `kind`, `text_len`, `notice_id`/`state` | context, systemMessage |
| `SelfWake` | a due self-wake is claimed, before its turn | `wake_id`, `reason`, `due_at`, `attempts`, `event` | block (+`reschedule_seconds`), systemMessage |
| `PreDeploy` | a deploy request is about to be written for the sentinel | `commit`, `installed_commit`, `reason`, `sentinel` | block, systemMessage |
| `PostDeploy` | the sentinel named a durable request | `request`, `commit`, `queued=true`, `installed=false`, `stopped` | context, systemMessage |
| `ComponentInstall` | a component is about to be installed, enabled or upgraded | `component`, `action`, `artifact` | block, systemMessage |
| `ComponentSwap` | an upgrade switched to the new instance | `component`, `state` | context, systemMessage |
| `bus:<topic>` / `bus:*` | `selfloop.publish(topic, …)` | the publish payload plus `topic` | nothing (a fact cannot be vetoed) |
| `StatusLine` | the CLI renders its footer (a mod) | `model`, `runs`, `tokens`, `context`, `context_percent` | its stdout is the segment |

`Notification` is produced where the agent already tells the reader something that is not the answer:
a wave-closure notice, and a failed closure report. A run's ordinary prose is not a notification.

## Lua hooks and components

A module the operator enabled can register a function instead of a command. It takes the same payload
table and answers the same decision table, so one interpreter covers both kinds:

```lua
local hooks = dofile('lua/core/hooks.lua')
local handle = hooks.register('PreToolUse', function(payload, ctx)
  if payload.tool_name == 'bash' and payload.tool_input.command:find('rm %-rf /', 1) then
    return { hookSpecificOutput = { permissionDecision = 'deny',
      permissionDecisionReason = 'that command is refused by policy' } }
  end
end, { name = 'no-rm-rf', matcher = 'bash' })
-- hooks.unregister(handle) when the module unloads
```

The state (config cache, registered hooks, last outcomes) is one process-wide table, because `dofile`
re-executes a module in this interpreter: `tools.lua`, `agent.lua` and the read surface each hold an
instance of the engine, and they must agree about what is configured and what just happened.

**Not built, on purpose: hooks as WASI components.** The shape the host would need is one export that
takes the same JSON and returns the same decision, in the async ABI of WASI 0.3:

```wit
interface hooks {
  record invocation { event: string, version: u32, payload: list<u8> }
  variant outcome {
    inert, allow, deny(string), ask(string), rewrite(list<u8>),
    context(string), message(string), stop(string), reschedule(u32),
  }
  handle: async func(call: invocation) -> result<outcome, string>;
}
world hook-component { export hooks; }
```

The host would keep the same bounds (per-hook timeout, capped output, never blocking unless the answer
is a denial) and the same rule as every other component: **governance applies to what the hook does,
not to calling it**. Until that exists, a component hook is a command that invokes one.

## Safety

* **A hook never blocks the run unless it explicitly denies.** Timeout, a crash, exit 1, unparseable
  stdout: recorded, logged, and the call proceeds.
* **Per-hook timeout** (`timeout_ms`, default 5000, cap 60000) and **capped output** (stdout 8 KiB,
  stderr 2 KiB kept). The caps are recorded (`stdout_clipped`), never silent.
* **Secrets.** A hook's stderr/detail is redacted before it is logged or listed (the same
  `lua/core/redact.lua` boundary every other log uses). Payloads are not logged.
* **Grants.** A command hook runs with the node's normal grants - the operator wrote the command, and
  the governance that applies to what it does still applies to it. A hook that edits files is a
  process that edits files, and the node does not pretend otherwise.
* **`/hooks`** lists the active sources, events, matchers, footer segments, commands, key
  declarations, the last outcome and any config error. It runs no hook (except the explicitly separate
  footer read) and prints no payload.

## What a hook cannot see or do

* It cannot see the answer text (`Stop` carries `text_len`, not `text`), the transcript, or a whole
  tool result (a bounded, redacted view, 8 KiB).
* It cannot veto a published bus fact, undo a completed tool call, or change a settled child.
* It cannot skip the boundary: parallel bash batching is turned off while hooks are configured, so
  every `bash` call passes `PreToolUse`/`PostToolUse` one at a time instead of running beside a hook
  that never saw it.
* It cannot promise that a `PostDeploy` was an install. The sentinel accepted a request; the
  installation is a different fact with its own record.

## Tests

`scripts/test-hooks-engine.lua` (protocol and bounds), `scripts/test-hooks-tools.lua` (the tool
boundary), `scripts/test-hooks-agent.lua` (context, refused prompt, Stop continue, denied tool call)
and `scripts/test-hooks-mods.lua` (footer segment, commands, `/hooks`). They run in the fast path and
are hermetic: every command is the test's own script in its own scratch home, and no provider is
called.

## Open questions

* The window's footer reads one mod segment through `POST /jobs {action:"hooks_status"}`. It is a
  request per session (cached 30s), not a push: a segment does not update while a run streams.
* `keybindings` are parsed, validated and listed, but this CLI has no configurable key surface yet
  (the native editor owns input), so nothing dispatches them. That is stated here rather than faked.
* A hook that runs under `PreToolUse` on every call costs one process per call. That is the operator's
  choice, and the reason batching is off while hooks are configured.
