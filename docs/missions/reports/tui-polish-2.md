# TUI polish 2 - four findings from avell, 18/11

Worktree `/home/victor/Work/missions/tui-polish-2/wt`, branch `change/tui-polish-2`, base
`origin/main 44229140`. Built and tested on this node (avell) only. Committed locally, not pushed.

Each item below is one test that fails on the base and passes here, run with a scratch HOME and
`WASM_AGENT_LUA_ROOT=<worktree>`, and no real node.

---

## Item 1 - the node-wide aggregate, drawn dim, never a named row

The backend (per-session progress rows, `node: N ops elsewhere`) lives in
`change/session-isolation` and is **not landed**. This is the TUI half, built against that branch's
function name with a fallback that says nothing until it lands.

| | |
|---|---|
| backend names used | `tool_progress.elsewhere({now, session})`, `tool_progress.elsewhere_text(count)` |
| TUI side | `cli_view.lua` `METHODS:elsewhere_text`; drawn by `METHODS:status_template` |
| test | `scripts/test-cli-welcome.lua` |

**Fallback, stated plainly.** `M.elsewhere` is only called when the module actually has it
(`type(module.elsewhere) == "function"`). On this tree, which does not have it, `elsewhere_text()`
returns `nil` and the status row says nothing about other sessions - the view never invents a count
it cannot read. When the branch lands, the same call returns the count and the row says
`node: N ops elsewhere`, dim, with no tool name, no session id and no line of anybody's output
(asserted, including the three leaks the old node-wide row had).

Strings, verbatim: `node: 1 op elsewhere`, `node: N ops elsewhere`.

## Item 2 - components follow a terminal resize

The width was measured once, before the welcome box, and cached for the life of the process. The
host redrew the input rule and the footer from its own size, so those followed a resize while the
welcome rule, the welcome box, the code-mode box and the rest did not.

**Measured on the base** (a chat created at 80 columns, then maximised to a 200-column terminal):

```
BEFORE terminal=200 drawn_rule=80
AFTER  terminal=200 drawn_rule=200
```

What changed:

* `cli_view.lua` `METHODS:refresh_limit` - the terminal's width, read again. Called at every frame
  boundary (the `FRAMED` wrapper) and by `screen_on`, so a frame's components are laid out from the
  width the terminal has now. A console that will not answer (a pipe, a CI log) or answers nonsense
  keeps the width the view already had; `M.MIN_COLUMNS = 24` is the floor.
* `cli_view.lua` `M.RULE` / `M.expand_rules` / `METHODS:rule` - a rule is written as a marker and
  expanded where the width is known. The banner's divider is the marker, not `string.rep("\u{2500}", limit)`.
* `rust/wa-term/src/transcript.rs` `expand_rule` - the native editor expands the marker **per draw**,
  because a transcript outlives a resize. Plain layout expands at write time (a line written once).
* `chat.lua` no longer passes a one-time `terminal_columns()` as the banner's width.

Inventory of what was checked: welcome box + its top rule, code-mode block, status row, footer,
the aggregate row. Each is rendered at 80, at 200 and back at 60, and no drawn row is wider than the
terminal (a row wider than the terminal wraps - the bounce Victor saw).

Tests: `scripts/test-cli-resize.lua` (54 checks, Lua) and
`rust/wa-term` `a_rule_is_drawn_at_the_width_of_the_frame_and_never_at_the_width_it_was_written`.

## Item 3 - the welcome line says WHY there is no provider

**This is the text that would land. Shown for approval before it does** (Victor: show the exact text):

```
model: none - this shell has no provider env; the node's wa-serve has one: run inside it with `wa chat` via the node, or /login
```

That sentence is the **default** cause: no key, no vault in this environment, while the node runs a
provider. Two other causes are distinguished, and each is *measured*, not assumed:

