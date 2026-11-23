# release-linux-reads-the-receipt

Branch `change/release-linux-reads-the-receipt`, rebased onto `origin/main` = `85593e74` (four times, see
section 8), eleven commits plus this report, lands on green, no review. Mission: the public channel step
publishes from the binary the build actually made; and the three additions of 23/11 09:45Z, 10:50Z and 11:20Z.

    git log --oneline 85593e74..HEAD
    407ab1bb test: the channel row names the steps it allows between the ring and the channel
    10148157 report: the rebase onto 41d6420c, and what only the narrowed fast path found
    bb8af9fb test: the two new rows follow the runner's TMPDIR, and the channel row is never dropped
    45273183 test: the channel row owns its stand-ins, so the landing can run it
    2d582e51 report: main moved to ad4576ee by one unrelated landing (no overlap)
    eb49fbd4 report: rebased onto origin/main 7865a08e, rows re-run green
    975017d8 report: the channel step reads the receipt, and the three 23/11 additions
    a18c0918 land: a description change runs the description rows before it lands
    7d54d172 land: wa land mark linux --by-hand records a hand-published channel, and the board reads it
    5559f624 cli: wa <verb> --help is a question and runs nothing, with a row that enumerates the acting verbs
    3ef96341 release-linux: stage the bundle from the build receipt, and a channel step row that runs the join
    (the four item commits were 94c39059, fb6ca151, c7bd3d98, 000bbc5f on base 7865a08e; the two test
     commits were b47c9081 and a970f559 before the rebases)

