# land-2a-fix: the merged release-2a tree made green

**Branch** `change/land-2a-fix`, base `land61/final` (44fa5e84). Commits below are on this branch only;
nothing was pushed. Worktree: `/home/victor/Work/missions/land-2a-fix/wt`.

## Result

`bash scripts/fast.sh` on the final tree (commit 46078941):

```
fast result ok (301 checks, 0 failed, 0 skipped): .../wa-fast-result.json
fast path ok (301 checks, 0 skipped, 236s)
```

The gate's own evidence (`~/.wasm-agent/land/land-20261119T042059Z-504810a7/evidence/gate.log`) and the
tree's `wa-fast-result.json` both read `301 checks, 3 failed, 0 skipped` at 44fa5e84. This run is 301
checks, 0 failed.

The binary the runner used was its own: `fast: binary .../m-land-2a-fix/release/wa (build 460789413c86,
tree 460789413c86, fresh: built from this tree)`. Scratch homes per row, `WASM_AGENT_HOME` under
`/home/victor/.wasm-agent/tmp/`, never the real `~/.wasm-agent`.

## Premises in the brief that were wrong (re-measured)

1. **Paths.** The brief says `lua scripts/test-cli-wake-row.lua` etc. The rows live in
   `scripts/test-*.lua`, not `lua/scripts/` (`git ls-files scripts/test-cli-wake-row.lua`). The `lua`
   prefix is what the runner prints as the *section*, not a directory.
2. **The count.** The brief says "3 of 301". The gate's log and json agree at 301/3. My own first
   baseline run (`--all-rust`, 673s) saw **4 of 316**, because a fourth row
   (`scripts/test-codemode-queue-timeout.lua`) is load-dependent: it passes alone and 8-way in parallel
   but failed inside the loaded run. That row is item 4 below. It was not one of the three the brief
   named, and I did not touch it before measuring it.
3. **Cause of item 3.** The brief blames "`docs/HOST.md` not documenting new host fields". The failing
   row never reads `docs/HOST.md`: it parses `rust/wa-capabilities/src/host.rs` and checks that a
   `push_json` capability's **doc comment** says it answers JSON text. `docs/HOST.md` already listed all
   three (`file_magic` line 766, `build_identity` 826, `runtime_info` 827). The defect was in the Rust
   doc comments, plus one attribute ordering that hid a doc comment from the row's parser.
4. **`WASM_AGENT_LUA_ROOT=<worktree>`** is what the runner sets for every row (`scripts/fast.sh`,
   `fast: env contract` line), so a row that has to read the tree can; that premise held.

## The three failures, each with the branch rule that caused it

### 1. `scripts/test-cli-wake-row.lua` — 1 of 30 (commit 423cc72b)

**Branch:** tui-polish-2, `f1f790ae` "one space between every status icon and its value".

**Measured failure:** the stored snapshot `tests/snapshots/balloon/wakes-80x24.txt` read

```
row 23 (status bar): 󰑐0 Σ↑0 ↓0
```

while the view now draws `󰑐 0 Σ↑0 ↓0` (`lua/core/cli_view.lua`, `session_summary`, `GLYPH.turns .. GAP ..`,
`GAP = " "` at line 298). The snapshot was last written by `0d7549d2`, before `f1f790ae` changed the
spacing. `f1f790ae` updated `scripts/test-cli-view.lua` but not this second fixture.

**Fix:** regenerated the fixture **from the view's own bytes** — I temporarily made the row dump the
exact `want` string it computes, ran it, and wrote that file, rather than hand-typing glyphs. Both
branches' rules stand: tui-polish-2's one space (pinned by `scripts/test-cli-view.lua` line 1888ff)
and the wake row's own placement (untouched). The row is 30 of 30 green after it.

**Not loosened:** no assertion changed; only the stored bytes it compares against.

### 2. `scripts/test-efficiency.lua:315` (commit 26ad366a)

**Branch:** turn-signal, #43 — `lua/core/tools.lua` lines 1602–1638: `list`/`await`/`wait` answer ids and
state by default and return an output body only when `output=true`/`include_output=true`; otherwise
they set `stdout_omitted`, `stderr_omitted`, `output_omitted` and `output_hint`.

**Measured failure:** the row did
`r=tools.dispatch(memory,'operation',{action='await',...})` then `r.stdout:find('fixture')`. Under #43
`r.stdout` is nil by default, so line 315 died on `attempt to index a nil value (field 'stdout')`. The
row predates #43 and relied on the old shape.

**Fix:** the row now pins **both** halves of #43 rather than bypassing it:

