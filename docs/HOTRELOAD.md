# Live reload: the UI and command layer reloads live, no restart

Operator, 13/11 ~06:45: *"i like this live reloads apply this update"*. The model is Claude Code's
`statusLine` - a fresh process per refresh, reading state from files - so an edit shows on the next tick
with no restart. This is that idea taken one step in: a fresh **module** per change, swapped in at the next
frame or command, with the state left where the core keeps it.

Code: `lua/core/reload.lua` (the store, the loader, the watcher, the swap), `lua/core/payload.lua` (the
release source and its signature gate). Test: `scripts/test-hotreload.lua` (in the fast path). Payload
packing: `scripts/hotreload-payload.sh`.

## What is reloadable, and what never is

Four classes, all data in `lua/core/reload.lua`, and `reload.class(path)` is the one answer any caller
gets.

| class | what | reloadable |
| --- | --- | --- |
| `ui` | the render (`cli_view`), every command's balloon, the slash-command registry and `/help`, `/status`, markdown and output formatting, tool titles and result views, the wake line, the skills list, the palette, the panel and local-view channels, `/mcp`, `/nodes`, `/model`, `/login`, `/bind` and the rest of the command layer | **yes**, from a reload source |
| `guard` | the hooks engine, the path guard, the canonical-worktree guard, the progress guard, the code-mode policy, the done gate, the release and payload signature checks, access/binding policy, the vault, `wa land`, `retired`, `redact`, and the reloader itself | never - and never read from a reload source |
| `core` | everything else under `lua/core`: the agent, memory, the provider, the tools, the ledger | never (it owns the session, the run and the database handle) |
| `runtime` | the terminal driver (`rust/wa-term`: raw mode, input, screen buffer, transcript, editor), the interpreter and its capability surface (`rust/wa-capabilities`: `host.rs`, `core_component.rs`, `capabilities.rs`), the process that owns the session (`rust/wa-host/src/main.rs`), `disk_cap` (`disk.rs`), the trusted-key verifier | never: compiled in |

A WASI component (`components.lock`) is installed bytes, not source: at the time of writing, the window's
UI component (`ui/render.wasm`) and every service component are updated by a normal install, and the window
is a client that reloads itself (`AGENTS.md`). Nothing in this mechanism touches a component.

**Why the guard list is a list and not a pattern**: a reviewer can read it, and the test asserts each name.
`scripts/test-hotreload.lua` plants a poisoned `lua/core/hooks.lua` (and a poisoned `reload.lua`,
`path_guard.lua`) in the reload tree and proves none of them reaches the process: guards are loaded from the
node's own source (the embedded tree, or the checkout the process was started from), are never watched, and
`reload.require` refuses a compiled path by name.

## State lives in one store, owned by the core

`reload.store` is created once per process and never replaced. A reloadable module keeps **no** state of
its own, so a swap drops nothing:

