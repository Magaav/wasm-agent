# The envelope — every control the model gets

Each turn is one HTTP request to the provider:

```
{ model, messages[], tools[] }        <- the "envelope"
```

`tools[]` is built in `lua/core/tools.lua` from the caller's **role**, so the
model literally cannot see a tool its account may not use. This is the map of
that surface. The live version is rendered in the UI under **engine → tools**
(`GET /tools`).

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
| `read` | `path`, `offset?`, `limit?` | read a text file / line range |
| `write` | `path`, `content` | create or overwrite a file |
| `edit` | `path`, `old_text`, `new_text` | first exact replacement |
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

No raw HTTP, no SQL, no filesystem, no process, no network, no key material.
Every side effect goes through a named tool in one of the tiers above, and the
tier is enforced twice: the schema is filtered *and* `dispatch` re-checks the
role, so a hallucinated tool name cannot escalate.

## Result shapes

Tools return JSON. Errors are explicit (`{"error": "..."}`), never silent
success — the model is told when something was refused (`forbidden_for_role`,
`bad_signature`, `unknown_caller`, `stale_request`, `postcondition_failed`).
