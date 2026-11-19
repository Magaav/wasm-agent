# change/vault-allowlist - round 8: an allow-list for what receives a vault value

Base: origin/main after round 1b (44229140). Branch `change/vault-allowlist`. **Committed locally, not pushed.**

## What changed, and why

Rounds 6-7 refused interpreters **by name**. Each review found another name, another wrapper, or the same
interpreter under another name, and round 7's last hole was a *list of names* defended one entry at a time.
The rule is now inverted: **a connector that receives a vault value runs one of two families, judged by what
the file IS.**

1. **Allow-list, by realpath.** `host.path_facts(path).path` (symlinks resolved) must have the basename
   `node`, `nodejs`, `sh`, `bash` or `dash`, **and** the file's leading bytes must be ELF, Mach-O or PE
   (`host.file_magic`). A shebang or plain text under an allowed name is refused
   (`program_not_native`). Everything else is refused whatever its name - `python*`, `perl`, `ruby`,
   `R`/`Rscript`, any interpreter, a copy under another name. The same judgement is applied to the
   interpreter the launch SPAWNS (`WA_NODE`), not only to the definition's program.
2. **`--native`: the operator's own voucher.** `/mcp <id> on --native <absolute path>` records
   `native <realpath> <sha256>` in the approval, and the kernel re-hashes those bytes before every launch
   (`vault_approval_native_changed`). A voucher is refused for an interpreter, a wrapper, or a script
   (`program_native_not_executable`): it approves a native binary, never a way around the allow-list.
3. **Wrappers refused as the program**, by realpath basename: `env`, `nice`, `ionice`, `timeout`,
   `setsid`, `stdbuf`, `xargs`, `sudo`, `doas`, `nohup`, `chrt`, `taskset`, `unshare`, `firejail`,
   `bwrap`, `flock`, `time`. An **argument** that resolves to an interpreter or a wrapper is refused too
   (`argument_not_allowed`), and an inline string is refused outright.
4. **Inline flags**: compared before `=` and split when the flag is a short cluster. `--eval=code`,
   `--print=1`, `-pe`, `-ec` are each refused by their own flag; a long option is never split.
5. **One shared table.** `fixtures/mcp-refused-names.json` holds the allow-list, the interpreter names and
   the wrapper names; **both** sides' tests assert their lists against it, and both compare case-insensitively
   (`Rscript` is `rscript` - Rust did not lowercase before).
6. **`vm` caught under any name**: `import`/`require` of `node:vm`/`vm` bound to a name and used through
   `.Script`, `.compileFunction` or `.runIn*` is refused, not only the literal `vm.Script`.
7. **docs/VAULT.md**: a new "The allow-list: what a vault connector may RUN" section states exactly what is
   allowed, what `--native` means, and that **a native binary's own loads are outside the digest**. The stray
   duplicate `///` at `host.rs` before `executable_on_path` is gone. `docs/HOST.md` documents `file_magic`.

## Files

- `lua/core/mcp.lua` - the allow-list, the voucher, wrapper/argument refusals, the flag and vm rules.
- `lua/core/mcp_cli.lua`, `lua/core/mcp_command.lua` - `/mcp <key> on --native <path>` (absolute only).
- `rust/wa-capabilities/src/{operations,host,capabilities}.rs` - the same judgement from the bytes on disk,
  `host.file_magic`, and the voucher's re-hash at launch.
- `fixtures/mcp-refused-names.json` - the shared table.
- `docs/VAULT.md`, `docs/HOST.md`.
- Tests: `scripts/test-mcp-vault-approval.lua`, `rust/wa-capabilities/src/operations.rs` (unit tests),
  plus native-binary fixtures in `scripts/test-mcp-request-shape.lua` and `scripts/test-mcp-share.lua`.

## Verified here (avell, 16 cores)

- `cargo test -p wa-capabilities --lib`: **323 passed, 0 failed**.
- `cargo build -p wa-host`: clean.
- `scripts/test-mcp-vault-approval.lua`: **mcp vault approval ok (121 checks)**.
- `scripts/test-mcp-request-shape.lua`: ok (11 checks). `scripts/test-mcp-share.lua`: ok (44 checks).
- `scripts/test-mcp.lua`: `mcp native ok (48 checks)`.
- `scripts/test-mcp-command.lua`: ok (132 checks).

Each Lua row was run in its OWN scratch `HOME`/`WASM_AGENT_HOME`, without `WA_MCP_SCRIPT_DIR` pointing at
the checkout.

## Pre-existing failure, not mine

`scripts/test-secret-guard.lua` fails at line 22 with `codemode_not_enabled`. **It fails identically on the
base** (a detached worktree at 44229140, same command, same scratch home) - it needs a codemode-enabled
node, which this invocation does not provide. Not changed by this branch.

## A mistake I made and corrected

One harness run passed `WA_MCP_SCRIPT_DIR=$checkout/scripts`, and the suites wrote their runtime stubs
**into the checkout**, overwriting 8 real `scripts/*.mjs` files. `git checkout --` restored them, the
untracked `scripts/bin`, `scripts/node-fixture` and `scripts/mcp-shared-fixture.mjs` were removed, and the
tree is back to the intended 11 changed files + 1 new file. Every run since uses a scratch directory only.

