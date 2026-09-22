# The Lua ↔ Rust host boundary

The Lua core decides what the agent does; `host.*` is everything it needs from
the platform. Those functions are the seam that becomes WIT imports when the Lua
core runs as a WASM component, so their semantics have to be boring and exact.

## Missing values: `nil`, never "no values"

A host function **always returns a value**. An absent one is `nil`.

This is not pedantry. A Lua function returning *zero* values expands to nothing
when used as an argument:

```lua
tonumber(host.getenv("NOT_SET"))   -- if getenv returned 0 values:
tonumber()                         -- -> error: bad argument #1 (value expected)
```

That is exactly how `host.getenv` broke every turn on Windows until it pushed an
explicit `nil`. The same trap applies to any new accessor: return `nil`, return
an empty string, return `0` — but never return nothing where a caller could
reasonably expect one value.

Lua code should still be written to survive a missing capability (an older host,
a WASI shim that has not wired something up):

```lua
local ok, value = pcall(host.some_thing)
if not ok or value == nil then ... end
```

## Paths: ask, do not assume

Use `host.paths()` — never `$HOME`, `/tmp`, `/proc` or a drive letter:

| field | meaning | Linux | Windows |
| --- | --- | --- | --- |
| `home` | user's home | `/home/ubuntu` | `C:\Users\Victor` |
| `config` | per-user config | `~/.wasm-agent` | `C:\Users\Victor\.wasm-agent` |
| `data` | persistent state | `~/.wasm-agent` | same |
| `cache` | throwaway | `~/.wasm-agent/cache` | same |
| `temp` | scratch | `/tmp` | `%TEMP%` |

`lua/core/paths.lua` wraps it and degrades to the environment if the host is too
old to answer, so callers use `paths.config()` and never build strings.

Why this matters, learned the hard way:

- Windows does not set `HOME` at all, and Git Bash sets it to `/c/Users/...` —
  a POSIX path a native binary cannot open. The config file was silently
  ignored and the agent ran with "no model configured".
- `host.uuid()` read `/proc/sys/kernel/random/uuid` and fell back to the process
  id, which is one value per process, so the second write in any session failed
  with `UNIQUE constraint failed: turns.id`.

The rule that follows: **no Linux-only path may appear in the Lua core or in
Rust code that Lua depends on.** Rust may use `std::env::temp_dir()` and friends;
it must not hardcode `/proc`, `/tmp` or `/var`.

## Environment

`host.getenv(name)` checks what the host resolved (the config file, the home
directory, the database path) and then the real process environment.

Do not use `os.getenv` in the Lua core. On Windows, Rust's `set_var` is invisible
to the C runtime's `getenv` — the UCRT caches the environment at startup — so
`os.getenv` returns what the process was launched with, not what the host
resolved. That silently disabled the entire configuration file.

## Redaction

`host.log(message)` masks credential-shaped text before printing, and the Lua
side has `lua/core/redact.lua` applied at every boundary that leaves the process:
provider errors, server replies, the REPL printer, and text persisted into the
trace. Errors are stored redacted, not only displayed redacted, because the trace
is readable later from the session view.

The mask keeps the last four characters (`sk-...7f2a`) so an operator can still
tell *which* key failed without being able to use it.

## Supervised execution and automation

`host.exec` is the synchronous facade for an owned **operation**. `host.operation`
exposes explicit launch receipts, status, cursor-based output, bounded waits and
cancellation; `host.jobs` manages automation definitions/enable state, never executes
a job itself. Both always return one JSON value, including failure. Do not add a
second shell runner with `Command::output`, `read_to_end` or detached reader threads.
See [OPERATIONS.md](OPERATIONS.md) and [JOBS.md](JOBS.md) for contracts, platform
limits, authority, recovery and the regression tests.
## Portable file search

`host.grep(pattern,path,options_json)` performs literal substring matching; Lua
validates options before dispatch. It returns matches, scan counts, explicit skip
categories and completeness, never silently substitutes shell grep/findstr semantics.
Case sensitivity, bounded result/depth controls and exact extension filters are
supported. Per-line clipping is marked; directories are sorted, symlinks skipped,
file reads bounded to 4 MiB and traversal bounded to 20,000 entries. These are scan
limits, not a hard filesystem deadline. See [TOKEN_EFFICIENCY.md](TOKEN_EFFICIENCY.md)
for read paging, single-file batch-edit limits and local deterministic index caching.

