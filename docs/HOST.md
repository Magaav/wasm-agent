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

`host.exec(command, cwd, timeout_seconds?)` is the synchronous facade for an owned
**operation**; the optional third argument bounds it (1-86400 seconds, the configured
default when omitted). `host.operation`
exposes explicit launch receipts, status, cursor-based output, bounded waits and
cancellation; `host.jobs` manages automation definitions/enable state, never executes
a job itself. Both always return one JSON value, including failure. Do not add a
second shell runner with `Command::output`, `read_to_end` or detached reader threads.
See [OPERATIONS.md](OPERATIONS.md) and [JOBS.md](JOBS.md) for contracts, platform
limits, authority, recovery and the regression tests.
## Bounded image reads

`host.read_file` remains UTF-8 text only. `host.read_image_base64(path,max_bytes)` first
sniffs PNG, JPEG, WebP and GIF magic bytes, then reads at most the caller's explicit
bound and returns a JSON envelope with MIME, byte count and base64. `not_image` tells Lua
to continue through the text reader; missing, unsupported and oversized inputs are
separate visible errors. MIME is never trusted from the extension.

The base64 exists only to cross the Lua/WIT seam. Lua stores the image through the
content-addressed attachment path, removes its private reference from the textual tool
result, and materialises bytes only while constructing a provider request. The `read`
tool therefore stays one operation for text and images without putting base64 into the
ledger.

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

## The code graph

`host.graph_index|query|explain|path|caps|stats|status` expose `wa-graph`'s SQLite
index of the source tree to Lua. The graph lives beside the ledger
(`<home>/.wasm-agent/graph.db`) and indexes the runtime worktree — the node's cwd —
which is the source the binary is actually running from. `WA_GRAPH_ROOT` and
`WA_GRAPH_DB` override both; `WA_GRAPH_WATCH=0` disables the watcher.

Reads pin a read-only database snapshot and compare every in-scope file's exact
bytes before and after answering. A stale or unbuilt graph is rebuilt
synchronously, or returns an explicit error; it cannot appear as an empty answer.
That refresh may take the write lock. `host.graph_index` is also a write path and
is incremental by content hash, so a repeat with nothing changed reparses nothing.
A whole index run is one `BEGIN IMMEDIATE` transaction, so a reader sees the old
graph or the new one - never a half-indexed file - and the watcher and a manual
index cannot interleave.

Every verb returns a JSON string, and an error as `{"error": ...}` — the same
shape as `host.sql_query`. On a node whose host predates the capability the
globals are absent; `lua/core/graph.lua` tolerates that and reports
`graph_unavailable`, and the `graph` tool checks for it before calling.

The watcher is a `notify` thread started only for `serve`. It registers before indexing once on
startup (off the accept path, so a large tree never delays the port) and reindexes
on change, debounced so one save's burst is one parse. Watcher errors are logged;
query-time verification is the correctness backstop. This verifies a source
snapshot, not the version already loaded into a running Lua worker.

## Drawing while Lua is blocked

`host.ticker(spec_json)` is the one capability that draws, and it exists for a single
structural reason: the CLI keeps a status line on screen for as long as a run is in
flight, and the interpreter spends most of that time blocked inside `host.http_stream`,
so nothing on the Lua side can repaint it. A run that is thinking and a run that is hung
looked identical - a frozen frame and a clock that had stopped.

The host runs a timer thread and draws the same line the view would have drawn. The line
stays Lua's: `spec.line` is that line with exactly two tokens left in it, `{m}` (one of
`spec.marks`, a JSON array, cycled per tick) and `{t}` (the seconds since `spec.started`).
The indent, the words, the separators and the round counter are the caller's text, so the
animated line and the printed line cannot drift apart.

- One ticker per process, drawn on that process's own stdout. The view only starts it when
  its output *is* stdout, so a captured transcript never has a second writer.
- **The row it draws on is the reader's row.** A run is exactly when a reader types, the terminal
  echoes at the cursor, and the cursor sits at the end of this line. So a frame rewrites only the
  columns it drew (a shorter line is padded with spaces, never `\27[2K`, which would erase the
  message they are halfway through typing), commits the row with a newline when it needs more room
  rather than writing over columns that may now hold their text, and saves and restores the cursor
  (`ESC 7` / `ESC 8`) around the write. `cli_view.status_draw` obeys the same rule on the Lua side,
  because the view writes this line too. A terminal that ignores `ESC 7`/`ESC 8` garbles the
  *display* of a line typed during a run and loses nothing: the line is read from the reader thread,
  never from the screen.
