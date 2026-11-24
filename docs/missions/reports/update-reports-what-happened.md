# update-reports-what-happened - SLICE 1: `wa update` follows the install it asked for

Branch `change/update-reports-what-happened`, base `origin/main` = 5bb28d8a. This round implements the
**slice 1** the brief names (Fable/Victor 24/11 ~15:40Z) and the two additions Fable sent at ~16:05Z and
~16:10Z. The rest of the Job (items 1-6, the real-pty acceptance test, the release-channel decision) is
NOT in this branch; what it still needs is listed at the end.

## What was measured first (rule 9: re-measure the brief's premises)

Read on this node, 24/11:

- `scripts/lib/build-status.sh` writes `$WASM_AGENT_DATA/build-status.json` with
  `state/phase/done/total/crate/commit/started_at/at` - and it exists here (`~/.wasm-agent/build-status.json`,
  24/11 12:49). **Brief confirmed.**
- `rust/wa-sentinel/src/queue.rs` writes `sentinel/queue/<id>.json` (`state/phase/detail/queued_at/updated_at`),
  `finish_request` writes `sentinel/done|failed/<id>.json` (`ok/detail/phase`), `deploy_outcome.rs` writes
  `sentinel/deploy-outcome/<id>.json` **only when a session was named**, and `scripts/deploy.sh:167` writes
  `<install>/deploy-result.json` (`ok/commit/detail/at/request_id`). The brief names three sources; the
  sentinel's own **queue** record is a fourth, and it is the one that says *what holds a request*.
- `scripts/deploy.sh:967/1048/1062` does try a published binary first and falls back to building. **Brief
  confirmed.**
- `~/.wasm-agent/update-check.json` exists, schema 2, five window entries with **asset names** - so "is commit
  X published for this triple" is a local lookup. **This is the fourth premise the brief did not name.**
- `lua/core/update.lua` `M.run` reaches the release path only when there is no tree (`if not facts.tree`), so
  on a tree install `/update`/`wa update` always means main. **Brief confirmed** (`update.lua:785` area).
- NOT re-measured here, by rule: anything on `work` (its install record, its sentinel's box, the doubled
  `ship-wave.mjs` path, the `WASM_AGENT_RAW_CODE=only` refusal). This branch touches none of them.

## What changed

| commit | what |
| --- | --- |
| `51a4e192` | `lua/core/update_follow.lua` (new), `update_banner.published/release_list/listing`, the `wa update` dispatch in `init.lua`, the remote follow in `remote_update.lua`, `scripts/test-update-follow.sh` |
| (this commit) | `scripts/test.sh` wiring, `lua/core/cli_help.lua` usage lines, `docs/RELEASE-UPDATE.md`, `docs/REMOTE-UPDATE.md`, this report |

### `lua/core/update_follow.lua`

Reads only what a deploy already writes, and makes no request and writes nothing. Sources in the order it
trusts them: the installer's `deploy-result.json` (**matched by request id**, never by recency - `deploy.sh:2189`
names that trap), `build-status.json`, the sentinel's `failed/` and `done/`, `deploy-state.json`,
`build-status.json`'s progress, the sentinel's `queue/` record, the request still in the box, and
`deploy-pending.json` (the bound the installer itself wrote).