## The client bridge: three states, one budget

The desktop window is not a host function: the window dials *out* to the node and
long-polls for commands, so the node needs no inbound path to the user's machine.

That channel has one contract, and the reason each clause exists is a failure:

- **A connection cannot cost another connection anything.** The accept loop used
  to serve one connection at a time: a peer that opened a socket and said nothing
  blocked every later poll, `mark_poll` never ran, and the only symptom was
  `client_not_connected` — which blamed the window, which was healthy. Requests
  are now read on their own thread with a read timeout.
- **Three states, not one flag.** `bridge.health` (does the node's bridge answer
  its own probe: `ok` / `degraded` / `wedged`), `connected` + `last_seen_secs`
  (is the window polling), and `busy` (what it is doing right now) have three
  different remedies. `/health` carries the same block as `client`, and the
  `nodes` tool shows it as the `client` row, so the answer costs no round trip.
- **The window is never the remedy.** The error text for a wedged bridge says so
  explicitly: restarting the window is not a fix, and a second window would split
  one bridge's commands between two pollers.
- **The caller's patience travels with the command.** `host.client(action, args,
  timeout_ms)` sends `budget_ms`; the client bounds its own work by it (a launch,
  a shell command) so a `client_timeout` means the work *stopped* rather than that
  the caller stopped waiting. The result is kept by id, so
  `client {action:'result', id=...}` collects an outcome even if the window has
  gone in the meantime.
- **A poll carries state.** Every poll posts what the client is and what it last
  did (no probes), which is what makes the awareness above free.

Browser control (`client {action:'browser'|'cdp'}`) lives in
`rust/wa-window/src/cdp.rs`, where a port is never assumed: an endpoint must
prove it is DevTools, the profile's own `DevToolsActivePort` is the authority for
which port Chrome chose, and a launch that hands off to an already-open profile is
reported as itself instead of as a 35-second timeout.

## The database capability

Each interpreter owns its **own** SQLite connection to the node's one WAL
database. Only the plugin runtime and the client bridge are shared. A shared
connection made a transaction one interpreter held open visible to every other
interpreter, and let a rollback there erase a peer's committed row. The
connection lives inside the interpreter's owned `Host`, so it closes (and rolls
back any open transaction) exactly when the interpreter does.

`host.sql_exec`/`host.sql_query` return a statement error as `{error=...}`; they
**never force a rollback**. SQLite permits the caller to recover inside its
transaction, and a forced rollback would silently end it - a Lua caller that
caught the error and wrote again would then autocommit that later write and break
atomicity. A transaction is closed only when:

- the caller runs `ROLLBACK` (or `COMMIT`) itself, or `memory.in_transaction`
  rolls back a failed `fn`;
- a Lua callback error is uncaught at the serve boundary, which calls
  `Lua::rollback_if_open()`; or
- the interpreter's connection drops with the VM, rolling back whatever it held.

Migrations are process-wide and run **once**: `host.db_ready()` reports whether
the schema has been migrated, and `host.mark_db_ready()` records that it has.
Both return exactly one value (`nil` for the marker);
`scripts/test-host-contract.lua` pins that arity. A second interpreter booting
while another holds a write transaction therefore does not replay the DDL and
block on the lock. `:memory:` uses a shared-cache URI so every interpreter sees
one database rather than a silent per-interpreter split.

## Adding a capability

`host.monotonic_ms()` measures elapsed time within a process. Use `host.now()` only
for cross-process event timestamps. `host.runtime_info()` returns version, OS,
architecture, PID and the SHA-256 of the executable (computed once per process).
The Lua loader records hashes in `LOADED_SOURCES` before evaluating each module.
HTTP clients reuse their connection pool. Stream results include provider request
ID, first-content/reasoning/tool-delta latency and `stream_complete`; EOF without
a finish reason is an incomplete response, never an executable partial tool call.
Heartbeat helper threads retain their owning worker ID.

1. Implement `pub extern "C" fn name(l: *mut LuaState) -> c_int` in
   `rust/wa-host/src/host.rs`; return `1` with a value, push `nil` for absent.
2. Register it in `main.rs` (`lua.register("name", host::name)`).
3. Wrap it in a Lua module that tolerates it being missing.
4. Test it on both platforms — `scripts/test-windows.ps1` exists because the
   Linux-only assumptions above all passed on Linux.