```lua
check(r.settled and r.ok, 'await returns settled evidence without model polling')
check(r.stdout==nil and r.output_omitted==true and tonumber(r.stdout_omitted or 0)>0
  and tostring(r.output_hint):find('output=true',1,true)~=nil, 'the default await omits the body and says so: ...')
local asked=tools.dispatch(memory,'operation',{action='await',id=op.operation_id,output=true,max_bytes=4096},...)
check(asked.settled and asked.ok and type(asked.stdout)=='string' and asked.stdout:find('fixture',1,true),
  'and hands the body over when the caller asks for it: ...')
```

That is **stricter** than the original single check: the old one only asked "is the body there"; the new
one requires the omission to be named and the body to arrive when requested. Consequently item 2 adds
checks: the row reports `efficiency ok (119 checks)`. **This is the one place the row's check count went
up because of a fix; the count is the row's own print, not a loosened assertion.**

### 3. `scripts/test-host-return-docs.lua:84` (commit 634891aa)

**Branch:** vault-allowlist (`b9642ece`, `file_magic`), tui-polish-2 (`186a531f`, `build_identity`),
and `runtime_info`'s later fields.

**Measured failure:** the row's message is exactly
`FAIL every capability that answers JSON text says so: ["file_magic","build_identity","runtime_info"]`
— then, after the comment edits, still `["file_magic"]`.

Two distinct defects, both in `rust/wa-capabilities/src/host.rs`:

* `build_identity` and `runtime_info` documents did not contain the words the row requires (that the
  answer is JSON text **and** that it is a string/table distinction).
* `file_magic` had its doc comment, but the `#[no_mangle]` attribute sat **between** the doc and the
  `fn`, and the row collects doc comments only from lines directly above the signature. The file's own
  convention elsewhere (`path_kind` 808/809, `path_facts` 835/836) puts the attribute above the doc.

**Fix:** added one doc line each to `file_magic`, `build_identity` and `runtime_info` stating the answer
is a JSON string the caller decodes (never a Lua table); completed `runtime_info`'s field list; and
moved `file_magic`'s `#[no_mangle]` above its doc block, matching the file's convention. Row: `host
return docs ok (10 checks; 38 JSON-text capabilities documented)`.

**Behavior unchanged:** no `push_json` call, signature, or return shape was altered — the diff is
comments plus one attribute reordering, both non-semantic in Rust. `cargo` built the tree (the run's
own `fresh` banner) and `rust wa-capabilities ok (9s)` in the final run.

### 4. `scripts/test-codemode-queue-timeout.lua` — found by my baseline, not in the brief (commit 46078941)

**Neither a branch's rule nor a contradiction: a fixture precondition nobody witnessed.**

`rust/wa-operation/src/lib.rs`: `start` records admission and answers its receipt, and `Slot::acquire`
— which flips `state` to `queued` and then to `running` — runs in the spawned supervisor thread
*afterwards* (`let slot = Slot::acquire(&entry, &dir, entry.control)?;`, comment: "Acquired here, after
admission, so the caller holds its receipt immediately"). The row started six `sleep 20` workloads and
immediately asked a seventh call to queue; under load those six may not have taken a slot yet, so the
seventh answered `accepted` (running) instead of `queued`. Measured message: `and the handle says it is
queued, not running: {"elapsed_ms":14,...,"state":"accepted"}`.

**Fix:** the row now polls `operation action=status` for each of the six until they report `running`
(bounded, 20 s), and asserts it observed all six before the ninth call. It adds one check, so the row is
`ok codemode-queue-timeout: 18 checks` (was 17). No assertion was removed or relaxed; the "it queues"
check stays exactly as strict and now runs against a state that was actually established.

**Pre-existing?** The row is byte-identical to `land61/final` (`git diff land61/final -- ...` is empty),
so this is a pre-existing, load-dependent flake in the merged tree, not something my items 1–3 caused.

## What I could not verify

* The failing-row causes above are attributed by *reading the merge* (`git log --oneline -S` on the
  branch commits), not by running the base tree and each branch separately (that would need extra
  worktrees; the brief allows it but the 218s gate evidence plus these three readings were enough).
* The 4th failure reproduced only inside a loaded full run; I did not make it fail on demand after the
  fix beyond the 8-way parallel and loaded runs above. It is fixed by construction (a witnessed
  precondition), not by having caught it again.

## Text to approve (operator-facing)

1. `host.file_magic` doc, added line: *"A JSON string the caller decodes with lua/vendor/json.lua,
   never a Lua table to index directly."*
2. `host.build_identity` doc, added line: *"One JSON string the caller decodes with lua/vendor/json.lua;
   it is a string, not a table."*
3. `host.runtime_info` doc, added lines: *"build_wave_generation, process_id, boot_id, os, arch,
   binary_path, run_origin} - one JSON string the caller decodes with lua/vendor/json.lua, never a Lua
   table."*

No other operator- or model-facing string changed: the snapshot fixture is data the test compares, the
two test files are not shipped, and no tool description, prompt, or CLI text was edited.