* model-less node: `this node is declared model-less (<source>, docs/MODEL-LESS.md), so no turn can run here`
* vault set but not answering: `the vault at <url> did not answer (<code>), and the provider is reached through it; check wa-vault, or /login`
* model not served by the route: `the model <id> is not served by this route; pick one with /model`

A note on the vault branch, because it corrected me: on this machine `WASM_AGENT_VAULT_URL` **is**
set and the vault on `:8810` **is** listening. A branch that fired on the variable alone would have
named a false cause; the branch therefore asks the vault its own status and prints the sentence above
when the vault answers. The older sentence `local mode (no model configured)` is gone.

Banner (measured, 120 columns):

```
────────────────────────────────────────────────────────────
✻ Welcome to wasm-agent! v44229140+dirty

/help for help, /login to sign in to a provider

cwd: ~/work/wasm-agent (change/tui-polish-2)
model: none - this shell has no provider env; the node's wa-serve has one: run inside it with `wa chat` via the node, o…
session: abc
```

Test: `scripts/test-cli-welcome.lua`.

## Item 4 - the welcome version is the running build, not a literal

`chat.lua` passed `version = "0.1.0"`; it now passes `build_identity.label()`. One function composes
the identity, and the banner, `wa --version`, `/health` and the update banner read it.

| case | label |
|---|---|
| dev / tree build | `e5ba9089` |
| dirty tree | `e5ba9089+dirty` |
| installed from a release | `node-e5ba908921e8` |
| pinned node | `fc6a9d80 (pinned)` |
| cannot name itself | `unknown build` |

Authorities, in order: **pin** (most specific fact about this node) > **release** (installed from one)
> **build** (the bytes' own compiled-in label) > **unknown** (never a made-up number).

Where it comes from: `rust/wa-host/build.rs` compiles commit/tree/dirty/ancestry into the binary
(`wa --build-info`, existing); `build_info::label()` composes the short name; `install_label()` adds
the release from `installed.txt` and the pin from `<config>/pins.txt`; `main.rs` states it once at
boot through `wa_capabilities::host::set_build_identity`, and Lua reads it via the new
`host.build_identity()` capability (`lua/core/build_identity.lua`, registered in the inventory and
in `docs/HOST.md`).

Measured on this node: `wa --version` -> `wasm-agent 44229140+dirty` (base said `wasm-agent 0.1.0`).

The update banner now fills `commit=` from the running build when the record cannot say it, so
"installed" is the same identity. It still refuses to guess: a build that cannot name itself leaves
the record alone and the answer stays `unknown`. `/health` carries the same string as `build`.

Test: `scripts/test-build-identity.lua` (12 checks).

---

## Pre-existing failures, named

`scripts/test-hotreload.lua`: **5 of 217 checks fail on this tree, and identically on the base**
(stashed and re-run), in the release-payload signature checks
(`payload_signature_invalid` / `payload_file_mismatch`). Not caused by, and not fixed by, this work.

`scripts/test-tool-progress.lua`: **11 of 78 checks fail on this tree AND on the base**, and on the installed binary as well (reproduced three ways). The failing rows are the live-row ones whose fixture depends on the machine's tool-progress file (`two seconds is long enough to say something`, `a live call is the tool kind`, the stall rows). Not caused by, and not fixed by, this work.

`scripts/test-status.lua` fails under the **debug** binary with `codemode_not_enabled` - the debug
build carries no code-mode assets; the same Lua passes 14/14 under the installed binary. Not a
code failure.

## What I did not verify

* A real terminal resize on screen (no real node or pty here): the width behaviour is asserted
  through `refresh_limit`, the banner, the components and the Rust transcript's draw-time expansion,
  not by resizing a window.
* The per-session backend itself: not landed on this base, so item 1's count is exercised against a
  stub module and the fallback (silence) is what this tree actually does.
* `/health`'s new `build` field: asserted by the build and by the capability inventory test, not by
  fetching a running node's `/health` (that would need a deploy, which this mission excludes).

