# search-miss-names-cli: an empty tool search says why, and names the installed CLI

Branch `change/search-miss-names-cli`, base `8082b42e`. Commits: `7208fda1` (the search's answer, both
surfaces), `6cfce856` (the component seam, its parity case, the `components.lock` repin).
Self-review: I read and ran everything below myself; no independent reviewer read this diff.

## What the brief said, and what I measured before writing code

| premise | measured on this node (avell, base 8082b42e) |
|---|---|
| `searchTools("github")` answers `[]`, `capabilities()` shows no GitHub tool, gh is installed | **true**. `searchTools("github")` → `[]`; `gh` is `/home/victor/.local/share/mise/shims/gh`. |
| `capabilities()` is wa's grant list and `describe()` the host registry (144 entries) | **true** for tools; nothing in `lua/core` listed PATH programs - `rg -n executable_on_path` found only `lua/core/mcp.lua`, `rust/wa-capabilities/src/host.rs` and the tests. |
| `host.executable_on_path` already exists as a building block | **true** (`rust/wa-capabilities/src/capabilities.rs`, read-only). |
| nothing in the prompt prefix or the tool list may change | kept: no change to `lua/core/agent.lua`, no change to any tool schema. The fact lives in the search's own RESULT. |
| a caller that iterates the result as a list must still work | kept: the miss is a MEMBER of the same array (`found:false`), the shape the unknown-name branch has answered since 11/11. |
| **not in the brief**: the chat path on this node is the code-mode COMPONENT, not the Lua loop | `~/.wasm-agent/policy.json` has `"features": {"codemode": true}` and `~/.wasm-agent/components/codemode.wasm` is installed, so `features.seam("codemode")` is true and `lua/core/codemode.lua`'s discovery never ran for a real turn. A Lua-only fix would have looked right and left the measured bug in the path Victor actually uses. That is why item 2 changed `rust/components/codemode/src/logic.rs` and why `components.lock` moved. |

A second measured fact changed the design: the first version of the `searchTools` help text named
"github" and "gitlab" as examples - and the help text is part of the haystack a keyword search scans, so
`searchTools("github")` started matching the `searchTools` entry itself and returned a HIT instead of
the miss. The help now describes the miss without naming an example word (measured after the fix:
`searchTools("github")` → one `found:false` member).

## What changed

1. `lua/core/cli_hints.lua` (new, `7208fda1`): one short allow-list of work-splitting word → program
   (`gh/github`, `glab/gitlab`, `git`, `docker`, `kubectl`, `aws`, `gcloud`, `az`), one
   `host.executable_on_path` lookup at miss time, and the sentence a miss carries. Nothing runs at load;
   a word the table does not name never reaches the PATH (measured: `searchTools("codewhisper")` opens
   zero lookups); the first table word decides, installed or not, so a miss cannot become an inventory.
2. `lua/core/codemode.lua` (`7208fda1`): the keyword branch, when it found nothing, answers
   `{name=<the query>, found:false, missing:true, query, reason, cli={name,path}?}` as ONE member of the
   same array. A hit, a listing and a batch are byte-identical to before.
3. `lua/core/envelope.lua` (`7208fda1`): the outer `tool_search` adds `.reason` (and `.cli`) when
   `matches == 0`. No key it already answered was removed or renamed.
4. `lua/core/codemode_view.lua` and `docs/CODEMODE.md` (`7208fda1`): the help `searchTools("select:searchTools")`
   answers, and the doc, both describe the miss member.
5. `rust/components/codemode/src/logic.rs` (`6cfce856`): `interpret` now hands a keyword search that
   matched nothing back to the loop (`Guest::Host`) - a sandbox cannot read the node's PATH - so the
   LOOP composes the one sentence and both loops answer identical bytes. The branch is read from the
   answer and the argument, not re-decided (`keyword_miss`).
6. `components.lock` (`6cfce856`): `codemode` repinned to `c942620dffa45057c944b2bdce200b25b7d318656a40d36607fe8e96d91fea9d`,
   225,166 bytes.

## Tests, and how each was run

* `scripts/test-search-miss-cli.lua` (new, wired into `scripts/test.sh` line 1581, and a fast-path row by
  the `scripts/test-*.lua` inventory): 24 checks over BOTH surfaces through a real run
  (`tools.dispatch(memory,"codemode",…)` and `tools.dispatch(memory,"tool_search",…)`): the measured
  case, the same query without the program, an alias and a program's own name, a word the table does not
  name (zero lookups), a hit left untouched, the unknown-NAME branch unchanged, the facade, the array
  shape a script maps over, and a bounded echo of a long query. One stubbed capability
  (`host.executable_on_path`), because the shared contract fake (`scripts/lib/contract-host.lua`) covers
  the store capabilities only and a PATH answer is not a store fact - the stub says so in its own
  comment. Own scratch `WASM_AGENT_HOME` through `scripts/lib/test-home-guard.lua`, refusing to run when
  it would be a live home.
  * it FAILS on the base: in a separate worktree of `8082b42e` (`git worktree add --detach /tmp/base-miss-check 8082b42e`),
    the same file run there answers `lua error: …:41: a search that matches nothing answers one member that says so: []`.
