# run-bodies-without-quoting

Branch `change/run-bodies-without-quoting`, base `c1337903`. Everything below was measured on this node
(avell) with the retained ledger (`~/.wasm-agent/tool-results`, 179 246 result files) and this tree's own
built binary; nothing was released, deployed or pushed, and no live peer was called.

## 1. The measurement the brief asked for (item 1)

Read-only over `~/.wasm-agent/tool-results`, files younger than 5 days written before 2026-11-23 13:00Z,
selected by `"code":"SyntaxError"`:

* **202 run calls failed to compile** in that window. Per day: 2026-11-19 **1**, 2026-11-21 **61**,
  2026-11-22 **72**, 2026-11-23 **68** (partial day).
* **132 of the 202 already carried the fix line that names `raw`** (commit `a74a1e64`, 22/11 00:28 -03, is
  the one that added it), and 68 of today's 68 are after it. Naming the cause and the way out in the fix
  line did **not** stop the first attempt from dying: the count after that commit is the same as before it.
* Error shapes: `expecting ';'` 90, `expected '}' after template expression` 26, `unexpected end of string`
  9, the rest 77 across 20+ other messages.
* **How many of the next calls used `raw`: not measurable from this ledger.** A `run` result records
  `code`, `fix`, `message`, `line`, `status` and the calls the script made; it never records the `raw`
  argument, and `lua/core/raw_code.lua:135` (`raw_blocks`) never reaches the result. The same holds for
  the message store (`tool_arguments` is not on the search surface). I did not fake this number; the
  proxy that is measurable is the 132/202 above - the sentence was already there and the failure
  recurred - and that is what the change below answers.
* **Does the run tool's own description need to name `raw`?** It already does, in the sentence the model
  reads: `raw_code.lua:64-71`, "Use raw to carry file bodies or patches exactly, as an object keyed by the
  variable name the script should read (each value reaches the script byte for byte, never escaped into
  the code)" (added `11dec17e`, carried through `46938061`). Measured cost of that sentence is already in
  the prompt bytes every thread carries; **no byte of it was changed by this branch**, so no new cache
  miss.
* Two more defects fell out of the measurement and one of them is the real reason the sentence did not
  help: the reported line was not the model's line (see item 2), and 39 of the 202 had their offending
  line cut at exactly 160 characters with nothing said, so the backtick the fix asks about could be past
  the cut.

## 2. Item 2 - the first attempt works or fails usefully

Reproduced first, on this node, with a three-line script and one `raw` block: the answer said
**"Change line 6"** for a script that has no line 6. `lua/core/raw_code.lua` wraps the model's script
before the sandbox sees it (one line for the `raw = {}` binding, four when the call carries raw blocks) and
`lua/core/codemode.lua`'s `script_line` undid only the harness prologue.

* `149a32cd` - the answer names **the model's own line**: `raw_code.native_run` returns `origin` (the text
  as sent) and `origin_line` (the source line it starts on), and `codemode.lua` maps the sandbox line back
  through them. The answer now shows **three lines around the error** with the error line marked `>`, and a
  line too long to show says how many characters it is not showing (` +N`) instead of ending silently.
  Per-line cap 200, message cap 600 -> 900 bytes (**cache cost: failure results only, +300 bytes, nothing
  on the success path**).
* `23d298d0` - the recorded header `line N:C | the text` is kept byte-compatible (a row and a reader
  already parse it, `scripts/test-codemode-errors.lua:15` asserts it) and now carries its own ` +N` cut
  marker; the excerpt is added **after** it, so no assertion was loosened.
* Tests: `scripts/test-run-syntax-fix.lua` grew from 27 to 42 checks (the model's line with and without
  raw, the three lines and the `>` marker, the ` +N` marker for a 312-character line). On the base
  (`c1337903`, separate worktree) the same rows fail by name: *"the line it names is the model own line
  (2), not a line of the wrapped source (got 6)"*.

## 3. Item 3 - a body is never silently altered

**Measured first, and it contradicts the note's premise.** A body containing a LITERAL backslash-n
(`A\nB`) went through `tools.write` and arrived as the four bytes it was (`od -c`: `A \ n B`), and the
same body carried in a run call's `raw` block arrived byte for byte too. So the harness does not decode
anything on the way in, and **the double decoding of `\n` (notes 83, 116) happens in the model's own
string literal**, one layer above: the harness never sees the pre-decoding text, so it cannot undo it and
should not guess. What the harness can see is the file after the write, and that is what `501804a6`
guards:

* `tools.write` reads the file back and compares it with the bytes the script held; a mismatch is a
  REFUSAL (`write_mismatch`, `effect: "unknown"`, naming the first byte that differs and the bytes sent
  against the bytes on disk), never `ok: true`. A body over 8 MB is not compared and the answer says so
  (`body_unverified`).
* `file_tools.apply` - the one write point every `edit` and mutation batch passes - does the same
  (`write_mismatch`, `outcome: "unknown"`, `EDIT_VERIFY_MAX` 8 MB).
* Test: `scripts/test-write-body-bytes.lua` (16 checks, new fast-path row - auto-discovered, not in
  `scripts/fast-path.exclude`). It writes the exact bytes and compares them, then wraps `host.write_file`
  for one call so the write lands short, and asserts both paths refuse. On the base the same file fails by
  name: *"and that answer is not a success"* (base reports `ok: true` over a truncated file).

## 4. Item 4 - sandbox globals

Already done at base, verified rather than assumed: `41372e9a` (22/11) added `sleep`, wrapped
`btoa`/`atob` and the named fix lines for a missing global; the row that proves it,
`scripts/test-codemode-globals.lua`, passes here (27 checks), and the all-allow-list `GLOBAL_FIX` table in
`lua/core/codemode.lua` names `Buffer`, `setTimeout`, `HOME`, `location`, `require`, `fetch` and the rest.
No change was made and nothing was duplicated.

