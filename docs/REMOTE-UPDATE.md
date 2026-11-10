# Remote update: a master asks a node to update itself

A master asks a peer to install a commit on itself. The peer's **own** Sentinel performs it, under its
own rules; the master only asks, reads back and is told once. What is admitted is a signed master
request, never a child shell.

```
wa update openclaw                          # origin/main, on openclaw, by openclaw's Sentinel
wa update openclaw --commit <40-hex>        # one exact landed commit
wa update openclaw --rendezvous             # the registry that node runs (scripts/deploy-rendezvous.sh)
wa update openclaw --status [--id <record>] # what it installed, read from the peer's own files
```

The same two calls are a tool: `node_update {node, action, commit?, rendezvous?, id?}`.

Status 2026-11-10: built (`lua/core/remote_update.lua`, capability `update`, `wa update <node>`, the
`node_update` tool), proved by `scripts/test-remote-update.lua` (51 checks) and used live from
`wasm_the_first` against `openclaw` and `work`.

## Why it exists

The fabric's intent (operator, 2026-11-10): *"we should be able to install from distance, that is the
intent of fabric ... allow openclaw to be updated by distance"*. Measured the same day, from
`wasm_the_first`, **nothing** could install anything anywhere else:

| door | answer |
| --- | --- |
| `remote {node, capability:bash}` then `wa update` | `update_coordinator_only` |
| `remote {node, capability:bash}` then `wa-sentinel request deploy` | `sentinel_coordinator_only: child tasks cannot change supervisor, jobs or installation` (even `--help`) |
| `wa-sentinel request run --script scripts/deploy-rendezvous.sh` on the peer | refused the same way |

The cause is one correct guard: a relayed shell on the peer carries `WASM_AGENT_PROVENANCE=child`
(`rust/wa-capabilities/src/operations.rs`), and a child task may not replace the supervisor it runs
under. Only a session **on the node itself** could request an install (`work`'s 16:17 install came from
its own session `db57bc92`).

The repair is not to weaken that guard. It is to stop asking through a shell: the peer admits a signed
capability call from a node the roster/binding already trust (`lua/core/server.lua`,
`wa_node_call` → `node_capability`), and that branch runs in the peer's **own** node process — no
`child` marker, and no installer logic in the requester.

## The two halves

### Peer half: `serve(args, caller)` (capability `update`)

1. **Authority.** `nodes.author_of(caller)` — the binding's author check, or the roster's master
   role. A guest is refused `forbidden_role`; nothing is executed and no tree is touched.
2. **Audit.** One record per request, `<config>/remote-update/<record>.json`, naming the requesting
   node's id, name, key prefix, the basis it was admitted on (`roster`/`binding`), the level, the
   requesting session, the target commit, the door and the request file. Plus one line in the peer's
   node log (`remote-update admitted: <name> (<node id>) asked for node on <sha12> - <request path>`).
   A refusal is recorded too, and its answer carries the record id.
