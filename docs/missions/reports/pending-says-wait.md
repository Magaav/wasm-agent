# pending-says-wait: a pending answer names its own next step

Branch `change/pending-says-wait`, base `ee38c015`. Victor, 22/11, quoting a model's turn note: "my
tools.remote calls keep flipping to a pending peer operation on long test runs, and reading the result
costs two extra round-trips (operation await then read) with no hint of that in the first payload beyond
a bare id".

## Re-measured first (the brief's facts, checked)

**1. What the model did after the pending answer of session fece6285, 22/11 11:21:04Z.**
Session `fece6285-fa88-4dc3-819a-399ec172546f`, tool message seq 137, 617 bytes (the stored row says
`calls: <sha>:617`), the handle verbatim:

```
{"log_path":"/home/ubuntu/.wasm-agent/operations/op-1795346372669326-3755147-6253/stdout",
 "node":"nextcloud","op":"op-1795346372669326-3755147-6253",
 "operation_id":"op-1795346372669326-3755147-6253","output_bytes":629,
 "progress":{"elapsed_ms":91732,"node":"nextcloud","op":"op-1795346372669326-3755147-6253",
             "output_bytes":629,"state":"running"},
 "settled":false,"state":"pending","state_name":"running",
 "stderr_path":"/home/ubuntu/.wasm-agent/operations/op-1795346372669326-3755147-6253/stderr",
 "stdout_path":"/home/ubuntu/.wasm-agent/operations/op-1795346372669326-3755147-6253/stdout",
 "tool":"remote","waited_s":60}
```

The op id is written three times and the stdout path twice, and nothing names `wait(op)` - the brief's
reading of the payload is exact. Its **next two calls** were seq 138 `run` calling
`tools.capabilities()` and seq 140 `run` calling
`tools.remote({node:"nextcloud", capability:"operation", action:"list"})` - the peer's operation
surface, i.e. the two-round-trip read. Not one `wait(` call.

