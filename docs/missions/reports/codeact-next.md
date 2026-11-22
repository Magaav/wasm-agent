# codeact-next: the measured waste in run results and scripts

Branch `change/codeact-next`, base `12fd4c12`. Local commits only, never pushed.

Every number below was re-measured on this node before the code was written, with
`python3 ~/Work/missions/codeact-stats.py 2` and two read-only scans of the same ledger
(`~/.wasm-agent/memory.db`, 2-day window). Where the brief's number and the ledger disagreed,
the ledger's number is used and the disagreement is written down.

## Re-measured premises (the brief was written on an older window)

| brief | measured 22/11 (2 days) |
| --- | --- |
| 1,976 real `run` results | **3,102 run rounds**; 3,131 run tool results (3,295 including the JSON form) |
| 490 results (25%) carry a pending note and lose the plain form | **673 of 3,131 (21%)**; 839 plain, 2,292 JSON |
| header bytes 6% of all result text | line 1 + `calls:` + `vars:` = **173,325 of 9,495,930 chars = 1.8%** today |
| ~35 shell-text compile failures, half of all failures | **62 SyntaxError rounds of 3,102 (2%)**; failures 4% of rounds |
| `raw is not defined`: 7 | **7** (exactly) |
| "four test rows nobody runs" | three of them; `test-exec-timeout` **is** run by `scripts/test.sh:2118` (with `WASM_AGENT_EXEC_TIMEOUT_SECONDS=2`) |

## 1. A pending note no longer costs the plain form — `9d9816df`

`lua/core/tool_output.lua`. `pending_settled` and `pending_backgrounded` are in the `plain` key set
now, and `M.project` writes each as one header line after `calls:` and `vars:`:

```
status 200 · bash 200 · full_result <sha>
calls: <sha>:<bytes>
pending: backgrounded {"count":1,"ops":["op-..."]}
pending: settled [{"op":"op-...","tool":"bash","state":"done","stdout":"later\n","code":0,...}]
```

The payload of a note line is the key's own JSON, so nothing is paraphrased; `M.parse_view` decodes
each line back into `pending_settled` / `pending_backgrounded`. A note set larger than
`NOTE_BYTES` (4096) keeps the **JSON form** instead — a note is never dropped to win the plain shape
(measured note sizes: `pending_backgrounded` median 56 B, max 161; `pending_settled` median 171 B,
p90 335, max 3,601). Stored views are not rewritten.

Test: `scripts/test-run-pending-header.lua` (19 checks, real sandbox, real handles, own scratch home;
it is in the fast path because it is not in `scripts/fast-path.exclude` and the fast path runs every
`scripts/test-*.lua` not listed there).

## 2. `raw` is always defined — `e29bb789`

`lua/core/raw_code.lua`. A `run` call with no `raw` argument used to return the code untouched, so a
script reading `raw.p1` died with `ReferenceError: raw is not defined` (7 failures). It now returns
`{ const raw = {};\n<code>\n}`: the binding rides on the **opening line**, so the script's own line
numbers do not move. The script compiles, the name reads `undefined`, and the failure (if any) is the
tool's own refusal about the argument that was missing — measured:
`tools.bash({command: raw.p1})` now answers `schema_required:arguments.command` instead of a
`ReferenceError` about `raw`.

Test: `scripts/test-native-raw-vars.lua` rows 4 and 8 (22 checks; row 4 was re-pinned from "no wrapper,
no binding" to the new contract, with the reason in the comment; row 8 drives the `run` **tool**, not
`native_run`, so the whole path is covered).

## 3. A compile failure names the cause and the way out — `a74a1e64`

`lua/core/codemode.lua` (`explain`). For a `SyntaxError` from a compile failure the fix line said only
"Change line N". It now says what the class is and where the way out is:

> The usual cause is shell text inside a JavaScript string - a backtick, ${...} or an unbalanced quote
> closes the literal early. Put the command in the run call's raw argument (raw: {script: "..."}) and
> pass raw.script to tools.bash, so the bytes never pass through JavaScript. Change line N and run the
> script again. The script did not compile, so nothing ran.