* `rust/components/codemode` unit tests: `cargo test --offline --lib` → 15 passed, 0 failed, including the
  new `a_keyword_miss_goes_back_to_the_node_that_can_name_an_installed_program`.
* `scripts/test-codemode-component.lua`: the new parity case ("a keyword miss says why, the same way on
  both paths") makes it 21 comparisons; `bash scripts/test-codemode-component.sh` → `codemode seam ok
  (21 parity comparisons ran)`, 0 skipped, and the same suite run against the pinned artifact
  (`WA_CODEMODE_COMPONENT_WASM=/tmp/miss-components/codemode.wasm`) → 50 checks, 21 comparisons, 0 skipped.
* Reproducibility of the pin: `WASI_SDK=/home/victor/wasi-sdk-34 bash scripts/build-components.sh codemode`
  twice, into two target dirs → the same `c942620d…` / 225,166 bytes both times.
* `bash scripts/test-component-pins.sh` → half 1 "source and pins agree", half 2 "11 of 11 pinned
  component(s) verified". The codemode bytes half 2 judged are the build above, placed in the check's own
  cache for this worktree (`<git-dir>/wa-pinned-components/codemode.wasm`) - NOT in this node's
  `~/.wasm-agent/components`, which still holds `191818ce…` for the running node. The release the deploy
  reads (`components-fbe95281b2ce`) does not exist yet.
* Rows that touch the changed paths, each run here with the tree's Lua and its own scratch home:
  `test-envelope` (100), `test-tool-search-names-codemode` (36), `test-codemode-friction` (21),
  `test-codemode-presentation` (46), `test-codemode-parity` (56), `test-codemode-boundary` (33),
  `test-codemode-errors` (10), `test-codemode-promises` (31), `test-tool-schema-fidelity` (69),
  `test-refusal-contract` (16974), `test-prompt-tool-names` (288), `test-tool-cues` (156) - all green.
  No pre-existing failure was met in the rows I ran.
* `bash scripts/fast.sh` under `flock -o ~/Work/missions/.suite.lock`: see "Gate" below.

## Texts to approve

Model-facing or operator-facing strings, verbatim:

1. `Any command-line tool on this machine runs through tools.bash.`
2. `gh is installed (<path>): run it with tools.bash.` (the program and path are substituted)
3. `no tool in this script's catalogue matches '<query>'.` (a script's `searchTools`)
4. `no permitted tool matches '<query>'.` (the outer `tool_search`)
5. The `searchTools` help (`searchTools("select:searchTools")`), new sentence: "A keyword search that
   matches nothing answers one member of the same array - {name:<the query>, found:false, reason,
   cli:{name,path}} - whose reason says what did not match and, when the query names a program this
   machine has installed, names it and the path it lives at and says to run it with tools.bash."
6. The help's `shape` example member: `{ name = "<the query>", found = false, reason = "no tool in this
   script's catalogue matches '<the query>'. gh is installed (/usr/bin/gh): run it with tools.bash.",
   cli = { name = "gh", path = "/usr/bin/gh" } }`
7. Field names a script reads on the miss member: `name`, `found`, `missing`, `query`, `reason`, `cli.name`, `cli.path`.
8. The `tool_search` result keys on a miss: `reason`, `cli.name`, `cli.path`.

## Gate

`bash scripts/fast.sh` (flock, `CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-search-miss-names-cli`):
`fast exit=0`, `lua 307/307 passed` (58 excluded by `scripts/fast-path.exclude`), `rust component codemode ok`, `component-pins ok`, `component-pins-selftest ok`, and one NAMED skip that is neither mine nor a pass (`status-icon-metrics`: 26 status-glyph measurements outside the brief's box). An earlier run of the same gate was killed mid-flight by the node install and is NOT a verdict; the one failure it left behind (`test-retire-many`, my new miss shape) is fixed in `30291bf2`, and `test-start-instant` failed once under that interrupted run while passing alone and in the final run.

## What is not done, and what I could not verify

* **The component release is not published.** The bytes are built, reproducible and pinned, but
  `scripts/publish-components.sh` only prints the `gh release create` line for a human, and this mission
  may not push. Until the bundle for the new lock (`components-fbe95281b2ce`) exists, a deploy refuses
  with `component_release_unavailable` and half 2 of the pins check on another node prints a named SKIP
  for `codemode` (not a pass).
* **The live node still runs the OLD installed component** (`191818ce…`, 215,594 bytes), so a `wa chat`
  turn on this node today would still answer `[]` for "github". The new bytes reach the chat path only
  through a deploy. What I verified end to end here is the component path itself: the parity suite drove
  real scripts through the built artifact.
* **`git` never reaches a miss** on this catalogue: the keyword match is a substring scan, and "git" is
  inside descriptions ("digits", "edit", "register"…), so `searchTools("git")` answers 3 hits (measured).
  The table maps it anyway, for a catalogue where it does not collide. Short words in general (`az`, `gh`)
  are the fragile ones; the aliases that matter for the measured case (`github`, `gitlab`, `docker`,
  `kubectl`, `aws`, `gcloud`) all miss and therefore answer.
* I did not run a live `wa chat` turn (that needs the deployed bytes and would touch the live node), and
  I did not touch any peer node. No model was called; nothing was pushed.
