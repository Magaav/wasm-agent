# sandbox-base64: a script that reaches for Buffer, a timer or base64 gets an answer

Branch `change/sandbox-base64`, base `ee38c015`, one commit: **30e60405** ("sandbox-base64: sleep,
named fix lines for a missing global, btoa/atob wrapped, one tail sentence"). Everything below cites that
commit, a file:line in it, or the measurement that produced it.

## The brief's premises, re-measured

| premise | measured | verdict |
|---|---|---|
| "the codemode sandbox has no Buffer/btoa" | `btoa("hi")` answers `aGk=` and `atob("aGk=")` answers `hi` on the BASE commit `ee38c015` (pinned QuickJS, `WASM_SHA` in `rust/wa-capabilities/src/quickjs.rs:15`) | **btoa/atob already existed.** `Buffer` does not. The turn note's ReferenceError was Buffer, and that one is real. |
| "count ReferenceErrors by missing name, 3 days" | over the whole retained ledger (`~/.wasm-agent/tool-results`, every `run` result whose fix line came from `lua/core/codemode.lua`) the names that are not a script's own variable: `setTimeout` 40, `Buffer` 17, `HOME` 16, `location` 12, `require` 6, `btoa`/`atob` **0**. Filtered to the last 3 days: `setTimeout` 20, `Buffer` 7, `require` 2, `location` 2 | a timer was the most common reach, Buffer second; base64 never. |
| "the last sentence is printed twice (codemode.lua, the sites near :879-:919)" | the two sites each print it ONCE. The doubling is a NESTED refusal: a script calling `tools.run` gets the inner script's fix, which already ends with the sentence, and the outer `explain` appended it again. Reproduced from the ledger (tool result `0bcc0eea73ca...`, 22/11 11:37) and by a probe before the change | the site was different; the defect was real. |
| "tools.remote runs a peer's `write` with the content as a string" | true for a single call: `remote` hands the capability to the peer's own dispatcher (`lua/core/server.lua:1557`, `toolslib.dispatch(memory, capability, args, ...)`) and only a `calls` batch is fenced to reads (`lua/core/tools.lua:1280`) | the peer write shape is in the fix line. The `remote` SCHEMA text still says "effects run here, outside" (`lua/core/tools.lua:559`) - stale against `docs/CODEMODE.md` line 305 ("a script may now change a peer as well as read it"). Left alone: it is model-facing, and item 3 said to prefer the fix line. |

## What the change is

1. **`sleep(ms)`** - the one pause, 0..5000 ms, a guest global answered by the loop in the HOST
   (`lua/core/codemode.lua:264` `SLEEP_MS_MAX`, `:617` the registration, the `sleep` branch in
   `host_global`), where the sandbox's computing clock is stopped (`rust/wa-capabilities/src/quickjs.rs`,
   the `admit`/`deliver` pause/resume a tool call already had) - so a pause spends none of the script's
   budget. Past the cap: `codemode_sleep_too_long`, whose fix names `wait_s`/`wait(op)`/`pending()`
   (`lua/core/refusal.lua:254-257`). Component side: `sleep` in `HOST_GLOBALS` and `GUEST_GLOBALS`
   (`rust/components/codemode/src/logic.rs:63`, `:82`).
2. **`btoa`/`atob`** - wrappers over the runtime's OWN encoder (`lua/core/codemode_harness.lua:231-247`):
   same bytes, same speed, no JavaScript loop over a large body; they replace one message - text above
   U+00FF, where the standard's per-byte rule throws a bare `InvalidCharacterError`, now names
   `unescape(encodeURIComponent(...))` and its inverse. No `Buffer` polyfill: 17 reaches against the
   timer's 40, and a body has a string route (below).
3. **A named fix line for a missing global** - `GLOBAL_FIX` (`lua/core/codemode.lua:900`) is an
   ALLOW-LIST: `setTimeout`/`setInterval`/`clearTimeout`/`clearInterval` → `sleep`; `Buffer` → a string
   to `tools.write`, the flat `tools.remote` write for a peer, `raw` for bytes, `btoa`/`atob`;
   `require`/`module`/`exports`/`process`/`fs`/`path`/`__dirname` → "this is not Node" plus the tools;
   `location`/`window`/`document`/`navigator`/`localStorage`/`alert` → "there is no browser in a
   script"; `HOME` → the `printenv` command; `fetch`/`XMLHttpRequest`/`WebSocket` → `curl`. A name
   outside it (`wt`, `raw`) keeps the generic "Change line N", because nothing there can say what the
   script meant. Wired in `explain` at `lua/core/codemode.lua:1014`.
