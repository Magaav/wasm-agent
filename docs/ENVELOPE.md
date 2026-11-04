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

## Declared and on-demand tools

<!-- generated:bootstrap-tools (scripts/sync-prompt-docs.lua) -->
New operator sessions declare 14 tools from the start (`lean`, the default): `bash`, `edit`, `read`, `read_many`, `recall`, `remember`, `session_worktree`, `skill`, `time`, `tool_call`, `tool_search`, `web_read`, `web_search`, `write`.
`codemode` is also declared when code mode is admitted for the run. Orchestration mode adds `route_task`, `subagent`.
`WASM_AGENT_BOOTSTRAP_MODE=classic` adds `capabilities`, `tool_result` (16 in all).
Every other permitted tool is called on demand with `tool_call`; the system prompt lists it with its cue.
<!-- /generated -->

<!-- generated:deferred-tools (scripts/sync-prompt-docs.lua) -->
Built-in tools not declared at bootstrap, as the progressive prompt lists them (the role, profile and mode still decide visibility):

- `memories`: List stored facts, with their ids
- `capabilities`: List the tools this account may use
- `subagent`: Start and collect a child agent on a bounded task
- `sessions`: List your past sessions
- `session`: Read a session, paging earlier evidence
- `search_messages`: Search your own past sessions for text
- `resume_session`: Fold a past session into this one as context
- `tool_result`: Read an exact byte range of a truncated tool result
- `route_task`: Record whether this turn is done here or delegated (orchestration mode)
- `forget`: Delete a stored fact by id
- `operation`: Run or collect a supervised long command
- `ls`: List a directory
- `grep`: Find lines matching literal text
- `graph`: Retrieve symbol source, trace relationships, or audit patch impact
- `diagnose`: Run a fixed read/grep check sequence once
- `client`: Act on the user's machine: screen, mouse, keyboard, browser
- `shell`: Run a shell command on the client machine
- `spell_save`: Save a verified command sequence as a reusable spell
- `spell_compose`: Combine a verified spell sequence with its checks intact
- `spell_run`: Replay a saved spell
- `spell_list`: List saved spells
- `spell_get`: Read one saved spell in full
- `spell_forget`: Delete a saved spell
- `spell_export`: Export a spell for the sentinel to run
- `remote`: Run a capability on another node
- `nodes`: List this node and its peers
- `session_debug`: Set a session's recording mode (debug or default)
- `session_fixture`: Export a session as a reproducible fixture
- `wave_autoflush`: Control coordinator acceptance and durable wave-end installation obligation
- `integrate`: Land an orchestration worker's tested tip; never deploy
- `resource`: Inspect resource ownership and reconcile interrupted effects
- `edit_many`: Preflight independent edits, then apply with per-file outcomes
- `grep_many`: Run separately scoped literal searches together
- `search_messages_many`: Run independently filtered history searches together
- `session_many`: Read bounded ranges from several sessions
- `symbol_source_many`: Retrieve several selected symbol implementations
- `write_many`: Preflight independent writes, retaining diff and undo evidence
- `mcp`: List and manage MCP connectors; new or edited ones stay disabled until enabled
- `capture_inspect`: Inspect retained model-request captures as bounded metadata before reading raw dumps
<!-- /generated -->

## Tool catalogue

Generated from the schemas in `lua/core/tools.lua` (built-in tools only; a node's WASM plugins in
`~/.wasm-agent/plugins` and its MCP connectors are added at runtime). `client` is one tool whose
actions (screenshot, frame, move, click, type, key, shell, cdp) run on the client machine; `shell`
runs on the client too, while `bash` runs on this node.

