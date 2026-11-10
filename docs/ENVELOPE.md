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

Discovery takes two forms, and they are exclusive. `tool_search(query=...)` scores keywords;
`tool_search(names=[...])` loads an exact list of 1-8 tool names, and `query="select:a,b,c"` is the
same batch spelled inside one string. A batch is one loadout write (a single compare-and-swap on the
session's loadout row), so it is all loaded or `envelope_loadout_changed` with effect none. Every
permitted name is pinned and guided exactly like a keyword hit; a name that is unknown or not
permitted comes back in `missing` with the nearest permitted names, drawn from the caller's own
catalogue, so a denied name is never disclosed. Inside code mode `searchTools({names=[...]})` is the
same request: the guest's metadata over its own ceiling, which loads and admits nothing.
The declared tool list (and the system prompt that describes it) is **frozen per session**: it is
recorded on the session's first turn and every later request sends exactly those bytes, so a provider
prefix cache can hit. A later orchestration toggle, skill install, policy reload or instruction edit
arrives as an appended `[session update]` note instead of changing the prefix - including the
`subagent`/`route_task` definitions for a mode turned on mid-session, which are pinned into the
loadout like a `tool_search` hit. See [PROMPT-CACHE.md](PROMPT-CACHE.md).

<!-- generated:deferred-tools (scripts/sync-prompt-docs.lua) -->
Built-in tools not declared at bootstrap, as the progressive prompt lists them (the role, profile and mode still decide visibility):

- `memories`: List stored facts, with their ids
- `wake`: Schedule your own next turn (time, event or repeating)
- `wake_list`: List your pending self-wakes
- `wake_cancel`: Cancel a pending self-wake by id
- `notes_read`: Read the plan/notes document you own for this session
- `notes_write`: Replace your session notes (previous version archived)
- `notes_append`: Append to your session notes
- `notes_compact`: Keep the last lines of your notes and archive the rest
- `capabilities`: List the tools this account may use
- `lessons`: Recall or add what this fleet learned the hard way (symptom, cause, fix, rule)
- `fleetview`: One read-only view of the whole fleet: liveness, version, health, disk, components, work, incidents
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
- `whatsapp_send`: Send one WhatsApp message to an exact chat through the durable outbox
- `whatsapp_send_status`: Read the state of a queued WhatsApp send, with its message id when sent
- `whatsapp_search`: Search every indexed WhatsApp message by text, chat, kind, sender or time window
- `whatsapp_read`: Read one WhatsApp chat newest first, with reactions folded onto their messages
- `whatsapp_reactions`: Who reacted to one WhatsApp message, with which emoji
- `whatsapp_media`: The media metadata of one WhatsApp message: mime, filename, size, sha256, duration
- `whatsapp_download`: Decrypt one WhatsApp message's media to this node and return the file path
- `whatsapp_backfill`: Ask the phone for older WhatsApp messages so search covers the account's past
- `email_send`: Send one email through the durable outbox, with the message id readable afterwards
- `email_send_status`: Read the state of a queued email send, with its message id when delivered
- `email_search`: Search every indexed email by text, sender, subject, mailbox or time window
- `email_read`: Read one mailbox newest first, or one message by uid, with its attachments listed
- `email_media`: The attachment metadata of one email, with the handle a download names
- `mcp`: List and manage MCP connectors; new or edited ones stay disabled until enabled
- `services`: List and manage long-lived WASI service components: start, stop, logs
- `capture_inspect`: Inspect retained model-request captures as bounded metadata before reading raw dumps
- `node_update`: Ask another node to update itself, and read its outcome
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
| `wake` | `reason` `at?` `every_seconds?` `in_seconds?` `on?` `probe?` `prompt?` | Schedule your own next turn (time, event or repeating) |
| `wake_list` | `all?` | List your pending self-wakes |
| `wake_cancel` | `id` | Cancel a pending self-wake by id |
| `notes_read` | `version?` `versions?` | Read the plan/notes document you own for this session |
| `notes_write` | `text` | Replace your session notes (previous version archived) |
| `notes_append` | `text` | Append to your session notes |
| `notes_compact` | `keep_lines?` | Keep the last lines of your notes and archive the rest |
| `skill` | `limit?` `name?` `offset?` `query?` `snapshot?` | Discover procedures by query or load a full skill by name |
| `capabilities` | - | List the tools this account may use |
| `lessons` | `action` `cause?` `fix?` `id?` `limit?` `query?` `rule?` `source?` `symptom?` `tags?` | Recall or add what this fleet learned the hard way (symptom, cause, fix, rule) |
| `fleetview` | `lessons?` | One read-only view of the whole fleet: liveness, version, health, disk, components, work, incidents |
| `tool_search` | `limit?` `names?` `query?` | Discover and load a permitted tool definition |
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
| `whatsapp_send` | `chat` `text` `mentions?` `reply_to?` | Send one WhatsApp message to an exact chat through the durable outbox |
| `whatsapp_send_status` | `id` | Read the state of a queued WhatsApp send, with its message id when sent |
| `whatsapp_search` | `chat?` `from?` `kind?` `limit?` `q?` `since?` `until?` | Search every indexed WhatsApp message by text, chat, kind, sender or time window |
| `whatsapp_read` | `chat` `before?` `limit?` | Read one WhatsApp chat newest first, with reactions folded onto their messages |
| `whatsapp_reactions` | `chat` `id` | Who reacted to one WhatsApp message, with which emoji |
| `whatsapp_media` | `chat` `id` | The media metadata of one WhatsApp message: mime, filename, size, sha256, duration |
| `whatsapp_download` | `chat` `id` `max_bytes?` | Decrypt one WhatsApp message's media to this node and return the file path |
| `whatsapp_backfill` | `chat?` `count?` | Ask the phone for older WhatsApp messages so search covers the account's past |
| `email_send` | `body` `subject` `to` `attachments?` `cc?` `in_reply_to?` | Send one email through the durable outbox, with the message id readable afterwards |
| `email_send_status` | `id` | Read the state of a queued email send, with its message id when delivered |
| `email_search` | `from?` `has_attachment?` `limit?` `mailbox?` `q?` `since?` `subject?` `until?` | Search every indexed email by text, sender, subject, mailbox or time window |
| `email_read` | `before?` `limit?` `mailbox?` `uid?` | Read one mailbox newest first, or one message by uid, with its attachments listed |
| `email_media` | `uid` `mailbox?` | The attachment metadata of one email, with the handle a download names |
| `mcp` | `action?` `definition?` `expected_revision?` `id?` | List and manage MCP connectors; new or edited ones stay disabled until enabled |
| `services` | `action?` `bytes?` `definition?` `expected_revision?` `name?` `producer?` `ready_ms?` `set_role?` `source?` | List and manage long-lived WASI service components: start, stop, logs |
| `capture_inspect` | `path` `item_index?` `limit?` `offset?` `request_index?` `snapshot?` `view?` | Inspect retained model-request captures as bounded metadata before reading raw dumps |
| `web_search` | `query` `limit?` `refresh?` | Search public web sources with retained evidence |
| `web_read` | `limit?` `offset?` `pending_ref?` `ref?` `refresh?` `url?` | Read a public source or page an immutable cache ref |
| `node_update` | `node` `action?` `commit?` `follow_up_seconds?` `id?` `reason?` `rendezvous?` | Ask another node to update itself, and read its outcome |

A guest's catalogue is `time`, `remember`, `recall`, `memories`, `wake`, `wake_list`, `wake_cancel`, `notes_read`, `notes_write`, `notes_append`, `notes_compact`, `skill`, `capabilities`, `lessons`, `fleetview`, `tool_search`, `tool_call`, `subagent`, `sessions`, `session`, `search_messages`, `resume_session`.
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