4. **The closing sentence, once** - `fixed_tail` (`lua/core/codemode.lua:918`) appends the tail only when
   the fix does not already carry it; used by the generic branch and by the timeout branch.
5. **Docs**: `docs/CODEMODE.md` gains "A pause, and base64 (22/11)".

## Tests

* `scripts/test-codemode-globals.lua` - **new**, 22 checks, its own scratch home through
  `scripts/lib/test-home-guard.lua` (it refuses a live one). Covers: `btoa("hi")`=`aGk=` and the inverse,
  padding for 1/2/3 bytes, one-character-per-byte plus the UTF-8 round trip the message names, the
  U+00FF sentence, a bad `atob`; `sleep(150)` reporting `slept_ms` and moving `Date.now` by >= 120 ms,
  the cap and the non-number refusals; the `Buffer` fix naming `raw.script`, `capability: "write"` and
  `btoa`; `setTimeout` → `await sleep(ms)`; `HOME` → `printenv HOME`; `require` → "This is not Node";
  `location` → "There is no browser in a script"; `fetch` → `curl -s`; a name nobody can explain keeps
  "Change line 1"; and a nested `run` refusal printing "No call had succeeded yet." exactly once.
* **Wiring**: `scripts/fast.sh` runs every `scripts/test-*.lua` row (its own comment: "every
  scripts/test-*.lua not listed in scripts/fast-path.exclude"); the new file is not in that exclude list.
  No `test.sh` edit was needed - it does not name these rows individually.
* **It fails on the base**: run against a separate worktree of `ee38c015` (`git worktree add /tmp/base-ee38
  ee38c015`, never `git stash`), the row stops at check 6, "text above U+00FF says the UTF-8 route"
  (`InvalidCharacterError: String contains an invalid character` plus the generic fix). The first five
  checks PASS on the base, because the runtime already had `btoa`/`atob` - stated here so nobody reads
  that as the row discriminating on item 1.
* **Rust**: `rust/components/codemode` `cargo test`: 15/15 green, including the new
  `logic::tests::sleep_is_a_guest_global_the_loop_answers` (`logic.rs:983`) and the node-for-node parity
  assertion in `src/lib.rs` that used to say "nine globals" - it now says ten and names `sleep` at index 5
  with the same strictness (every earlier assertion kept, one added).
* **Component path**: the component built from this tree (`scripts/build-components.sh codemode`) and run
  against it gives `codemode seam: 48 checks, 20 parity comparisons, 0 skipped`, and the new row passes
  through the component loop too (`{"checks":22,"ok":true}` with `WA_CODEMODE_COMPONENT=1`).
* **Nothing else moved**: `test-codemode-errors` (10), `test-codemode-promises` (31), `test-codemode-boundary` (33),
  `test-codemode-presentation` (46), `test-codemode-wait-shape` (25), `test-codemode-reuse` (26),
  `test-codemode-default` (39), `test-codemode-parity` (56), `test-codemode-pending` (92),
  `test-session-vars` (48), `test-codemode-counters` (29), `test-refusal-contract` (17036),
  `test-prompt-cache` (195), `test-prompt-golden` (20), `test-host-return-docs` (10) - all green.
* `lua/core/refusal_codes.lua` regenerated (`lua5.4 scripts/gen-refusal-codes.lua --write`, +2 codes); the
  refusal contract test fails without it, and it was the check that caught it.

## The fast path, on this branch

`flock -o ~/Work/missions/.suite.lock ... bash scripts/fast.sh --jobs 8` (commit ecd9c25c, the tree's own
release binary, `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-sandbox-base64`):

    fast result FAILED (388 checks, 1 failed, 1 skipped)
    fast path FAILED (1 of 388 checks, 1 skipped, 435s)

* the one FAIL is `install-guards` - "test-install-guards: 72 checks, 3 failed" - and it fails the same
  way on the base worktree `/tmp/base-ee38` (see below): the installer guards, not this change.
* the one SKIP is the bytes half of `component-pins`: it cannot find a copy of the new codemode pin on
  this node (`2f432ec04ea1…`). Pointed at the artifact this tree built
  (`WA_PINNED_COMPONENTS_DIR=/tmp/comps-base64`) the same check verifies it, and says "source and pin
  moved together". A skip is not a pass, so it is stated rather than counted.

## Round 2: the preflight's merge conflict, and the repin that follows it

The landing gate stopped before running a row: `land-quick: merge conflict with main bcb5c5ce in: components.lock`. Main
had repinned `codemode` to `c942620dffa4...` (225,166 bytes) from `change/search-miss-names-cli`, and that
change ALSO edits `rust/components/codemode/src/logic.rs` - so the conflict was not a lock file disagreeing
about a number, it was two sources for the same component.

* Commit **99e817a8**: the branch is rebased onto `bcb5c5ce` (the rebase merged `logic.rs` and
  `lua/core/refusal_codes.lua` on its own; only `components.lock` conflicted), the lock keeps MAIN's block,
  and the component is rebuilt from the MERGED source and pinned again:
  `codemode 9091cd796ecceaf186c1a5a49619986c02d9422f79149f3f43c083a82d3829f9 225184`, with a comment
  block that says what moved (the guest globals gain `sleep(ms)`, and the two `codemode_sleep_*` codes come
  with it). `scripts/test-component-pins.sh` with `WA_PINNED_COMPONENTS_DIR=/tmp/comps-b64b` answers
  'source and pin moved together' and 'verified codemode: 9091cd796ecc... 225184 bytes ... the bytes this node
  would INSTALL ARE the pin'.
* Component tests after the rebase: 16/16 (main's keyword-miss test plus
  `sleep_is_a_guest_global_the_loop_answers`); the seam's own parity: 50 checks, 21 parity comparisons,
  0 skipped, with the component built from the merged tree - and the new row through the component loop:
  `{checks:22, ok:true}`. The Lua rows that touch this: codemode errors 10, promises 31, boundary 33,
  refusal contract 17122 - all green.
* The full fast path on the rebased branch (commit 99e817a8, the tree's own release binary):
  `fast result FAILED (392 checks, 2 failed, 1 skipped)`. The two:
  - `install-guards`: identical on the base worktree - the installer guards, nothing this branch touches;
  - `scripts/test-start-instant.lua`: `start-instant: 1 FAIL` under 8 parallel rows. It measures a turn's
    latency and passed three times alone afterwards (once with the same tree binary, twice more): a load
    flake on a node running other missions' suites, which is the class the runner's own classifier names.
    No test was loosened for it and no timeout raised.
  The skip is the same component-pins bytes half as in round 1, verified by hand with the artifact dir.

## The component pin

`rust/components/codemode/src/logic.rs` is compiled into the `codemode` component, so the guest-global
list moved the wasm bytes and `scripts/test-component-pins.sh` refused the branch until the pin moved
with the source. Commit **192c7f55** rebuilds it (`WA_COMPONENTS_DIR=/tmp/comps-base64 bash
scripts/build-components.sh codemode`) and pins `codemode 2f432ec04ea1051ebae3a8c38b660c41d0478219117436b2463bc995119e270a
224319` in `components.lock`. With `WA_PINNED_COMPONENTS_DIR=/tmp/comps-base64` that check says
"verified codemode: 2f432ec04ea1… 224319 bytes … the bytes this node would INSTALL ARE the pin" and
"source and pin moved together". Without it the check SKIPs the bytes half - it cannot find a copy of the
pin anywhere on this node, which is the honest state: `scripts/publish-components.sh --from` refuses a
commit "reachable from no branch the REMOTE has" and this mission does not push, so the release artifact
for that pin does not exist yet and landing/deploying has to publish it.

## Prompt cache

No file that composes the model's prefix changed: the codemode tool's schema string
(`lua/core/tools.lua:839`) and the `remote` schema (`:559`) are untouched, and `docs/CODEMODE.md` is not
read into the prompt (only cited in code comments). The new text is per-call: a fix line and two refusal
codes. So the prefix - and the provider cache - is unchanged; nothing is re-paid.

## Pre-existing failures on this node (not caused by this branch)

Measured by running each against the base worktree `/tmp/base-ee38` with the same binary:

* `scripts/test-codemode-native.lua` - `opt-in adds one tool, direct tools retained` (needs a node built
  with the tree's prepared assets).
* `scripts/test-codemode-unprepared.lua` - `default build honestly reports assets not embedded` (same
  cause: the binary is not this tree's).
* `scripts/test-remote-refusals.lua` - `node refusal through the relay` (needs a relay).
* `scripts/test-install-guards.sh` - "test-install-guards: 72 checks, 3 failed" on the same base worktree, with the same shell: the installer guards, nothing this branch touches.

## Texts to approve

1. `sleep` refusal, not a number: message "`sleep` was given something that is not a number of
   milliseconds (this node)." / fix "call `await sleep(ms)` with a whole number of milliseconds from 0 to
   5000."
2. `sleep` past the cap: message "`sleep` was asked to pause for longer than one call may (this node)." /
   fix "`sleep` pauses at most 5000 ms. To wait for work, give the call a `wait_s` option or call
   `wait(op)`; `pending()` lists what is still running."
3. `codemode_global_not_available` fix (changed): "the globals a script has are `searchTools`,
   `results`, `wait`, `cancel`, `pending`, `sleep`, `describeTool`, `showCall`, `capabilities` and
   `describe`, plus one member per callable tool on `tools`."
4. Buffer fix (verbatim from a run): "There is no Buffer in this sandbox: a file body is a string, so
   tools.write({path, content}) writes it here and tools.remote({node: "<name>", capability: "write",
   path: "<path>", content: "<text>"}) puts it on a peer in one call. Bytes that must not pass through
   JavaScript go in the run call's raw argument (raw: {script: "..."}) and reach the script as raw.script.
   Base64 is built in: btoa, atob. Change line 1 and run the script again. No call had succeeded yet."
5. Timers fix: "There are no timers in this sandbox: pause with await sleep(ms) - 0 to 5000 ms, in the
   host, so it spends none of the script's budget - and wait on work with the call's wait_s option or
   wait(op)."
6. Not-Node fix: "This is not Node: a script has no require, module, process or fs. Run a command with
   await tools.bash({command: "..."}), and read, write or search files with tools.read, tools.write,
   tools.ls and tools.grep."
7. No-browser fix: "There is no browser in a script: no window, document, location or navigator. Read
   this node with tools.read, tools.ls and tools.bash, get its time with tools.time, and the user's own
   browser is the client tool."
8. No-network fix: "A script has no network: fetch an address with await tools.bash({command: "curl -s
   <url>"}), and reach another node with the nodes and remote tools - a remote call is how a script runs
   a tool on a peer." (the fenced form is a `calls` BATCH, reads only - lua/core/tools.lua:1280; a single
   remote call may be an effect.)
9. `HOME` fix: "There are no environment variables in a script: read one with `await
   tools.bash({command: "printenv HOME"})` - a command runs with this node's environment."
10. `btoa` above U+00FF: "btoa takes one character per byte and this text goes above U+00FF. For UTF-8
    text use btoa(unescape(encodeURIComponent(text))), and read it back with
    decodeURIComponent(escape(atob(text)))."
11. `atob` on text that is not base64: "atob takes base64 text: A-Z, a-z, 0-9, + and / with = padding,
    and nothing else (...the runtime's own sentence...)."

## Not done, and what is unknown

* The `remote` schema's stale "effects run here, outside" sentence (`lua/core/tools.lua:559`) is left as
  it is on purpose (model-facing text, and item 3 said the fix line is the cheaper place). It is a real
  contradiction with `docs/CODEMODE.md:305` and deserves its own round.
* No UTF-8 HELPERS beyond the message: the count said base64 was never reached, so `btoa`/`atob` stay the
  standard two.
* `sleep` really sleeps the node's Lua thread (`host.sleep`, `rust/wa-capabilities/src/host.rs:1900`),
  which is the thread already running the script; it is capped at 5000 ms per call and a script cannot
  loop forever because its computing budget is not what pays for the pause. A script that calls
  `sleep` 100 times in a row can still hold the thread for ~8 minutes: not measured, not bounded, stated.