- one line per change of phase, each with the elapsed time since the request was queued (the queue record's
  `queued_at`, so `--follow` started late still shows the install's real duration);
- a heartbeat every 30 s while nothing changes (a cold build is never drawn as dead - item (d) of the Job, by
  construction: the follower reports "still building 48/456 · 6m30s" forever, never "silent");
- the final line names the installed commit and the command exits 0; a failure prints the phase, the reason,
  the elapsed time and a `next:` line, and exits 1 (the 15:34:55Z acceptance case);
- `--detach` returns at once with the one command that re-attaches; `--follow` attaches to the newest deploy in
  flight; Ctrl-C stops following only, because the installer is a process the sentinel spawned detached.

**How the request is matched.** `deploy-result.json` carries `request_id`; when it does not match this request
(and the id is not empty) the record is not this install's. When an old installer wrote no id, the ISO `at` is
compared with the ISO stamp of the request - never a floating one. A record that matches neither is not claimed.

### `lua/core/update_banner.lua` - the local "is it published?" answer

`M.release_list` (the cache, no fetch), `M.published(commit)` and `M.listing` (installed + behind-by). Three
answers and no fourth: `published` (the window names the commit **and** carries this target's three assets);
`none` (an entry names it but has no asset for this triple, **or** local ancestry proves the commit is newer
than every entry - `git merge-base --is-ancestor` on objects already on disk, no network); `unknown` (no list,
or a commit the list does not name and ancestry cannot order). A `none` is never produced from "I did not find
it".

`options.target` is the **triple** in this module (the spelling `M.target` and `M.installable` already use);
`M.listing` takes the commit to compare as `options.target`, so it builds a copy of its options without either
key before it calls `M.published` - the two meanings are named in a comment where they meet.

### The commands

`lua/core/init.lua`: the plan line is printed **first**, then the queue line; `--detach` returns; otherwise the
command follows and its exit code is the install's. `--check` also prints `M.listing`'s lines (b)(i).
`lua/core/remote_update.lua`: `wa update <node>` asks, then reads the peer's own `status` every 10 s (one
fabric call; a per-second poll is the relay storm this tree already paid for on 19/11) and prints each state
change with its clock; `--detach` returns; `--follow` attaches to the newest record without asking for anything;
`--status` and `--json` keep their single-answer shape, because agents parse those.

## The test, and how it discriminates

`scripts/test-update-follow.sh`, wired into `scripts/test.sh` next to the `/update` row. It drives the **real**
`wa update` against a scratch node (`WASM_AGENT_HOME` under a `mktemp` dir, refused by
`scripts/lib/scratch-home.sh` if it lands in the operator's store) whose sentinel is a stub: on `request deploy`
the stub writes the request file and starts a stub deploy that writes the **same files, in the same shapes**, a
real one writes (`scripts/lib/build-status.sh`'s JSON, `queue::observe`'s record, `deploy.sh`'s `write_result`).

Five cases: (1) `--check` answers for the installed commit and the one behind it, from the fixture release
list, and writes no request; (2) the first line is exactly `no published binary for <sha> on
x86_64-unknown-linux-gnu: building from source, minutes`, every phase prints with `n/m` and its clock, the
final line names the commit and the exit is 0; (3) a build that ends `state=failed` prints
`failed: compiling: no built binary at .../release/wa · <elapsed>`, a `next:` line and exits 1; (4) `--detach`
returns in under 4 s for a 10 s deploy and names `wa update --follow`; (5) `--follow` attaches to the deploy in
flight and prints its final line.

Measured, on this node, with the tree's Lua and the installed binary:

```
  ok: --check answered for the installed commit and for the one behind it, from the local list
  ok: the first line named the target and the build, every phase printed with its clock, the final line named 35ddce93984b, exit 0
  ok: the failure printed its phase, reason, elapsed time and next step, and exited 1
  ok: --detach returned in 1s and named the command that re-attaches
  ok: --follow attached to the deploy in flight and printed its final line
update follow ok
```

On the base (`origin/main`, a separate worktree - never a stash) the same row fails at its first check with
`the first line must name the target and download-or-build, got: queued: the sentinel will deploy ...`, which is
the command as it was.

## Texts to approve

Every string this branch adds, verbatim (U+00B7 is the `·` in each line; U+2014 the `—`):

1. `install: published binary for <sha12> on <triple> — download, no build`
2. `no published binary for <sha12> on <triple>: building from source, minutes`
3. `install: the release list here cannot say whether <sha12> is published on <triple> (<reason>): the installer tries a published binary first and builds if there is none (minutes)`
4. `install: the published binary is used when one exists for this node's commit; otherwise it builds here (minutes)` (no target commit known)
5. `following: Ctrl-C stops following; the install continues (wa update --follow re-attaches)`
6. `detached: the install continues without this terminal; wa update --follow re-attaches`
7. `following the newest deploy on this node: <request path>`
8. `nothing to follow: <why>; wa update starts a new one`
9. `installed <sha12> · <elapsed>`
10. `installed (the installer named no commit)` / `installed (installed.txt names no commit)`
11. `failed: <reason> · <elapsed>` and `failed: the installer exited without a reason · <elapsed>`
12. `next: this node still runs <sha12>; the installer's own output is <sentinel>/deploy.out` and
    `next: the deploy's own output is <sentinel>/deploy.out`
13. `waiting: for this node to be idle (<phase>)` / `waiting: <the sentinel's own hold detail>`
14. `installer started: <detail> · <elapsed>`
15. `queued: the sentinel has not performed it yet · <elapsed>`
16. `no phase reported yet: waiting for the sentinel to observe this request · <elapsed>`
17. `installing: stopping the node and switching binaries (<phase>) · <elapsed>`
18. `failed: upgrade.sh stopped in <phase> · <elapsed>` and `failed: <the sentinel's detail> · <elapsed>`
19. `building <n>/<total> <phase> <crate> (published binary, no build) · <elapsed>` and the same with `(from source, on this machine)` - the installer's own declaration from `deploy.out`
20. ` (<by>: paused turns, bound <n>s, <n>s left)` - appended to a waiting line when `deploy-pending.json` says so
21. remote: `<node>: <state> — <detail> · <elapsed>`, `installed <sha12> on <node> · <elapsed>`,
    `FAILED on <node>: <detail> · <elapsed>`, `SILENT on <node>: <detail> · <elapsed>`
22. remote: `detached: the install continues on <node>; re-attach with wa update <node> --follow`
23. `--check`: `release list: <n> entries, read <YYYY-MM-DD HH:MMZ>, newest <tag>`,
    `release list: not readable here (<reason>), so nothing is claimed about what is published`,
    `this node (<sha12>): <published fact>`, `behind by (<sha12>): <published fact>`,
    `this node: its install record names no commit, so what it is published as cannot be asked`
24. published facts: `published binary for <sha12> on <triple> (<tag>)`, `no published binary for <sha12> on <triple>`,
    `the release list cannot say whether <sha12> is published on <triple> (<reason>)`
25. help: `usage: wa update [--check] [--detach|--follow]   update THIS node (...)`, the second usage line now ending `[--json] [--detach|--follow]`, and
    `  --follow follows the install to its end, and is the default; --detach asks and returns at once`;
    `wa update <node> --help` gains `wa update <node> [--follow|--detach]  asks, then follows the node's own answer until it settles` and
    `  --follow   attach to the newest record without asking again; --detach asks and returns`

## What I could NOT verify, and the limits of this slice

- **The plan line is a lookup into a list, not a promise.** `none` is proved by local ancestry against the list
  this node holds; the list holds the newest few releases (`per_page`, default 5). A commit *older* than the
  window is `unknown`, and the line then says so rather than claiming a build. A release cut for this exact
  commit *after* the list was last read would also read as `none` - the `--check` listing carries the list's
  date for that reason, the plan line does not. Nothing here refreshes the list (that is the "pull trigger"
  Fable said comes after the cut); on a tree node `update_banner.check` returns before the cache, so the list
  is only refreshed on a node that reads the release feed.
- **No real pty, no real deploy, no live node.** The row proves the command against a stub deploy that writes
  the real shapes; the ACCEPTANCE TEST in the brief (the window coming back on the new build with the session
  carried over, on a tree and a release node) is NOT done here, and neither is the `remote_update.read_status`
  fallback (Job item 4), the doubled-path fix (1a), the continuation flags (1b), the build-dir/install-path
  agreement (1c), the pre-install env check (3), the release-channel switch (5/ADDED 23/11 15:35Z), or
  `deploy-result.json` separating installed from follow-on failure (2).
- **`--detach` under 4 s** is asserted for the fixture; a real node's `wa update` also takes a backup before it
  writes the request, which is not part of that 4 s here.
- The remote follow is exercised by nothing yet: `scripts/test-remote-update.lua` does not drive
  `M.follow_remote`. It is a loop over the existing `status` action, but a loop that is not run is not proved -
  named here rather than claimed.

## Left for the next slice (unchanged from the brief)

1. Job items 1a-1c, 3, 6; the release-channel decision (23/11 15:35Z) and item 5's replacement;
2. the ACCEPTANCE TEST in a real pty on a scratch node, both install kinds, with the measured time from
   `/update` to the new header;
3. a row for `M.follow_remote` (two scratch homes, the peer's `status` answered from its own files).