**One gap measured, not closed:** the allow-list holds environment and runtime names, not tool names. My
own first script this session died with `ReferenceError: search_messages is not defined` and the fix line
was the generic "Change line 4" - `tools.search_messages` exists and the answer could have said so. It is
not one of the cited names (notes 146, 155 are about `Buffer`/`setTimeout`), so it is reported here rather
than smuggled into this branch.

## 5. Item 5 - `rg -rn` is a replacement

`4e4f4890`: `bash_result.rg_replace` reads the command text and, when the short cluster carries `r`
(`-rn`, `-rl`, ...) or `--replace` is used, adds one sentence to the answer's `note`: *"rg reads -r as
--replace: 'n' replaced every match in the output above, so that text is not what the files contain. For
grep's -rn use rg -n (line numbers) and drop -r."* Nothing is refused or rewritten back - the mistake is
the model's - and only that shape is named, so `rg -n`, `rg --files` and `grep -rn` stay quiet.
`6dd5e84c` adds the real-path case (a run block, not a unit call).

I reproduced the underlying bug live before writing it: `rg -rn "run_tool_schema" lua/core/raw_code.lua`
returned `function M.n()` - every match replaced by `n`. That is the output a reader built conclusions on
in notes 120 and 263.

Tests: `scripts/test-slim-bash-result.lua` 152 -> 156 checks (the habit shapes named, the ordinary shapes
quiet, the sentence present on the sliced answer, and one real run block). On the base the new rows fail
by name: *"the rg replacement note has one definition"*.

## 6. What was run, and what was not

No full suite, no `scripts/test.sh`, no `preflight`, no `wa land --until gate`, no release, no deploy, no
push, no live peer call. Rows were run the way `scripts/fast.sh` runs them (scratch `WASM_AGENT_HOME`,
`WASM_AGENT_LUA_ROOT` at this worktree, cwd at the worktree, this tree's built binary), one row at a time:

* green: `test-run-syntax-fix` (42), `test-slim-bash-result` (156), `test-write-body-bytes` (16),
  `test-write-node-receipt` (18), `test-script-writes-show-diff` (38), `test-codemode-errors` (10),
  `test-codemode-globals` (27), `test-codemode-default` (39), `test-codemode-friction` (21),
  `test-codemode-blocks` (72), `test-codemode-presentation` (46, `new_model_bytes` 15 368 against
  18 468 unprojected), `test-codemode-model-boundary` (665), `test-edit-aliases` (34),
  `test-one-run-path` (138), `test-patch-audit-agent`; `test-patch-audit` SKIPs by name (no
  `WA_COMPONENTS_DIR` outside the runner).
* **A full `scripts/fast.sh` narrowed to these rows was started under the suite lock and did not finish**:
it rebuilt the tree's binary, built the components, and then the operation ended with exit 2 and no FAIL
line (`op-1795454607678686-3346212-13`, right after the components pin; a deploy was installing at the
time and the operation owner detached). The rows were therefore run individually, as above. The gate at
landing still owes the full narrowed path.
* **Pre-existing failure, not mine:** `scripts/test-codemode-native.lua:24` ("opt-in adds one tool, direct
tools retained") fails identically on a separate base worktree at `c1337903`, so the catalogue count it
asserts is already wrong on main.
* Two rows refusals are my harness, not the tree: `test-script-writes-show-diff` needs
  `WASM_AGENT_VAULT_URL` removed (it passes with that env, 38 checks), and three rows refuse a home inside
  `~/.wasm-agent` while two others refuse a home outside `~/.wasm-agent/tmp` - each passed in the home it
  asks for.

## 7. Texts to approve (model-facing, verbatim)

1. The compile-failure message tail, now (error line + three lines + marked row):
   `line 2:11 | const s = 'hello;` / ` 1: const a = 1;` / `>2: const s = 'hello;` / ` 3: return a;`
2. The long-line marker: `>1: const s = 'xxx... +112` (the count of characters not shown).
3. The write refusal note: `the file does not hold the bytes this call sent - they first differ at byte N
   (sent A bytes, the file holds B bytes): sent "…", on disk "…". Nothing here can say what wrote the
   rest, so this call does not report success.`
4. The edit refusal note: `the file does not hold the text this edit sent (it holds N bytes, the edit sent
   M): nothing here can say what wrote the rest, so this edit is not reported as applied.`
5. The too-large body marker: `body_unverified: body_too_large_to_compare`.
6. The rg sentence: `rg reads -r as --replace: 'n' replaced every match in the output above, so that text
   is not what the files contain. For grep's -rn use rg -n (line numbers) and drop -r.`

## 8. Proposed text (not written) for FACTORY.md and HANDOVER.md

FACTORY.md, under the rules about failure lines:

> A failure line about a line of the model's script names the MODEL's line, not the line of the text the
> harness compiled: the wrapper and the prologue are subtracted before the number is printed, and the
> three lines around it are shown with the error line marked, since an unterminated literal is usually
> opened on the line above. A line too long to show says how many characters it is not showing.

HANDOVER.md, under the measured state of the code channel:

> 23/11: 202 compile failures in five days, 132 of them after the fix line already named `raw`. The line
> the answer names was off by the harness wrapper (measured: "Change line 6" for a three-line script), and
> that - not the missing sentence - is what made the way out hard to use. Fixed in `149a32cd`/`23d298d0`.
> A write now compares the file against the bytes it sent and refuses rather than reporting success
> (`501804a6`). The double decoding the ledger blames on the harness happens in the model's own string
> literal, one layer above, and is not something the harness can undo.