## Texts to approve (verbatim)

Victor approves these; the approved ones stay verbatim.

**Rust (kernel, launch time)**

- `vault_approval_program_wrapper:{program}: this connector's program resolves to {real}, which is a wrapper ({matched}) that runs another program, so the file the approval names is not the file that runs, and nothing was launched and no value was read. Run the connector under node or a POSIX shell: /mcp <id> probe, then /mcp <id> on`
- `vault_approval_program_not_allowed:{program}: this connector's program resolves to {real}, which is an interpreter ({matched}) whose modules and packages this digest cannot follow, so nothing was launched and no value was read. A vault connector runs node or a POSIX shell, judged by the program's realpath, or a native binary the operator vouches for with /mcp <id> on --native: /mcp <id> probe, then /mcp <id> on`
- `vault_approval_program_not_allowed:{program}: this connector's program resolves to {real}, which is not node or a POSIX shell (sh, bash, dash), so nothing was launched and no value was read. A vault connector runs node or a POSIX shell, judged by the program's realpath, or a native binary the operator vouches for with /mcp <id> on --native: /mcp <id> probe, then /mcp <id> on`
- `vault_approval_program_native_not_executable:{program}: this connector's program resolves to {real}, which the operator vouched for with --native but which is not a native executable: --native approves a native binary, never a script, so nothing was launched and no value was read. Name the real interpreter: /mcp <id> probe, then /mcp <id> on`
- `vault_approval_program_not_native:{program}: this connector's program resolves to {real}, which is named {real_name} but is not a native executable: a script or a plain file under an allowed name is an interpreter in disguise, so nothing was launched and no value was read. Name the real interpreter, or record a native binary at the operator's terminal with /mcp <id> on --native: /mcp <id> probe, then /mcp <id> on`
- `vault_approval_program_missing:{program}: this connector's program is not a file on this node, so nothing was launched and no value was read. Name the absolute path of its interpreter or binary: /mcp <id> probe, then /mcp <id> on`
- `vault_approval_argument_not_allowed:{value}: this connector's argument resolves to {real}, which is a {kind} whose code this digest cannot name, so nothing was launched and no value was read. Name a script file instead: /mcp <id> probe, then /mcp <id> on`
- `vault_approval_native_unreadable:{path}: the native binary this connector was approved on cannot be read now, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> on --native`
- `vault_approval_native_changed:{path}: the native binary this connector was approved on is not the bytes the operator vouched for, so nothing was launched and no value was read. A native binary's own loads are outside this digest; approve it again with /mcp <id> on --native`
- `vault_approval_native_not_covered:{path}: the native binary this connector was approved on is not in the files the approval names, so nothing was launched and no value was read. Approve it again at the operator's terminal: /mcp <id> on --native`

**Lua (console, the `problems` list of `mcp_vault_code_not_covered`)**

- `its program resolves to {real}, which is a wrapper ({clean}) that runs another program: the file this approval names is not the file that runs`
- `its program resolves to {real}, which is not node or a POSIX shell: it is an interpreter ({clean}) whose modules and packages this digest cannot follow`
- `its program resolves to {real}, which the operator vouched for with --native but which is not a native executable ({magic}): --native approves a native binary, never a script`
- `its program resolves to {real}, which is named {real_name} but is not a native executable ({magic}): a script or a plain text file under an allowed name is an interpreter in disguise`
- `its program resolves to {real}, which is not node or a POSIX shell (sh, bash, dash): a vault connector may run only those two families, judged by the program's realpath, or a native binary the operator vouches for with --native`
- `an argument resolves to a wrapper ({value} -> {real}, {clean}), and a digest of files cannot say what it would run`
- `an argument resolves to an interpreter ({value} -> {real}, {clean}), and a digest of files cannot say what it would run`
- `it evaluates a string as code (vm: Script, compileFunction or runIn*, under whatever name the module was bound), whose source no digest of files names`
- `its interpreter ({real}) cannot run a vault connector: {refusal}` - the spawned interpreter (WA_NODE, then the provisioned copy) is judged by the same allow-list, and its refusal follows the colon verbatim (round 8 addendum; measured 18/11: on this host 'which node' is mise's shim, realpath /usr/bin/mise, so this is the FIRST refusal a shimmed host meets)

**CLI (`/mcp <key> on --native`)**

- `--native takes the ABSOLUTE path of a native binary this connector runs: a bare name is resolved through PATH, which this digest cannot name`
- `usage: /mcp <key> on --native <absolute path of the binary>`

## What remains, explicitly

- **A native binary's own loads are not priced.** `--native` is trust in a whole program, by the operator,
  for those bytes. That is the trade the mission asked for and docs/VAULT.md now says so.
- `scripts/test-secret-guard.lua` could not be run (pre-existing, above); I did not make it pass.
- Nothing was pushed; the branch is local.