**2. How often, over the last three days.** Read through the supported ledger surface
(`search_messages`, `match:"phrase"`, `scope:"all"`, `query:'"waited_s"'`, the twelve six-hour windows
of 19/11 14:37Z to 22/11 14:37Z; each hit's next assistant call read with `session{around_seq,after:2}`):

* **23** code-mode pending-handle tool messages in the window.
* the model's very next call was `tools.operation({action:"await"|"read"})` in **12 of 23 (52%)**;
  a bash follow-up, a file write or `capabilities()` in 11; `wait(` in **0 of 23**.
* Coverage: 5 of the 12 six-hour windows refused with `search_page_budget_too_small`, so 23 is a
  **floor**, not a total. The direction is unambiguous; the exact count is not claimed.

**Premises that were stale or incomplete.**
* "About 620 characters" is a **remote** number. A **local** `bash` handle's model copy is 908 bytes in
  the tests' own scratch home (long local paths), and its `progress` carries no `op`/`node` - only the
  remote executor repeats those there (`lua/core/codemode_pending.lua`, `operation_progress` vs the
  remote `progress`).
* `bash` and `operation` define **no** `cancel` in `M.EXECUTORS`; their `cancel(op)` works through the
  generic local-operation branch of `M.cancel`. So "not cancellable" is not "this kind has no cancel
  function" - it is the outbox without a draft (`a sent message stays sent`) or a kind that sets
  `cancel=false`.

## What changed

* `81e36041` - `lua/core/codemode_pending.lua`: `stoppable(record)` and `next_step(record)`, and
  `handle()` now carries `next`; `invoke()` copies `started.draft` into the record, so a draft outbox
  handle - the one outbox handle a cancel can stop - is told so. One field, every tool.
* `81e36041` - `lua/core/tool_output.lua`: `handle_view`/`handle_views`, the ALLOW-listed model copy of
  a handle, applied in `M.project` only inside the `M.is_script(name)` branch and only to a table that
  has `state=="pending"` **and** a string `next` (only the code-mode layer writes it, so the operation
  tool's own `{state:"pending", op}` is untouched). A returned value with no handle in it comes back as
  the **same** table.
* `c401af8c` - tests (`scripts/test-codemode-pending.lua`, `scripts/test-remote-pending.lua`) and
  `docs/CODEMODE.md` (the handle section, and the script-value / model-copy split).

The texts:

* stoppable: `wait("op-...") returns this call's result; cancel("op-...") stops it`
* not stoppable: `wait("op-...") returns this call's result`

**Item 2 - peer paths: decided by the measurement above, option (b).** A handle that names a node shows
the node and keeps `stdout_path`/`stderr_path`/`log_path` **out of the model's copy**; the exact handle
is still retained, by hash, in `full_result` (`tool_result({sha256})` reads it byte for byte). Chosen
because the measured failure was exactly a model reading a **peer** path and going to the peer's
operation surface; a path on another machine is not a local file, and naming it beside the node still
invites the read. A **local** handle keeps its two paths (they are readable while the work runs, which
is why item #37 added them) and loses only the duplicate `log_path`.

## Sizes, measured (not estimated)

| answer | base | now |
|---|---|---|
| the ledger's remote handle (session fece6285, seq 137) | 617 B | (its fields, at today's lengths) |
| a peer handle, `scripts/test-remote-pending.lua` | **825 B** | **386 B** |
| a local `bash` handle, `scripts/test-codemode-pending.lua` | **908 B** | **793 B** |

Both rows print the two numbers on every run (`pending remote view: ... vs the base's ...`), and both
assert `#view <= #header + 2 + #json.encode(handle)` - the base's own text for the **same** handle, so
the size rule cannot rot into a magic number. `next` is included in every number above.

## Tests (failing on the base, green here)

* `scripts/test-remote-pending.lua`: 90 checks green. New rows: `a remote handle names wait(op) as its
  next step, with its own id`, `and offers cancel, which the peer's operation tool can do`, `the script
  still reads operation_id, stdout_path and log_path`, `the model's copy of a pending remote answer
  names the next step`, `and shows no peer path a model could read locally`, `and still says which
  machine the work is on`, and the size row.
* `scripts/test-codemode-pending.lua`: 108 checks green (real sandbox). New rows: the handle's `next`
  names its own op and offers cancel, the script keeps `log_path`/`operation_id`/`progress.output_bytes`,
  the model view drops `log_path` and `operation_id` and carries `next`, the size row, plus the outbox
  pair (`an outbox handle names wait(op) as its next step`, `a message already queued does not offer
  cancel`) and the draft side (`a draft nothing has sent offers cancel in the same field`).
* **On the base** (`git worktree add /tmp/psw-base-tree ee38c015`, the two test files copied in, no
  stash): `test-remote-pending.lua` fails at `:45 a remote handle names wait(op) as its next step, with
  its own id: nil`; `test-codemode-pending.lua` fails at `:35 a pending answer carries one plain field
  naming the next step: {"log_path":".../operations/op-.../stdout","op":"op-...",...}`.
* Wiring: `test-remote-pending.lua` is row `scripts/test.sh:1252`; `test-codemode-pending.lua` runs
  native and through the component in `scripts/test-codemode-component.sh:140-146`, with the check
  count compared between the two paths - the new rows run on both.

## Prompt cache (only NEW results change)

* `git diff ee38c015 -- lua/core/tools.lua lua/core/codemode_policy.lua` is empty: no tool schema, no
  guidance text, so no declared-tool byte and no system-prompt byte moved.
* `scripts/probe-prompt-bytes.lua` run on the base tree and on this tree **from the same working
  directory**: identical - `system_bytes 20572`, `envelope_bytes 786`, `codemode_bytes 1388`,
  `prompt_bytes 21358`. (Run from different working directories the probe differs by the cwd line it
  embeds; that is what the first, unpaired run showed, and it is not this change.)
* `scripts/test-prompt-cache.lua` 195 checks, `scripts/test-prompt-tool-names.lua` 288 checks,
  `scripts/test-prompt-golden.lua` 20 checks - green on **both** trees (the golden normalizes only the
  scratch home and the cwd).
* No stored message is rewritten: the change touches how a NEW result is projected and what a NEW handle
  carries. An existing transcript's bytes are what they were.

## Texts to approve

1. `wait("op-...") returns this call's result; cancel("op-...") stops it` - the `next` field of a handle
   whose work can be stopped (`lua/core/codemode_pending.lua`).
2. `wait("op-...") returns this call's result` - the same field where a cancel can do nothing (an outbox
   message already queued, a kind with `cancel=false`).
3. `lua/core/tool_output.lua` comment block `THE MODEL'S COPY OF A PENDING HANDLE` - code comment, not
   model-facing, listed for completeness.
4. `docs/CODEMODE.md`, two new bullets under "Pending calls": `The handle names its own next step` and
   `The script's value and the model's copy are two things`.

## What I did not verify

* The **component path** of `scripts/test-codemode-pending.lua` was not run: this mission's
  `CARGO_TARGET_DIR` has no `wasm32-wasip2/release/codemode.wasm` and the diff is Lua only, so the guest
  is untouched - but "not run" is not "green", and the check-count comparison in
  `scripts/test-codemode-component.sh` is the row that would prove it.
* Anything against a live peer: rule 13. The remote rows drive the real pending executor over the relay
  stand-in the file already carries.
* 5 of the 12 windows of the three-day count (**the ledger search refused them**), so the 23 / 12-of-23
  numbers are a floor.
* The full `scripts/test.sh` / `scripts/fast.sh` suites: not run in this round (one heavy suite at a
  time on this node, and the deploy swap kept killing long operations).