- Stopping is immediate - the thread waits on a condition variable, not on a sleep - and the
  caller stops it before writing anything else: two writers on one line is how a line
  becomes two half-lines.
- The clock's shape (`59.9s`, `1m00s`, `2m05s`) is the twin of `cli_view.duration`, because
  the elapsed time of a call that has not finished cannot be computed by the side that is
  blocked. Both sides pin those three values in their own tests, so a one-sided change fails
  a test rather than a frame on a screen.
- `WASM_AGENT_CLI_TICKER=off` disables the motion for a caller that wants the sequences
  without it.

`scripts/test-cli-ticker.lua` measures the timer for real: it starts a ticker, then sleeps -
so it cannot repaint anything itself - and the gate reads the frames and the clock out of
its captured stdout.

## Input that arrives while Lua is blocked

`host.input_start()`, `host.input_take(timeout_ms)` and `host.input_stop()` are the ticker's
mirror image. The status line exists because the interpreter cannot repaint while it is blocked;
this exists because the interpreter cannot *read* while it is blocked. `wa chat` used to call
`io.read("*l")` between turns, so while a run was in flight nothing read stdin at all: a reader
typing their next message typed into a stream nobody was looking at, and the line was lost. pi and
codex do not lock input, and a reader compared them to this, correctly.

So a thread of the host reads stdin for the life of the process, and Lua takes what arrived when
it next runs.

- `input_start()` starts it, once per process; a second call is still `true` and does not add a
  second reader - two readers would split the reader's typing between two queues and neither
  caller would see the whole of it.
- `input_take(timeout_ms)` waits up to that long for at least one line and answers
  `{lines, eof, running}`. **`lines` is an array and never a missing value**: "nothing typed yet"
  is not "no console", and a caller that cannot tell the two apart stops on a keystroke that has
  simply not happened yet. `timeout_ms` of 0 is "take what is there now".
- `input_stop()` asks the thread to stop and does **not** join it: it is blocked in a read that no
  portable call can interrupt, and making the process exit wait for the reader to type one more
  line is a worse answer than one thread dying with the process.
- The console is left in the terminal's own mode. This puts nothing into raw mode and echoes
  nothing itself, so line editing, the echo and Enter stay the terminal's, as for any shell. What
  changes is who reads the line, and that a line typed during a run is still there when it ends.
- `lua/core/cli_input.lua` is the Lua side, and tolerates the capability being absent (an older
  binary) by falling back to the blocking read it replaced.

What this does **not** do, deliberately: raw-mode input, per-key editing, an interrupt key, and
multi-line input all need the terminal handed over (raw mode plus a frame the CLI owns), which is a
larger change than reading the reader's lines.

`scripts/test-cli-input.lua` is observed through a real child process, like the ticker's test and
for the same reason: the reader is a thread, so the only honest evidence is that process's own
behaviour. Its producer on stdin writes the second line **while the script is asleep**, which is
the one arrangement that distinguishes a reader thread from a read in the REPL: with `io.read`
that line would have arrived to nobody.

## The console's size

`host.terminal_size()` returns `{columns, rows}` for the console this process draws on, or
`nil` when there is none to ask. It exists because the width a terminal *has* is not the
width a child *knows*: `COLUMNS` is a shell variable on most machines and is not exported
to children, so a CLI that wrapped to `COLUMNS or 80` drew in an 80-column column inside a
120-column window - measured, with `COLUMNS` empty, in the terminal the CLI actually runs
in. `lua/core/platform.columns()` is the Lua side of it: the console first, `COLUMNS`
second, 80 last.

- `nil`, never a zero. A detached or uninitialized console answers *successfully* with
  0x0 rather than failing, and a caller told "80 columns wide by 0 rows" would wrap every
  line to nothing - a blank screen, which is worse than the fallback it replaced.
- The console is asked about **stdout**, not stderr or stdin, because that is where the
  caller draws. A redirected stdout (a transcript, a log) therefore gets `nil`, which is
  the honest answer: there is no width to wrap to.

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