Every rebase was clean, in the tree: onto `7865a08e`, onto `41d6420c` (ten commits of other missions), onto
`c1337903` (fifteen, including `change/esc-socket-per-thread`) and onto `85593e74` (twenty-seven, including the
release plan's new `canaries` step). Two of them found a red row the branch had not seen - the narrowed fast
path under the second (section 8) and the landing's own preflight under the fourth (section 9) - and both are
fixed by naming what the row really means instead of a literal that happened to hold on one main.

## 1. What was measured, before anything was changed

### The recorded failure, re-read

`release-20261123T082627Z-3fc25b76/evidence/linux.log` ends with, twice:

    release-linux: building wa (x86_64-unknown-linux-musl) - cross code-mode shipping build
    release-linux: building wa-sentinel
    release-linux: no built binary at <run>/tree/rust/target/x86_64-unknown-linux-musl/release/wa
    linux-channel: build_failed: scripts/release-linux.sh --target x86_64-unknown-linux-musl (log .../build-x64.log)

and `release/linux-channel/out/wa-host.receipt.json` from the same run says the build was FINE:

    ok: true, binary: <home>/.wasm-agent/build/target/tree-424a56556023/x86_64-unknown-linux-musl/release/wa,
    binary_sha256: 0b20faffbe6f..., source_commit: 2104a4d88a37bb05627f166eaf47b5f32e8eacf4,
    source_tree: 713f370c18ea06c65dc5bf8f036a61ea0b7fecad, target: x86_64-unknown-linux-musl

So the premise was exact: the bytes existed, the receipt named them, and the bundle step looked in
`rust/target/<triple>/release/wa` instead.

### Re-measured on a scratch tree (item 1)

A separate worktree of the base (`git worktree add /tmp/base-rel 4b314af5`, never `git stash`) with only the
new row copied in:

    $ WA_BIN=... bash scripts/test-release-channel-e2e.sh
    FAIL the release channel step publishes over the real scripts and the real signature (linux_channel_build_failed ...)
    $ tail -1 <run>/release/linux-channel/out/build-x64.log
    release-linux: no built binary at .../repo/rust/target/x86_64-unknown-linux-musl/release/wa

The measured line, reproduced by a test in ~15 s, with no cargo and no real cross build. That is also the
discrimination the land gate asks for: the row fails on `4b314af5` and passes on this branch.

### The brief's facts that had drifted (re-measured)

* **Line numbers.** On base the guessed `wa` paths are lines 145 (cross) and 150 (native), and the refusal is
  line 154 - the brief said 144/150/154. Same shape, one line off.
* **`wa-sentinel` is not a onebuild product.** `scripts/codemode-build.mjs` builds `-p wa-host` only, so the
  sentinel is still this script's own `cargo` build (its receipt names nothing about it). The path is now
  taken from cargo's `compiler-artifact` message, which is cargo's own answer instead of a guess.
* **`wa update --help`, re-measured** in a scratch home against this node's installed binary
  (`wasm-agent v0.1.2 · vccbd3cdd`): it ran a local update and answered with the UPDATE's report
  ("no sentinel watcher ownership was verified, so nothing can safely accept this deploy: the request was not
  queued", exit 1). The premise holds; the words the brief quoted are the refusal of a different machine
  state. `wa update -h` reached `remote_update.lua` as a NODE named `-h` ("unknown_node:-h").
* **Job 8's file.** The row that went red on main (`scripts/test-host-return-docs.lua:15`) reads
  `rust/wa-capabilities/src/host.rs`, not `rust/wa-capabilities/src/capabilities.rs`. Both are in the
  allow-list below, with `docs/HOST.md` and the tool descriptions the prompt shows.
* **`wa release --help` does not reach Lua.** `rust/wa-host/src/release.rs` answers `wa release verify` /
  `trust-key` before the interpreter boots, so the guard delegates that form and answers for `release cut`, the
  one that would cut a release.

## 2. The items

### Item 2 - the bundle comes from the receipt (commit `94c39059`)

`scripts/release-linux.sh` no longer guesses a target directory. After the shipping build it reads the receipt
through the new `scripts/lib/build-receipt.mjs`, and refuses BY NAME, never by falling back:

* `receipt_unreadable`, `receipt_not_ok`, `receipt_no_binary`, `receipt_field_missing`;
* `receipt_commit_mismatch`, `receipt_tree_mismatch`, `receipt_target_mismatch`, `receipt_root_mismatch` -
  held against `--commit`, `git rev-parse <commit>^{tree}`, `--target` and the checkout's realpath;
* `build_receipt_no_binary`, `build_receipt_binary_absent`, `build_binary_changed` (the bytes are held to the
  `binary_sha256` the build recorded).

The sentinel's path comes from `cargo build|zigbuild --message-format=json` through
`scripts/lib/cargo-executable.mjs` (`no built wa-sentinel` when cargo named no executable), so the guess that
breaks under an ambient `CARGO_TARGET_DIR` is gone there too. No guessed path remains:

    $ git show 000bbc5f:scripts/release-linux.sh | grep -n 'rust/target'
    145:# not into rust/target - and until 23/11 this script staged the bundle from `rust/target/<triple>/release/wa` and
    (a comment recording the defect; no path is built from it)

The forwarding of `--message-format=json` through `cargo-zigbuild` (0.24.1) was verified directly on a scratch
crate: it prints `{"reason":"compiler-artifact",...,"executable":...}` lines. A full two-target musl build was
NOT run here: this node has no `zig` on PATH.

### Item 3 - the channel step, end to end (commit `94c39059`)

`scripts/test-release-channel-e2e.sh` + `scripts/test-release-channel-e2e.lua`. Until now every row replaced
one half of the step: `test-land-linux.lua` ran the real step against a fixture publisher, `test-linux-channel.sh`
ran the real publisher against a fixture builder. `scripts/release-linux.sh` had never run inside a test, which
is why release F found its bug at the real cut.

What runs for real: `impl.linux` -> `scripts/publish-linux-channel.sh` -> `scripts/release-linux.sh` ->
`scripts/lib/build-receipt.mjs` / `cargo-executable.mjs` -> `scripts/check-linux-channel-fresh.sh`; a scratch
`wa-vault` (`scripts/lib/test-release-vault.sh`) signs the sums and the tree's own verifier checks them; real git
remotes; the JSON index; and the one commit the step pushes (index entry + version bump), read back from the fake
origin.
What stands in, and says so in the row: the build (`node … codemode-build.mjs build` writes a receipt of the real
shape and a real executable in the node's one build root, OUTSIDE the checkout, where the real onebuild puts it),
`cargo` (the `compiler-artifact` message), `gh` (the shared fake, `scripts/lib/fake-gh.sh`), and the toolchain
precondition `scripts/lib/build-requirements.sh` (it stats a rustup toolchain a fixture home cannot have).

Assertions that catch the defect: the receipt's binary is outside the checkout; the archive's `wa` has EXACTLY
the receipt's sha256; the manifest names the released commit and the triple; the signed set is on the fake
release; the pushed commit carries exactly `releases/index-linux.json` and `lua/core/build_identity.lua`. A
second case hands the step a receipt of ANOTHER commit and requires `linux_channel_build_failed` with
`receipt_commit_mismatch` in the evidence and main untouched.

### Item 4 - the operator procedure (proposal only, below)

### Item 5 - nothing the model reads changes

No prompt text, no `docs/HOST.md`, no tool or capability description is touched by this branch
(`git show --stat 3cefe6c5 46d1ee99 264351ce c5331658`): the new strings are operator/CLI texts, listed in
section 4.

### Item 6 - `--help` is a question and runs nothing (commit `fb6ca151`)

`lua/core/cli_help.lua` holds the one list of the verbs that ACT (25 of them) with the lines that answer for
each, and the guard in `lua/core/init.lua` takes `--help`/`-h` above the dispatch, so no verb's body sees it.
Two forms keep their own, better words: `wa update <node> --help` (remote_update.lua's ten lines) and
`wa release <not cut> --help` (the binary's release CLI). `wa --help` and `wa -h` are now `wa help` (before:
"unknown command", exit 2). `scripts/test-cli-help.sh` + `scripts/lib/cli-help-verbs.lua` drive every local
acting verb and hold it to: exit 0, a `usage: wa <verb>` first line, NOTHING else on stdout, and the text this
tree declares; the fleet-membership verbs (bind, unbind, accept, promote, demote, revoke, network, fleet) are
not driven (a base tree would make them ask a live rendezvous, rule 13) and are covered by the in-process
check of the same list. On `4b314af5` the row fails first on `wa update --help`.

### Item 7 - a channel published by hand is recorded (commit `c7bd3d98`)

`wa land mark linux --by-hand --who <name> --why <text> --evidence <file>`:

* the effect is verified the way the step verifies it - `origin/main`'s `releases/index-linux.json` must name
  this run's commit for every target - so no claim is taken on trust (`mark_not_verified`);
* the hand is named and the reason recorded in `journal.linux.by_hand {who, why, evidence, at, commit, targets,
  state}` plus `steps.linux.state = done`, which is what the speed board and a resume read;
* refusals by name: `mark_by_hand_required` (a plain `mark linux` would lose the fact the board needs),
  `mark_by_hand_needs_who`, `mark_by_hand_needs_why`.
The speed board's release row (`scripts/speed-board.sh`) reads `.linux.by_hand` and prints
`cut -> published by hand (<who>): <why>; journal <id>` with state `ok` instead of `not a finished release`;
a journal with no such record is still `unknown`. Release F's journal was NOT touched: the row and the verb are
proved on a scratch journal in `scripts/test-land-linux.lua` and `scripts/test-speed-board.lua`, both red on
`4b314af5`.

### Item 8 - a description change runs the description rows (commit `000bbc5f`)

`lua/core/land.lua`: `M.DESCRIPTION_PATHS` (allow-list: `rust/wa-capabilities/src/capabilities.rs`,
`rust/wa-capabilities/src/host.rs`, `docs/HOST.md`, `lua/core/tools.lua`, `lua/core/codemode_policy.lua`,
`docs/PROMPT.md`), `M.DESCRIPTION_CHECKS` (`scripts/test-host-return-docs.lua`,
`scripts/test-prompt-tool-names.lua`, `bash scripts/sync-prompt-docs.sh --check`) and
`M.run_description_checks`. `impl.tests` runs them FIRST, before the Rust skip that swallowed the measured
failure; a red one refuses the landing as `description_rows_red` naming the check, its command and its last
line. `M.build_plan` names them in the tests step for such a round, so `wa land --dry-run` says it before the
push. The row is `scripts/test-land-quick-tests.lua`: the fixture tree carries the tree's own `host.rs` (plus a
capability line this case adds) and the JSON library the real row decodes with; with the line that does not say
"JSON text" the landing stops and names `test-host-return-docs.lua`, with the phrase it does not - and on
`4b314af5` the same branch LANDS (exit 0).

## 3. Where the new rows are wired

* `scripts/fast.sh`: `check release-channel bash scripts/test-release-channel-e2e.sh`,
  `check cli-help bash scripts/test-cli-help.sh`.
* `scripts/test.sh`: `gate_run bash scripts/test-release-channel-e2e.sh` (Linux only),
  `gate_run bash scripts/test-cli-help.sh`.
* `scripts/test-land-linux.lua` and `scripts/test-land-quick-tests.lua` are existing always-run rows
  (`scripts/lib/fast-rows.sh`, `wa_fast_core_rows`); `scripts/test-speed-board.lua` is reached by its subject.
* `scripts/test-release-channel-e2e.lua` is a never-dropped row too (`wa_fast_core_rows`, commit
  `e3870e26`): it dofiles the land harness, and `scripts/test-fast-rows.sh` judges that list against the
  tree - a narrowed run that dropped it would silently skip the one row that runs the real channel step.

## 4. Texts to approve (every new or changed operator/CLI string, verbatim)

`scripts/release-linux.sh` (commit `94c39059`):

    release-linux: wa        <path> (sha256 <12 hex>)
    release-linux: sentinel  <path>
    release-linux: receipt_unreadable: ... | receipt_not_ok: ... | receipt_no_binary: ... |
                   receipt_field_missing: ... | receipt_commit_mismatch: ... | receipt_tree_mismatch: ... |
                   receipt_target_mismatch: ... | receipt_root_mismatch: ...
    release-linux: build_receipt_no_binary: ... | build_receipt_binary_absent: the receipt names <path>, which is
                   not an executable file | build_binary_changed: <path> is not the bytes the build measured (<sha>)
    release-linux: no built wa-sentinel: <cargo's last line>
    release-linux: build_artifact_absent: cargo named <path>, which is not an executable file

`lua/core/cli_help.lua` (commit `fb6ca151`) - one `usage:` line + detail lines per verb; the usage lines:

    usage: wa update [--check]   update THIS node (tree: the Sentinel deploy; release: the verified bundle)
           wa update <node> [--commit <sha>] [--binary|--tree|--release] [--reason <text>] [--json]
           wa update <node> --status | --rollback | --to <sha> | --pin | --unpin
      --check is read-only: it says whether this node is behind what an update would install
    usage: wa land --ready | --branches a,b [--dry-run] [--no-deploy]   the landing pipeline, as one machine
           wa land --resume | status [--run <id>] | ready <branch> <sha>   continue, read, or record a READY line
      it merges, gates, pushes, moves main, publishes, deploys and publishes the public channel
    usage: wa release cut --run <id> [--resume] [--until <step>] [--no-deploy] [--signer local|<node>]
           wa release trust-key ... --node <peer>   another node's trust set
      a release writes a commit on main (the public channel's index) and it cannot be undone quietly
    usage: wa clean [--dry-run] [--days N] [--pin <path>] [--cap <percent>] [--status]
      reclaims this node's one build root: landed worktrees, old operations/logs/temp, and the cap
    usage: wa session park <id> [--reason <text>] [--mission <name>]   hold a session's schedule
           wa session release <id> | status [<id>]
           wa session start <node> --prompt <text> [--cwd <dir>]   start a session on another node
    usage: wa steer <session> "<note>" [--status]   queue a note for a session whose run is in flight
    usage: wa bind [service|status|renew|run] | unbind | nodes pending | accept <pairing-code>
      a binding is a pairing this node accepts and acts on; it is written where the runtime reads it
    usage: wa unbind [service|status]   stop acting on a binding this node holds
    usage: wa accept <pairing-code>   accept a pending pairing request
    usage: wa promote <node>   confirm a node of this network (administrator)
    usage: wa demote <node>   withdraw a node's confirmed place (administrator)
    usage: wa revoke <node>   remove a node's access (administrator)
    usage: wa network role <node-id> master|guest | forget <node-id> | remove <node-id> | approve <node-id>
      administrator-controlled changes to who this network is
    usage: wa fleet push-roster <node> [--replace-key <hex>]   install this fleet's roster on a node, then verify it
    usage: wa approve [on|off|status|list|only|except|send|edit|reject|cancel]   the gate on outgoing drafts
      send/reject/edit decide a real outgoing message
    usage: wa call <node> <capability> [args-json]   run work on another node
    usage: wa whatsapp archive list|cut|restore|unload|push|expire [YYYY-MM]   the index's monthly archives
    usage: wa services list|status|start|stop|enable|disable <name>   service components, no turn required
    usage: wa eval capture|list|run|report|verdict|reviewer   freeze real tasks, replay, review, read metrics
    usage: wa mission launch <name> <base> | start <name> | resume <name> [--msg <text>] | status [name]
           wa mission stop <name> | amend <name> <file> | preflight <name>
      the mission loop: a worker, its branch, its gate
    usage: wa backup [--to <dir>] | list   snapshot every store with its manifest
    usage: wa restore --from <dir>   put a snapshot back after re-checking every byte
    usage: wa setup fonts [--undo]   install wa's two faces for this user
    usage: wa init [--db <path>]   initialise this node's database
    usage: wa remember <text>   store a fact in this node's memory
    usage: wa forget <id>   remove a memory by id

(and the same sentences in `scripts/test-cli-help.sh` / `scripts/lib/cli-help-verbs.lua` as check labels, which
only a developer reads).

`wa land mark` (commit `c7bd3d98`):

    wa land mark linux --by-hand --who <name> --why <text> --evidence <file>   record a channel published by hand
    wa land mark: published by hand by <name> (<why>): the channel on <origin>/main names <sha12> for <n> target(s) (verified)
    refused (mark_by_hand_required): the channel step is marked by hand only, and the mark has to say who and why
    refused (mark_by_hand_needs_who): a by-hand publish is recorded with the person who did it
    refused (mark_by_hand_needs_why): a by-hand publish is recorded with the reason it was done by hand
    refused (mark_not_verified): the channel on <origin>/main does not name this commit for every target

`lua/core/land.lua`, the tests step (commit `000bbc5f`):

    refused (description_rows_red): the round changes what a model reads about this node (<paths>) and its
      description rows are red:
    the description rows (<rows>), because the round changes what a model reads about this node: <paths>

`scripts/speed-board.sh` (commit `c7bd3d98`):

    cut -> published by hand (<who>): <why>; journal <release-id>
    the newest release journal (<id>) was published by hand (<who>) and carries no created/updated time

## 5. Proposals (never written)

### HANDOVER.md, step 3 (item 4)

The line, exactly, with the sentence that saves the next operator a refused resume:

    wa release cut --run <id> --resume --no-deploy --signer local --until linux

    The boundary is named AGAIN: a plain `--resume` of a run stopped by `--until` is refused by design
    (lua/core/land.lua, resume_of_stopped_at_until), so the cut has to say where it stopped.
    Bind the result to the node release: the channel's index entry is the ONLY thing a machine with no node
    installs from, so the release is finished when `releases/index-linux.json` on main names it
    (`bash scripts/check-linux-channel-fresh.sh --repo <tree>` says `fresh:`), not when the node release exists.

### HANDOVER.md, for a channel published by hand

    bash scripts/publish-linux-channel.sh --tree <tree> --commit <sha> --tag v<version>   # then commit the index
    wa land mark linux --by-hand --who <name> --why "<why>" --evidence <file>

    The mark verifies the live channel first and refuses if the index is not on main; the speed board then
    says `cut -> published by hand (<who>)` instead of `not a finished release`.

### FACTORY.md, after rule 10 (item 8)

    A landing that touches what a model READS about this node runs the description rows before it lands.
    `rust/wa-capabilities/src/{capabilities,host}.rs`, `docs/HOST.md`, `lua/core/tools.lua`,
    `lua/core/codemode_policy.lua` and `docs/PROMPT.md` owe scripts/test-host-return-docs.lua,
    scripts/test-prompt-tool-names.lua and `bash scripts/sync-prompt-docs.sh --check`; the landing's tests step
    runs them first, whatever else the round is (a capability line IS a Rust change, and a Rust change used to
    skip the tests step entirely - measured 23/11: piped-chat-starts-fast landed 7df9dc7f, main-health on
    5956ae15 went red on test-host-return-docs).

### FACTORY.md, about `--help` (item 6)

    An acting verb that cannot answer `--help` by printing usage and running nothing is a foot-gun: asking
    "what does this do" is exactly what must not deploy. A new verb that acts is added to lua/core/cli_help.lua
    (its list is what scripts/test-cli-help.sh drives).

## 7. Round 1 of the gate: the channel row was red UNDER THE LANDING

The preflight stopped the branch on one row:

    land-quick: the branch's own tests are red: scripts/test-release-channel-e2e.lua
    lua error: check failed: the release channel step publishes over the real scripts and the real signature
      (linux_channel_build_failed: linux-channel: build_failed: scripts/release-linux.sh --target x86_64-unknown-linux-musl ...)

**The cause was mine, and it was a test that only worked in the shell I ran it in.** The stand-ins (the build,
`cargo`, the fake `gh`) lived in `scripts/test-release-channel-e2e.sh`, which put them on PATH before starting
the row. The LANDING does not run that wrapper: it runs a branch's own row as `WA_SCRIPT=<row> wa`, so the row
met the real `node` and `cargo`, the real shipping build failed in that fixture, and the step refused. Green by
hand, red in the gate - and I had reported "rows run singly, all green" without ever running this row the way
the landing runs it. That is the gap this round closes.

**The fix (commit `test: the channel row owns its stand-ins, so the landing can run it`):**

* the stand-ins moved INTO the row (`scripts/test-release-channel-e2e.lua`, "the stand-ins, IN THE ROW"): it
  writes `node`, `cargo`, `cargo-zigbuild` and `rustc` into its own `<home>/e2e/bin`, installs the shared fake
  GitHub, and computes the paths it asserts on (`gh_state`, not `os.getenv`);
* every command the STEP runs goes through `land.exec`, which now prefixes the stand-ins' PATH and variables -
  so the publisher and `scripts/release-linux.sh` (which `impl.linux` starts) see them;
* `scripts/test-release-channel-e2e.sh` is a convenience for a human only: scratch HOME, guard, call. It owns
  no part of the test any more, and says so.
* **No assertion was deleted, no row removed from a list, no timeout raised.** The 20 checks are the same ones.

**Verified, three ways:**

    bash scripts/test-release-channel-e2e.sh                                 -> release-channel-e2e ok (20 checks)
    WA_SCRIPT=scripts/test-release-channel-e2e.lua wa --db <db>               -> release-channel-e2e ok (20 checks)
      (the landing's own invocation: plain PATH, scratch HOME, nothing set up for it)
    the same row on 4b314af5, the landing's way                              -> fails: the channel step builds nothing
      (linux_channel_build_failed, "no built binary at .../rust/target/..."), so it still discriminates.

## 8. Round 2 of the gate: what only the fast PATH found

The first narrowed fast run on the rebased branch (`WA_FAST_ROWS` = the land rows + `test-speed-board.lua`, 29
of 342 Lua rows plus every contract check, `flock -o` on the suite lock) was red on three checks. Two were this
branch's, and neither could be seen by running a row singly - which is what every earlier round did:

    FAIL tmp-cleanliness: scripts/test-cli-help.sh:31 roots its scratch at a literal /tmp (mktemp)
    FAIL tmp-cleanliness: scripts/test-release-channel-e2e.sh:21 roots its scratch at a literal /tmp (mktemp)
    FAIL fast-rows: scripts/test-release-channel-e2e.lua uses the land harness but is not a never-dropped row

Both are fixed in `e3870e26`:

* the two shell rows now take their root from `${TMPDIR:-/tmp}`, the shape `scripts/test-linux-channel.sh`
  already uses, so a run under the runner's own TMPDIR mints there - and the rows' own guard still refuses a
  root inside the operator store (measured by hand on this node, whose TMPDIR is `/home/victor/.wasm-agent/tmp`:
  `REFUSED ... WASM_AGENT_HOME (.../wa-cli-help.XXXXXX/home) is inside the operator store`);
* `scripts/test-release-channel-e2e.lua` is in `wa_fast_core_rows` with the reason written beside it.

Re-run singly after the fix, each green: `scripts/test-fast-rows.sh` fast-rows ok (37 checks);
`node scripts/test-tmp-cleanliness.mjs` PASS (9 checks); `scripts/test-cli-help.sh` ok (42 checks) + cli-help-verbs
ok (113 checks); `scripts/test-release-channel-e2e.sh` ok (20 checks).

The third red was not this branch's:

    FAIL esc-stops-pty: bash: Esc brings the prompt back at once (300 ms idle, 120 ms per unit of load, never
         over 2000) - 2362 ms (limit 1175 ms at load 9.79)

That row is `change/esc-socket-per-thread`'s (on main since `beae64c6`), and this branch's diff touches no pty,
term or provider path (`git diff --stat origin/main..HEAD -- rust/wa-term rust/wa-host` is empty). The same row on
the same tree and binary, run again 20 minutes later, was `esc-stops pty: 18 ok, 0 failed`; and main-health
measured it green on main at 12:34Z (`fast: esc-stops-pty ok (30951ms)`). So it is a load-sensitive timing row on
a machine at load 10-32, not a regression from this branch.

For the record, main-health's own run on `41d6420c` was red on one row - `scripts/test-speed-board.lua`
(`speed-board: 5 FAIL of 30`), main's version of a row this branch rewrites; on this branch that row is green.

## 9. Round 3 of the gate: main's new `canaries` step, and the preflight that caught it

The landing's preflight on the rebase onto `85593e74` stopped the branch on one row:

    land-quick: the branch's own tests are red: scripts/test-land-linux.lua
    lua error: check failed: the channel step comes right after the deploy (got 14, want 13)

main had gained a `canaries` step ("every feature this node runs proves itself, after the deploy read-back")
between `deploy` and `linux`, so `position.deploy + 1` was no longer the channel. The adjacency was a fact about
one plan; the invariant the row exists for is that the channel publishes AFTER the ring, because the channel
moves main and a node deploys a commit only while `HEAD == origin/main ==` that commit.

`407ab1bb` keeps the invariant and NAMES the allowance as an allow-list rather than widening a comparison: the
steps between the deploy and the channel must be exactly `canaries` - a step that reads the deployed bytes without
writing main - and any other step in that gap has to be added to the row in its own right. No assertion was
deleted, the row still says the report is last, and it still counts 121 checks. (The discrimination check sees a
MODIFIED row that passes on the base as `unchanged-verdict`, which does not block; this row discriminates anyway,
because its by-hand cases need `wa land mark` from `7d54d172`.)

Every row this branch touches, run SINGLY on `85593e74` (no suite lock, rule 15), all green:

    test-land-linux.lua          land-linux ok (121)      test-land-rows.lua          land ok (137)
    test-land-plan.lua           land ok (109)            test-land-gate-rows.lua     land ok (82)
    test-land-until.lua          land ok (102)            test-land-marks.lua         land ok (27)
    test-land-release.lua        land ok (72)             test-land-resume.lua        land ok (42)
    test-land-quick-tests.lua    landing ok (49)          test-land-resume-19-11.lua  land ok (22)
    test-release-channel-e2e.lua release-channel-e2e ok (20)  test-land-sign.lua      land ok (46)
    test-land-review.lua         land ok (47)             test-land-health-program.lua ok (8)
    test-land-quick.lua          landing ok (81)          test-land-quick-main.lua    landing ok (26)
    test-land-quick-components.lua ok (12)               test-land-quick-install.lua landing ok (23)
    test-land-gate-log.lua       land-gate-log ok (8)     test-speed-board.lua        speed-board ok (35)
    test-cli-help.sh             cli-help ok (42)         test-release-channel-e2e.sh release-channel-e2e ok (20)

The narrowed fast path itself was run on `41d6420c` (section 8: 29 of 342 Lua rows plus every contract check,
594 s) and not again on `85593e74`: the suite lock was held by main-health and two missions (a run queued 25
minutes without starting), and the landing's own preflight - which is that same run - is what found this round's
red. That is the honest state: the rows above are measured on this base, the whole-path run on this base is the
preflight's.

## 10. The narrowed fast path on the final base, and the one row that is not this branch's

Run on the branch tip `d1f90cca` on `85593e74`, under the suite lock, `WA_FAST_ROWS` = the nineteen land rows +
`test-speed-board.lua` (30 of 350 Lua rows plus every contract check):

    fast: lua 30/30 passed          prompt-docs ok   discrimination ok   landing-queue ok   deploy-wait ok
    fast: linux-channel ok          cli-help ok      release-channel ok  install-front-door ok
    FAIL esc-stops-pty (exit 1): bash: Esc brings the prompt back at once ... 790 ms (limit 466 ms at load 3.88)

The run was cut at the pty tail by the harness (the operation's owner detached while a node install was
pending), so it printed no summary line of its own; every check it reached before that line is listed above.

`esc-stops-pty` is `change/esc-socket-per-thread`'s row (on main since `beae64c6`) and it is intermittent on
this node, measured four times on THIS tree and binary with nothing else of this branch's running:

    12:58Z  18 ok, 0 failed
    14:44Z  17 ok, 1 failed    790 ms (limit 466 ms at load 3.88)
    15:10Z  17 ok, 1 failed    894 ms (limit 422 ms at load 3.52)
    15:15Z  17 ok, 1 failed    945 ms (limit 744 ms at load 6.20)

This branch's diff contains no Rust at all and no pty, terminal, chat or opening file (`git diff --name-only
85593e74..HEAD` lists nineteen files: `docs/missions/reports/...`, `lua/core/{cli_help,init,land}.lua`,
`scripts/release-linux.sh`, `scripts/speed-board.sh`, four `scripts/lib/*`, eight `scripts/test-*` and
`scripts/fast.sh` / `scripts/test.sh`). It is reported, not touched: loosening another mission's budget is
not this branch's to do, and `main-health` measures that row on main with main's own build.

## 6. What was not verified, and what is open

* **No real release was cut and nothing was pushed to origin.** The proof is the next cut; by the brief's own
  test, the channel step must publish v0.1.2 by itself and `curl -fsSL .../install.sh | sh` on a scratch HOME
  must print `wasm-agent v0.1.2 · v<sha>`.
* **The full cross build was not run here**: no `zig` on PATH on this node. The receipt/artifact plumbing is
  proved by the row and by a direct `cargo-zigbuild build --message-format=json` on a scratch crate.
* **The full suite was not run** (the G-wave rule: a landing runs no gate, the gate runs at release). A NARROWED
  `fast.sh` was run under the suite lock - `WA_FAST_ROWS` = the nineteen land rows plus `test-speed-board.lua`,
  which came to 29 of 342 Lua rows plus every contract check, 594 s - and its two red rows are section 8. On
  the final base (`85593e74`) every row this branch touches was run SINGLY instead (a single test file needs no
  suite lock, rule 15) because the lock was held by main-health and two missions; the list with its counts is
  section 9. `main-health` runs the whole check on main.
* **`luac -p lua/core/land.lua` fails on base too** ("attempt to assign to const variable 'path'", line 1376);
  pre-existing, not this branch. Rows are the verdict, and they run.
* **One self-inflicted incident, recorded so the next session does not repeat it.** A new test case at
  `scripts/test-land-linux.lua` called the harness's `must(...)` without its `cwd` argument, so `git add -A &&
  git commit` ran in the WORKTREE under test and created two junk commits; the `git push origin main` that
  followed was refused (non-fast-forward) and `origin/main` stayed at `7865a08e` (checked with
  `git ls-remote`). The commits were removed with `git reset --mixed 46d1ee99` - that is the pre-rebase name of `fb6ca151` - (no stash, nothing lost), and the
  call now passes `repo` with the reason in a comment. `must` without a cwd runs in the node's working
  directory - the fixture helper must always name its repository.