3. **The tree.** `git fetch`, then the target must be an **ancestor of `origin/main`**
   (`commit_not_on_main` otherwise), and `HEAD` must fast-forward to it (`merge --ff-only`;
   `commit_not_reachable` otherwise — a remote update never resets a tree; rollback stays
   `upgrade.sh`'s job). A dirty tree is refused `tree_dirty`.
4. **The installer.** The module writes exactly what `/update` writes: `update.run` with
   `expected_commit` (so "install X" cannot silently become "install whatever is at HEAD"), which
   applies the same preconditions a local `/update` does — a verified watcher, no stop file, no
   deploy already waiting — takes the same pre-update backup, and writes one
   `wa-sentinel request deploy --if-no-pending` into the peer's own request box. `--rendezvous` writes
   the wrapper that `wa-sentinel request run` can execute (that door takes a path and no arguments)
   into a directory named by the peer's `WA_SENTINEL_SCRIPTS`, and issues it.
5. **Nothing else.** The peer's Sentinel builds or installs the published prebuilt binary
   (`scripts/deploy.sh`'s prebuilt branch), applies the disk floor, the deploy lock and its own
   outcome record. This module installs nothing itself.

### Master half: `request` / `status`

`request` sends one signed call and keeps `<config>/remote-update/requests/<record>.json` (which
node, which commit, which session asked). `status` reads the peer's record and the peer's durable
files — `installed.txt` (including `binary_source=prebuilt-release`), the installer's own
`deploy-result.json` for that request id, the sentinel's `done/`/`failed/`, and the
`deploy-outcome` ledger when one was opened — and answers with a state:
`queued` · `running` · `installed` · `failed` · `silent` · `unknown`.

`installed` is only said when `installed.txt` names the requested commit. An installer that claims
success for a request whose commit is not what is installed is reported as `unknown` with both facts,
never repeated as a success.

**One notice.** A settled outcome is handed to the requesting session once (`notice=true`, then
`notice=false`), and only to the session that asked. A request made from a turn also schedules one
`wake` (`lua/core/selfloop.lua`) so the session is asked to read the outcome 3 minutes later, and the
tool's answer says so.

Why the notice is master-side: the sentinel's report is a `wake` request in **its own** request box,
which wakes a session **on that node**. The asking session lives on another node, and a node below the
master may not call up (`docs/MESH.md`: a node may call and control nodes at its own level or below).
The peer keeps the durable record; the master's own loop carries the notice. Nothing pretends a peer
session reported back.

## Grants, roster, and what a guest can do

The capability is not classified in `server.lua`'s `MESH_VERBS`, so a mesh attestation grades it
`call` — the strongest grant — rather than inheriting `control`'s price for a shell. On a bound node the
managed allow-list must also name it (`update=true`), and the handler still refuses anyone
`author_of` does not name as a master. So a guest is refused twice, and a master without the grant is
refused by the mesh before the handler runs.

## The prebuilt binary a remote update needs

A remote update must not compile on the node it replaces. `scripts/publish-node-binaries.sh` finds its
own toolchain (`zig` from PATH or the pip `ziglang` package, `~/.local/bin`, `/usr/local/bin`,
`/opt/homebrew/bin`, `build/zig`; `WA_ZIG` names one) and exports **one** `CARGO_TARGET_DIR`
(`rust/target` by default, `--target-dir` to move it) so `wa-host`'s workspace and `wa-sentinel`'s own
workspace land in the same tree — the two things a caller used to have to recreate by hand.

`scripts/landing-queue.mjs land` runs `publish-node-binaries.sh --ensure --publish --target
aarch64-unknown-linux-gnu --commit <merged>` **after** the push and the readback, and records the
answer in the row and in its own line:

```
landing-queue: #7 release covered (aarch64-unknown-linux-gnu): covered: node-4147192f2725 covers the
  compiled inputs of <merged> for aarch64-unknown-linux-gnu; nothing to build or publish in 2s
```

`--ensure` is what makes that cheap: a Lua/docs/test-only landing answers in seconds because its
compiled inputs are unchanged, and a Rust landing pays one build here instead of on every node. A
publisher that cannot run **never** fails the landing (the merge is already pushed and read back): the
row says `release failed (...): <reason>` and keeps its log beside the queue.

## Proof

- `scripts/test-remote-update.lua` — guest refused; master admitted; the tree fast-forwards; exactly
  one `request deploy --if-no-pending`; the audit record and line name the requester and the commit;
  `commit_not_on_main`, `commit_not_reachable` and `tree_dirty` refused by name; the outcome read from
  `installed.txt` + `deploy-result.json` reports `prebuilt-release`; one notice to the requesting
  session and none to another; the rendezvous wrapper and its `request run`; an unconfigured
  `WA_SENTINEL_SCRIPTS` refused by name; `wa update` with no node still local.
- `scripts/test-landing-queue.mjs` — `land` calls the publisher with the landed commit and records
  `covered`, and a failing publisher leaves the landing landed with the reason in the row.
- `scripts/test-node-binaries.sh` — the publisher's plan names its zig and its one target directory
  with zig off `PATH` and no `CARGO_TARGET_DIR`, and the exported target directory is the one both
  workspaces use.
- Live, 2026-11-10: `wa update openclaw` and `wa update work` from `wasm_the_first` after the feature
  landed (see the session's report for the exact records, release tags and installed commits).

## What the first live runs found

Two defects that only a real peer could show, both fixed and pinned by tests:

1. **The branch that serves the capability was empty.** `node_capability`'s
   `elseif capability == "update" then` had its comment and no statement after it. Lua accepts an
   empty block between `then` and the next `elseif`, so the file parsed and the node ran - and every
   remote update answered `plugin_not_found:update`, because the call fell through the whole chain to
   the plugin dispatcher. `scripts/test-remote-update.lua` called `remote_update.serve` directly and
   was green; it now also reads `lua/core/server.lua` the way the node loads it: the branch exists,
   its first non-comment statement is the `return dofile("lua/core/remote_update.lua").serve(...)`
   call, the capability is in the managed allow-list, and it is not classified in `MESH_VERBS`.
   A comment is not a statement.

2. **`scripts/deploy-rendezvous.sh` is mode `100644` in git.** The rendezvous wrapper `exec`'d it and
   the sentinel's run reported `code=126 Permission denied`; the wrapper now runs it through `bash`,
   which is what the run door does for every `.sh` anyway.

Both were visible on `openclaw` within a minute of the first attempt, and neither was visible from the
unit tests alone. The bootstrap itself was never the problem: the install a peer performs on request is
the same one it performs for itself.

## What each step cost (2026-11-10, measured)

| step | what it took |
| --- | --- |
| capability call, peer writes its request | ~1.2 s (`wa update openclaw` returns the record id) |
| peer installs from a published release | 44.6 s build-shipped node install; 15 s for a Lua-only commit (the fast path) |
| peer compiles because no release covered the commit | ~19 min on a 2-vCPU aarch64 host - the case the publisher exists to remove |
| publishing the release in the landing (`--ensure --publish`) | 169 s when the compiled inputs changed, 4 s when an earlier release covers them |
| reading the outcome back (`--status`) | one call; the notice is handed over once per request per session |
