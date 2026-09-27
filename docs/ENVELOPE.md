# Model-request envelope and tool surface

[ARCHITECTURE.md §6](../ARCHITECTURE.md#6-naming-and-execution-ownership) owns the
vocabulary: a run contains decision steps; each provider attempt is a model call
with its own **model-request envelope**. A step normally makes one call, but a
timeout retry can replay the envelope and overflow recovery can prepare a different
one in the same step. A preflight failure can make none. A turn is a speaker's
contribution, not a provider request. The prepared request includes the model, messages (instructions,
summary if any, and transcript), advertised tools when present, and applicable
output, reasoning, cache and streaming options. Summaries can use a different
model and no tools. `lua/core/agent.lua` builds context and the tool list;
`lua/core/provider.lua` assembles the request. The subscription bridge translates
that prepared input to its own provider wire request. Neither the selected settings
nor a predicted next context is the exact request of a past model call.

The **tool surface** (`tools[]`) is built in `lua/core/tools.lua` from the role
and, for a subagent, its approved profile. Dispatch independently enforces the
capability policy: advertising a schema does not itself grant execution. The
following is an orientation map, **not a frozen or exhaustive schema catalog**.
The current role-filtered list and schemas are shown under **engine → tools**
(`GET /tools`). That view also shows a **selected configuration/tool preview**
(`GET /model-configuration-preview`, with `/envelope` retained as a legacy alias): it
contains model, provider, base URL and advertised tools, **not** messages or
per-call options. It is not the full envelope and is not provider wire bytes.
For the available debug context/tool snapshot versus a reconstruction at report
time (neither a complete provider request), see
[OBSERVABILITY.md](OBSERVABILITY.md#live-efficiency-report).

## Tiers

### everyone (guest *and* master)

| Tool | Args | Does |
| --- | --- | --- |
| `remember` | `content`, `scope?`, `tags?` | store a fact |
| `recall` | `query`, `scope?`, `limit?` | search remembered facts |
| `capabilities` | — | list the tools this account may call |

### master only

**environment (pi)** — runs on the host

| Tool | Args | Does |
| --- | --- | --- |
| `bash` | `command`, `cwd?` | run a shell command |
| `read` | `path`, `offset?`, `limit?` | read a PNG/JPEG/WebP/GIF as visual input, or an exact text range, naming the line frame an edit may address |
| `write` | `path`, `content` | create or overwrite a file |
| `edit` | `path`, `edits?`, `range_edits?` | replace quoted bytes, or an opaque versioned selection from `read` sliced by the line frame `read` names; the result echoes what was replaced |
| `ls` | `path?` | list a directory |
| `grep` | `pattern`, `path?` | search files |

**shell** — runs on the *client* machine (the desktop hosting the window); the
UI terminal uses the same path

| Tool | Args | Does |
| --- | --- | --- |
| `shell` | `command`, `shell?` (`cmd`\|`powershell`), `cwd?` | run a command on the client |

**ledger**

| Tool | Args | Does |
| --- | --- | --- |
| `search_messages` | `query`, `conversation_id?`, `limit?` | search the message ledger |
| `conversation` | `conversation_id`, `limit?` | read one conversation |
| `list_conversations` | `limit?` | list conversations |

**client** — one tool, many actions; each runs on the client machine

| Action | Args | Returns |
| --- | --- | --- |
| `client.screenshot` | — | `{path, width, height}` (full-res BMP on the client) |
| `client.frame` | `max_width?` | `{image (base64 BMP), width, height, scale}` |
| `client.move` | `x`, `y` | `{ok}` |
| `client.click` | `x`, `y`, `button?` (`left`\|`right`) | `{ok}` |
| `client.type` | `text` | `{ok, chars}` |
| `client.key` | `key` (`enter`\|`tab`\|`esc`\|`up`\|…) | `{ok}` |
| `client.shell` | `command`, `shell?`, `cwd?` | `{code, stdout, stderr}` |
| `client.cdp` | `target`, `script?`, `id?`, `url?`, `port?`, `profile?` | see below |

`client.cdp.target` ∈ `list` · `open` · `close` · `activate` · `navigate` ·
`evaluate` · `launch`. It drives **Chrome** on the wasm-agent account
(`AgentBrowserChromeProfile`), launching it with remote debugging if it is not
already running. `evaluate` runs JS in the first page target and returns the
value.

**spells** — deterministic, verified executions (see `SPELLS.md`). Note the
name is reserved for spells only; the tier that *lists* what you may do is
`capabilities`, above.

| Tool | Args | Does |
| --- | --- | --- |
| `spell_save` | `name`, `steps`, `post` (required), `params?`, `pre?`, `target?`, `description?` | crystallize a deterministic execution; **refused without `post`** |
| `spell_run` | `name`, `params?` | replay; fails loudly if a step or assertion fails |
| `spell_list` | — | list with version and params |
| `spell_get` | `name` | read one in full |
| `spell_forget` | `name` | delete |

**nodes** — the multi-node fabric

| Tool | Args | Does |
| --- | --- | --- |
| `nodes` | — | list this node + peers from the rendezvous |
| `remote` | `node`, `capability`, `args` | run a capability on a peer (signed, verified) |

**plugins** — every WASM plugin in `~/.wasm-agent/plugins` (e.g. `echo`).

## What the model does **not** get

The model does not receive credentials or direct, unmediated host access. It can
request side effects through tools (including shell and filesystem access for an
authorized operator). The schema is filtered and `dispatch` re-checks authority,
so inventing a tool name cannot bypass the role or subagent policy.

## Result shapes

Tools return JSON. An image returned by `read` is persisted as a reference on the tool
message, while the provider receives a following user-role image part after the complete
tool-result block. This preserves Chat Completions tool-call ordering without storing
base64 in the result. Missing, unsupported and oversized images are explicit errors.

Errors are explicit (`{"error": "..."}`), never silent
success — the model is told when something was refused (`forbidden_for_role`,
`bad_signature`, `unknown_caller`, `stale_request`, `postcondition_failed`).