A tool's own `fix`, when there is one, still wins, and a runtime failure does not get the sentence
(scoped to the class, measured by the test's fourth row).

Test: `scripts/test-run-syntax-fix.lua` (27 checks) runs the **three shapes taken from the ledger** —
a shell `${...}` inside a template ("expected '}' after template expression"), a backtick inside a
template ("expecting ';'"), a stray backtick after the code ("unexpected end of string") — through the
real sandbox, and asserts the sandbox's own words are kept, the cause and `raw.script` are named, the
line is still named, and the fix stays inside its 600-byte budget.

## 4. The `full_result` reference on a whole body: measured, and KEPT

Numbers, 2-day window:

- 80 bytes per plain result (` · full_result ` + 64 hex). **976** plain results had a whole body
  (1 was cut), so dropping it would save **78 KB = 0.8%** of all result text today; after item 1 makes
  nearly every result plain the same rule saves ≈ 2.4%.
- It is **read for a whole body** by two rows: `scripts/test-whatsapp-names.lua:33` pins the exact
  header line including `full_result %x+`, and `scripts/test-codemode-default.lua:38-44` fetches the
  file it names and asserts `backend` and all three `attempts` exist **only there**.
- A whole body is **not** a superset of the stored original: the view deliberately drops `backend`,
  `context_policy` and `attempts` (each call's arguments and its result a second time),
  `lua/core/tool_output.lua`'s lean branch, and `tool_result`'s own description tells the model to use
  `full_result.sha256`.
- Usage in the same window: 3,301 run scripts, **1** `tools.tool_result(...)` call and 13
  `results.get` mentions — rare, but not zero.

80 bytes against breaking a documented contract plus two tests, on 0.8% of the text, is not a trade
this branch makes; the reference stays. Nothing in `lua/core/tool_output.lua` changed for item 4.

## 5. The four excluded rows: one fixed and off the list, three stale by measurement

- `scripts/test-exec-timeout.lua` — **real, fixed, off the list** (`d19a8c02`). Its deadline is read by
  the host at start, so run alone the default 300 s makes "timeout is failure" unsatisfiable. It now
  re-executes itself once through the binary it is already inside (`WA_FAST_BIN`, which
  `scripts/fast.sh` gives every row) with `WASM_AGENT_EXEC_TIMEOUT_SECONDS=2`, and prints a named
  `SKIP` when there is no such binary; `285b7572` adds `host.runtime_info().binary_path` as the second
  way to find it, so the row is self-contained wherever a node can run it. Verified alone in the fast-path
  shape, with and without `WA_FAST_BIN`: "exec timeout ok (child node with a 2 s deadline)".
  `scripts/test.sh:2118` still runs it with the variable set.
- `scripts/test-envelope-iteration.lua` and `scripts/test-envelope-outcomes.lua` — **stale**, and not
  by a flake: `tools.envelope('master',ctx)` returns exactly **one** declared tool (`run`) with
  `WASM_AGENT_BOOTSTRAP_MODE` unset **and** with it set to `lean` (measured). So "lean declarations"
  (13 names) and "lean reduces the total context" (classic vs lean byte totals, a strict `<`) can never
  hold again — `change/one-run-path` retired the envelope they pin, and their `.cjs` drivers run the
  same rows and fail with them.
- `scripts/test-read-batch.lua` — **stale on three premises, each measured**: it needs a
  `READ_BATCH_CAPTURE` payload (seq5193, 59,723 B) that no script in this tree produces; it calls a
  global `routed` helper that nothing defines (the retired `*_many` form); and it pins the
  `calls_or_cursor_exclusive` refusal the dispatcher no longer makes (`{cursor,calls}` answers
  `ok=true`, 6 executed).

For those three the list now records the verdict and the reason instead of an error line, because
removing an assertion is not this branch's call: deleting them is an operator decision, and the note
names exactly what each one guarded. (An attempt to make `test-read-batch` self-contained was made and
reverted: with its capture skipped it still fails on the retired refusal, above.)

## Texts to approve (verbatim, model- or operator-facing)

1. The note lines in a script result: `pending: backgrounded {"count":1,"ops":["op-..."]}` and
   `pending: settled [{...}]`.
2. The compile-failure fix sentence: "The usual cause is shell text inside a JavaScript string - a
   backtick, ${...} or an unbalanced quote closes the literal early. Put the command in the run call's
   raw argument (raw: {script: "..."}) and pass raw.script to tools.bash, so the bytes never pass
   through JavaScript. Change line N and run the script again. The script did not compile, so nothing
   ran."
3. The named skip of the timeout row (reachable only when there is no binary to re-execute with at
   all): "SKIP test-exec-timeout: this row needs the node started with WASM_AGENT_EXEC_TIMEOUT_SECONDS=2
   (its deadline is read at start) and no binary to re-execute itself with (neither WA_FAST_BIN nor
   host.runtime_info's binary_path); scripts/test.sh runs it with the variable set".
4. The three STALE entries in `scripts/fast-path.exclude` (operator-facing comments).

## Checks run

- Each new or changed row alone, through the tree's own `wa` (release build of this branch):
  `test-run-pending-header` 19, `test-run-syntax-fix` 27, `test-native-raw-vars` 22,
  `test-exec-timeout` (child node), `test-run-view` 17, `test-session-vars` 48,
  `test-codemode-wait-shape` 25, `test-codemode-pending` 92, `test-whatsapp-names` 8,
  `test-handle-wake` 16, `test-codemode-default` 39, `test-codemode-presentation` 46,
  `test-operation-cpu-priority` 18 — all green.
- `scripts/test-discriminates.sh 12fd4c12` (final HEAD `7e45765f`; `rc=0`): **3 discriminating, 0
  blocking, 1 unchanged-verdict**. `test-native-raw-vars`, `test-run-pending-header` and
  `test-run-syntax-fix` each failed on the base's code with the base's own error (`a run without raw
  still binds raw, on the opening line: return 1`; `the view opens with the status line, not a JSON
  envelope`; `the fix names the cause: Change line 2 and run the script again`). `test-exec-timeout` is
  `unchanged-verdict` - the row was made runnable, the code it measures was not changed, so it passes on
  the base too and proves nothing about a fix; that is the tool's own rule and it does not block.
- Fast path, narrowed to the 13 touched rows (`WA_FAST_ROWS`, `--jobs 4`, under the suite lock):
  **`fast path ok (99 checks, 0 failed, 1 skipped, 367s)`**; 27 Lua rows ran (the 13 plus the
  never-dropped core rows) and every one passed, `test-exec-timeout` included. The one skip is
  `test-status-icon-metrics`, a glyph-measurement skip unrelated to this branch (named in
  `wa-fast-result.json`).

## Not done, and what would block it

- The three stale rows were not deleted (see above): that needs an operator's word.
- Nothing was measured on a live fleet call: every row runs in its own scratch home with no rendezvous
  and no network, as the quality rules require.
