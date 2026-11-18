# codeact-fix round 7 (review 18/11 21:40)

Base: `3abec8c5` (round 6). Branch `change/codeact-fix`, committed locally, not pushed. The root
`REPORT.md` stays DELETED (item 5, and the branch's rule): this report is in `docs/missions/reports/`, and
`git ls-files REPORT.md` is empty.

## 1. The resolver: node's own order, and an ambiguous name refused

Before: `RESOLVE_EXT={'.mjs','.js','.cjs','/index.mjs','/index.js','/index.cjs'}` (Lua) and
`IMPLIED=[".mjs",".js",".cjs","/index.mjs","/index.js","/index.cjs"]` (Rust). Measured on this node's node
26.13.1: `node ./a` with only `a.mjs` beside it fails with `Cannot find module`; with `a.js` AND
`a.mjs` it runs `a.js`. So the old list named a file nothing runs, and left the file that DOES run
unhashed - the value went to the file the digest never saw.

Now both sides resolve a name in node's order (`lib/internal/modules/cjs/loader`): the exact name, then
`.js`, `.json`, `.node`, then the directory it may name (`package.json`'s `main`, resolved the same way,
then `index.js`/`index.json`/`index.node`; depth-capped at 2). `.mjs` and `.cjs` are not implied.
When MORE than one file answers to the name, the launch is REFUSED instead of resolved:
`vault_approval_argument_ambiguous:<value>` (Rust) and a `problems` entry "an argument names more than one
file node could run (...)" (Lua, `mcp_vault_code_not_covered`). An import/source name that more than one file
answers to is refused the same way.

Where: `lua/core/mcp.lua` (`node_candidates`, `package_main`, `resolve_local`, `ambiguous_argument`) and
`rust/wa-capabilities/src/operations.rs` (`Resolved`, `node_candidates`, `package_main`,
`ambiguous_refusal`).

## 2. The interpreters the digest cannot follow

Before: `INTERPRETERS` followed `node,nodejs,bun,deno,qjs,quickjs` plus the POSIX shells, and every other
interpreter was refused only by whatever script it happened to name - so `python3 -c`, `python3 -m`,
`perl -e`, `ruby -e` passed, and `-c` was treated as the value of an option.

Now:

* `INTERPRETERS` (followed) is `node, nodejs` (js) and `sh, bash, dash, zsh, ksh` (sh) and nothing else.
  `bun`, `deno`, `qjs`, `quickjs` moved into the refused list: their module systems are not the one
  this digest follows (a remote URL, a lockfile's tree, a compiled blob).
* `UNFOLLOWED_INTERPRETERS` (33 names, identical in `lua/core/mcp.lua` and
  `rust/wa-capabilities/src/operations.rs` - checked by extracting both lists and diffing them):
  `python python2 python3 pypy pypy3 perl ruby php lua luajit tclsh expect deno bun qjs quickjs ts-node tsx
  java jjs pwsh powershell julia elixir escript erl rscript groovy scala kotlin swift dotnet mono`, matched with
  or without a version (`python3.11`, `perl5.36`, `ruby3.2`, `php8.2`: the trailing digits and dots
  are stripped before the match).
* A PROGRAM that is one of those is refused by name: `vault_approval_interpreter_unfollowed:<program>` (Rust),
  "its program is an interpreter this digest cannot follow (<name>), whose modules and packages this approval
  cannot name" (Lua).
* A code option given to a program the digest cannot classify is inline code: `CODE_FLAGS` =
  `-c -e -E -m -p -r --eval --print --command -command -encodedcommand --module --require`, refused with the
  existing `vault_approval_inline_code:<flag>` text. For the two families it DOES follow its own list still
  decides, so `node -r file` stays a FILE that is hashed and `sh -c` is still inline code.

`docs/VAULT.md` (line 529, the bullet that said "a Python, Ruby, Perl, PowerShell or Lua script") and
`docs/MCP.md` now state exactly this: the 33 names, the versioned match, the two followed families, and the
code options. The code lists and the documents name the same set.

## 3. The string overclaim

`recheck_after_spawn` now returns, verbatim as approved:

`vault_approval_changed_since_check:<path>: a file this connector runs changed between the check and the launch, so the operation was killed - the value had already been put in its environment at launch, so treat it as exposed and rotate it if this change was not yours. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on`

`docs/VAULT.md` and `docs/MCP.md` say the same thing in prose (the value was in the child's environment,
so it is to be treated as exposed and rotated). The Rust test compares the whole sentence with `assert_eq!`,
so a later edit that softens it fails.

## 4. LOW: vm next to eval, and the child's PATH

* `require('vm')`, `import ... from 'node:vm'` / `'vm'`, `runInThisContext`, `runInNewContext`,
  `runInContext`, `vm.Script` and `vm.compileFunction` are refused exactly like `eval` and
  `new Function` ("it evaluates a string as code (vm: runInThisContext, vm.Script), whose source no digest
  of files names"), in `lua/core/mcp.lua`'s `refused_construct`. `vm` was already in `BUILTIN` (so
  it was never followed as node_modules) but was never refused.
* The interpreter is resolved with the PATH the CHILD gets. `host.getenv("PATH")` answers the host's CONFIG
  first (resolved_env), while the kernel resolves a bare program name against the PROCESS environment
  (`host::executable_on_path`, used by the `start` branch of operations.rs). So a config PATH named one
  node while the child ran another and the digest named a file no launch reads. New read-only capability
  `host.executable_on_path(name)` (rust/wa-capabilities/src/host.rs + capabilities.rs + docs/HOST.md row,
  effect read-only, inventory now 139 entries); `M.interpreter_path` uses it, and a host that cannot
  answer gives nil - the approval is refused rather than naming a guess. The kernel-side resolver was
  renamed `which_on_path` so the two names cannot be confused.

## 5. Root REPORT.md

Deleted on this branch (as in round 6) and still deleted: `git ls-files REPORT.md` prints nothing,
`ls REPORT.md` fails. Nothing in this round adds it back; a merge that brings `7a83e263`'s edit in must
keep the deletion.

## Tests (this node, this worktree)

```
CD /home/victor/Work/missions/codeact-fix/wt, CARGO_TARGET_DIR=/home/victor/wasm-agent/target/m-codeact-fix

cargo test --lib -p wa-capabilities (offline)                     319 passed, 0 failed
cargo test --lib -p wa-capabilities vault_approval_tests          16 passed (3 new in this round)
node scripts/test-capability-inventory.mjs <bin> <fresh dir>       ok: cli --json, cli text, sandbox
                                                                   capabilities()/describe(): 139 entries,
                                                                   sha256 c516783b..., 437 sandbox checks

Lua, each in its own scratch WASM_AGENT_HOME (test.sh's own preamble):
  test-mcp-vault-approval.lua    mcp vault approval ok (93 checks)   [64 before this round: 29 new]
  test-mcp-request-shape.lua     mcp request shape ok (11 checks)
  test-mcp-share.lua             mcp share ok (44 checks)
  test-mcp-node-runtime.lua      {"checks":142,"ok":true}
  test-mcp.lua                   mcp native ok (48 checks)
  test-secret-guard.lua          secret guard ok (36 checks)
  test-capability-inventory.lua  {"ok":true,"checks":437,"count":139}
node --test scripts/test-mcp.mjs test-mcp-session.mjs test-mcp-request-seal.mjs
                                 20 pass, 0 fail
```

The `wa` binary used for the Lua/CLI runs was built into the mission's CARGO_TARGET_DIR with
`WA_CODEMODE_BUILD_ASSETS=<git-common-dir>/codemode-assets/pi-1.2.0-quickjs-3.6.2` (the same env the supported
`scripts/codemode-build.mjs build` sets), so the codemode-backed rows above (secret guard, capability
inventory) ran for real rather than being skipped.

### The same tests on the base tree (git stash of the code, tests kept)

* Rust: `git checkout HEAD -- operations.rs host.rs capabilities.rs` with the three new tests still in
  operations.rs, so the same tests ran on the round-6 production code -
  `a_name_is_resolved_in_nodes_own_order_and_an_ambiguous_one_is_refused`,
  `an_interpreter_this_digest_cannot_follow_is_refused_by_name` and
  `a_change_after_the_check_names_the_value_as_exposed` FAILED there, and the 13 other
  `vault_approval_tests` passed (no pre-existing failure in that module). The change-sentence failure
  printed both strings: base ended "so the operation was killed and no value was used", this branch ends
  "so the operation was killed - the value had already been put in its environment at launch, so treat it as
  exposed and rotate it...".
* Lua: `git stash push -- lua/core/mcp.lua` + a release rebuild - `mcp vault approval: 24 failed of 93
  checks` on the base, the same 93 pass here. All 24 failures are in the new section 7 (the order/ambiguity
  checks, the 12 interpreter programs, the two code-option checks, the three vm checks, and the four PATH
  checks); none of the 64 pre-existing checks fails on the base either.

No pre-existing test failure was found in any suite named above.

## Not verified here

* The full `scripts/test.sh` gate was not run (it builds components and runs the whole suite); the rows
  above are the ones this change can move.
* Windows: `host.executable_on_path` appends `.exe` exactly as the `start` branch does, but no Windows
  node was available to run it.
* A connector whose `package.json` `main` is a directory-of-directories beyond depth 2 keeps resolving to
  nothing and is refused - unverified in the field, by design conservative.