| field | what it holds |
| --- | --- |
| `views` | the live `cli_view` objects. Session view state (the run, the phase, the footer's numbers, the rows drawn) *is* the object, so the object is never touched - only the methods it answers with are re-pointed |
| `objects` | every live object a swap has to rebind, with its path |
| `balloon` | the balloon's own state: the stack it last showed, the page, the selection, the published command |
| `scroll` | the output region's anchor |
| `wakes` | the self-wake fact the footer draws |
| `input` | the `cli_input` object - the lines typed while the run was working, and its eof |
| `notices` | one line per failure, with how often it repeated |
| `version`, `swaps`, `failures`, `last`, `stamps`, `checked`, `payload` | the mechanism's own bookkeeping, for `/reload` and the test |

Two caches that used to be module-level tables are in the store now, which is why a swap starts warm rather
than cold: `cli_view`'s restart-notice cache (`restart_notice`) and `local_views`' publish times
(`local_views`).

## The mechanics

1. **Load.** `M.require(path)` answers a stable **proxy**; the module behind it is read lazily (a command's
   module when the command is used) from the reload source when it has one, else from the node's own tree.
   Loading is `load(text, "@<file>", "t", env)` with a **fresh environment** per load: it inherits `_G`
   (so the module still sees `host`, `utf8`, `string`, `pcall`) and its own assignments stay private to that
   copy. `dofile` inside that environment is routed through the reloader, so a reloaded `cli_view` gets the
   reload tree's `markdown`, not the binary's.
2. **Self-check.** The module's own `M.selfcheck` when it exports one, then `PROBE` - which **runs** the new
   code (for `cli_view`: create a view, compose a status line, render a banner, a tool title, a result) -
   because "it parsed" is not "it renders". A module that parses and then raises while drawing is refused.
3. **Swap.** One assignment to the module entry, then the rebind of every live object registered for that
   path. Nothing is ever half-swapped: a caller that has already been entered finishes on the copy it
   entered with, and the next lookup is the new one.
4. **What the reader sees.** A swap draws one dim line (`reloaded commands (reload, 4 ms)`); a refusal draws
   one line and keeps the old module: `reload failed: <path>: <error>`. The same broken file is not re-read
   and re-reported on every frame - the stamp that failed is remembered until the file changes again.
5. **When.** The watcher is ticked at every frame a live view begins (`cli_view`'s framed methods: `paint`,
   `line`, `event`, `answered`, ...) and at every command boundary in the REPL. A run that is streaming is
   drawn event by event while the interpreter is alive, so a reload lands **in the middle of a run** without
   interrupting it - which the test proves with a fake stream.
6. **Nothing costs anything when off.** With no source configured, `M.tick` returns before it asks the host
   anything, and the status line says nothing.

## The two sources

**`dev` - the operator's working tree.** `wa chat --dev <dir>`, or `WASM_AGENT_HOTRELOAD_DEV=<dir>`. `<dir>`
is the directory that contains `lua/` (a checkout's root). The status bar says **`dev reload`** for as long
as it is in use - the row the host's ticker also redraws - and the start prints one line naming the tree,
because a CLI whose commands are not the ones it was installed with is a fact a reader acts on. The tree is
the operator's own code: it is loaded as written, and saying `dev reload` on screen is the whole guard.

**`release` - the installed payload.** On a deployed node, with no flag, the source is the payload beside the
node (`<config>/payload`, `WASM_AGENT_HOTRELOAD_PAYLOAD` to name another) - a committed tree written there by
a deploy, which is what makes a deploy of UI-only changes reach sessions that are already running. It is
accepted only when

- its `SHA256SUMS` verifies against a trusted release key, checked by **this node's own binary**
  (`wa release verify --sums <payload> --quiet`, `rust/wa-host/src/release.rs` - the same verifier
  `scripts/install.sh`, `scripts/upgrade.sh` and the publisher use, reading the keys embedded in the binary,
  `<home>/release-keys.txt` and `WA_RELEASE_KEYS`); and
- **every file that is loaded** matches its line in those signed sums, so a file edited inside a payload after
  it was signed is refused (`payload_file_mismatch: <path>`) instead of loaded.

`change/sign` is on main, so nothing here is accepted unsigned: no signature is `payload_unsigned`, and a
refusal is said once (`payload refused: <reason>`), not once per frame.

Packing a payload from a checkout:

```bash
bash scripts/hotreload-payload.sh <out-dir> [--root <tree>] [--sign]   # writes SHA256SUMS (+ .sig)
bash scripts/hotreload-payload.sh --install [--sign]                  # into <config>/payload, atomically
```

The sums and the signature are the release path's own formats, so the signer is
`scripts/sign-release.sh` run where the vault is (measured 13/11: the vault's admin listener is loopback
only, on the machine that runs the vault). `--install` refuses an unsigned payload: a node would refuse to
load it, and a directory that looks like a source and is dead is worse than none. Wiring the packing step
into the release pipeline (so a *release* carries the payload) is the one piece left for a deploy to do this
by itself, and it belongs where releases are signed - it is not a step a deploying node can perform.

## Using it

```
wa chat --dev ~/wasm-agent            # reload this checkout's UI as it is edited
/reload                               # which tree the UI comes from, what was swapped, what failed
WASM_AGENT_HOTRELOAD_PAYLOAD=/tmp/p   # reload from a payload elsewhere (a candidate)
```

`/reload` is the report: the source, whether a payload verified, the swap count, the last swap and its
cost, and every failure line. The mechanism is invisible by design, so "is it on, and is it reading the tree
I am editing?" has to be a command.

The `/mcp` case, end to end (the one the mission names): `wa chat --dev <tree>`, start any run, edit
`<tree>/lua/core/mcp_cli.lua` or `mcp_command.lua`, type `/mcp` - the next page is the edited one, and the run
that was streaming is still streaming. Nothing about the session, the run or the input changes.

## Measured (this node, 13/11, `scripts/test-hotreload.lua`)

The row prints three numbers and asserts on them:

```
hotreload: save to visible 3 ms (plus the 250 ms dev throttle at most); scan 0.06 ms;
           status frame 0.065 ms scanning, 0.000 ms watched, 0.001 ms unwatched
```

- **save to visible**: one tick's whole path - directory listing, read, `load`, self-check, swap, rebind -
is 3-6 ms measured across runs. The reader-visible latency adds at most the throttle (250 ms in dev, 2 s for
a payload), so it is well under the one-second target.
- **scan**: one `host.list_dir` of `lua/core` (126 entries) per throttle window - 0.06-0.25 ms. The listing
  carries `size` and `modified`, so one call stamps every watched file.
- **per frame**: a frame whose scan is due costs 0.06-0.15 ms (the scan plus the clock comparison); a frame
  that is not due costs ~1-2 µs, which is a `host.now()` and a branch; with no source at all, 1-2 µs.
  `scripts/fast.sh` therefore times the same as before.

The `/mcp` case is proved end to end in the same row: with a run streaming, `mcp_command.lua` is edited in the
reload tree, its swap lands as its own line, the next `mcp_cli.views` answers the changed page title, and the
run keeps its counters and finishes normally.

## Risks and limits, named

- **A captured function is not re-pointed.** `local f = cli_view.paint` taken before a swap calls the old
  copy until the caller reloads. The rule for the UI layer is therefore: hold the proxy, or ask it each
  time - which is why `chat.lua`'s `HELP` became `help()`.
- **A changed interface is a load-time error.** A reloaded module whose API dropped something a live caller
  needs will fail at that caller, not at the swap. The self-check narrows this; it cannot remove it.
- **A guard can never be swapped, and that is deliberate**: the hooks engine, the path guard, the release
  checks and this file itself are outside the mechanism, and the test proves a poisoned copy is ignored.
- **A payload is signed by the vault.** A node that cannot reach the vault cannot sign a payload, so it
  cannot roll one out either - the same constraint releases already have.
- **The payload signature check costs one process per change** (`wa release verify`), at most once per
  payload change, not per tick.
- **A streaming run's frame may use one copy and the next the other.** That is the design: the swap is at a
  frame boundary, so a single drawn frame is never half of each.