<!-- generated:tool-catalogue (scripts/sync-prompt-docs.lua) -->
| Tool | Args (`?` optional) | Cue |
| --- | --- | --- |
| `time` | - | Ask this node's OS clock (local time with its offset) |
| `remember` | `content` `id?` `scope?` `tags?` | Store a fact the user asked you to keep |
| `recall` | `query` `limit?` `scope?` | Look up stored facts before answering about the user |
| `memories` | `limit?` `scope?` | List stored facts, with their ids |
| `skill` | `limit?` `name?` `offset?` `query?` `snapshot?` | Discover procedures by query or load a full skill by name |
| `capabilities` | - | List the tools this account may use |
| `tool_search` | `query` `limit?` | Discover and load a permitted tool definition |
| `tool_call` | `arguments?` `calls?` `checked?` `cursor?` `name?` | Call a permitted tool by name without expanding permanent declarations |
| `subagent` | `action` `after_seq?` `before_seq?` `byte_limit?` `byte_offset?` `context?` `conversation_id?` `delivery_id?` `id?` `idempotency_key?` `limit?` `message_id?` `message_version?` `model?` `offset?` `parent_run_id?` `profile?` `prompt?` `reasoning?` `run_id?` `session_id?` `text?` `title?` `view?` `wait_ms?` | Start and collect a child agent on a bounded task |
| `sessions` | `all_owners?` `limit?` `node?` `path?` | List your past sessions |
| `session` | `session_id` `after?` `around_seq?` `before?` `before_seq?` `byte_limit?` `byte_offset?` `limit?` `message_id?` `message_ids?` `message_version?` `node?` `view?` | Read a session, paging earlier evidence |
| `search_messages` | `query` `after?` `before?` `byte_limit?` `group_by?` `limit?` `match?` `node?` `offset?` `roles?` `scope?` `session_id?` `sort?` `tool_name?` `view?` | Search your own past sessions for text |
| `resume_session` | `session_id` `limit?` | Fold a past session into this one as context |
| `tool_result` | `sha256` `limit?` `offset?` | Read an exact byte range of a truncated tool result |
| `route_task` | `route` `task` `reason?` | Record whether this turn is done here or delegated (orchestration mode) |
| `forget` | `id` | Delete a stored fact by id |
| `bash` | `command` `cwd?` `timeout_seconds?` | Run a shell command on this machine |
| `operation` | `action` `command?` `cwd?` `id?` `limit?` `offset?` `stream?` `timeout_seconds?` `wait_for?` `wait_ms?` | Run or collect a supervised long command |
| `read` | `path` `column?` `limit?` `offset?` `version?` | Read a file (text or image), paged |
| `read_many` | `cursor?` `requests?` | Read several files or ranges in one call |
| `write` | `content` `path` | Create or overwrite a file |
| `edit` | `path` `edits?` `range_edits?` | Replace a versioned range returned by read |
| `ls` | `path?` | List a directory |
| `grep` | `pattern` `extensions?` `ignore_case?` `limit?` `max_depth?` `path?` | Find lines matching literal text |
| `graph` | `action` `aspects?` `byte_offset?` `commit?` `critique?` `cursor?` `cwd?` `depth?` `direction?` `evidence?` `force?` `from?` `grade?` `hours?` `kind?` `limit?` `line?` `max_bytes?` `name?` `offset?` `outcome?` `path?` `prefer_implementations?` `reason?` `requests?` `run_id?` `source?` `source_version?` `to?` | Retrieve symbol source, trace relationships, or audit patch impact |
| `diagnose` | `steps` | Run a fixed read/grep check sequence once |
| `client` | `action` `button?` `id?` `key?` `max_chars?` `port?` `profile?` `reuse?` `script?` `target?` `text?` `timeout_ms?` `url?` `x?` `y?` | Act on the user's machine: screen, mouse, keyboard, browser |
| `shell` | `command` `cwd?` `shell?` | Run a shell command on the client machine |
| `spell_save` | `name` `post` `steps` `description?` `params?` `pre?` `target?` | Save a verified command sequence as a reusable spell |
| `spell_compose` | `name` `parts` `description?` | Combine a verified spell sequence with its checks intact |
| `spell_run` | `name` `params?` | Replay a saved spell |
| `spell_list` | - | List saved spells |
| `spell_get` | `name` | Read one saved spell in full |
| `spell_forget` | `name` | Delete a saved spell |
| `spell_export` | `name` `binary?` `params?` `path?` | Export a spell for the sentinel to run |
| `remote` | `capability` `node` `args?` `calls?` `command?` `path?` | Run a capability on another node |
| `nodes` | - | List this node and its peers |
| `session_debug` | `mode` `session_id?` | Set a session's recording mode (debug or default) |
| `session_fixture` | `session_id?` | Export a session as a reproducible fixture |
| `session_worktree` | `action` `path?` `session_id?` | Point this session's tools at their own checkout |
| `wave_autoflush` | `action` `binary_receipt?` `child_id?` `digest?` `evidence?` `request_id?` `revision?` `sha?` `tip?` `tree?` | Control coordinator acceptance and durable wave-end installation obligation |
| `integrate` | - | Land an orchestration worker's tested tip; never deploy |
| `resource` | `action` `evidence?` `key?` `principal?` `run?` | Inspect resource ownership and reconcile interrupted effects |
| `edit_many` | `requests` | Preflight independent edits, then apply with per-file outcomes |
| `grep_many` | `requests` | Run separately scoped literal searches together |
| `search_messages_many` | `requests` | Run independently filtered history searches together |
| `session_many` | `requests` | Read bounded ranges from several sessions |
| `symbol_source_many` | `requests` | Retrieve several selected symbol implementations |
| `write_many` | `requests` | Preflight independent writes, retaining diff and undo evidence |
| `mcp` | `action?` `definition?` `expected_revision?` `id?` | List and manage MCP connectors; new or edited ones stay disabled until enabled |
| `capture_inspect` | `path` `item_index?` `limit?` `offset?` `request_index?` `snapshot?` `view?` | Inspect retained model-request captures as bounded metadata before reading raw dumps |
| `web_search` | `query` `limit?` `refresh?` | Search public web sources with retained evidence |
| `web_read` | `limit?` `offset?` `pending_ref?` `ref?` `refresh?` `url?` | Read a public source or page an immutable cache ref |

A guest's catalogue is `time`, `remember`, `recall`, `memories`, `skill`, `capabilities`, `tool_search`, `tool_call`, `subagent`, `sessions`, `session`, `search_messages`, `resume_session`.
<!-- /generated -->

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
