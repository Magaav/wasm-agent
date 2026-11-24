# session-isolation-git - one session's commit landed in another session's worktree

Mission branch `change/session-isolation-git`, base `origin/main` 51c2cf62. Every claim below cites the
commit or the measurement that produced it, and every git command in this mission ran as
`env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git -C <my own worktree> ...`.

## 1. The incident, re-measured before any code was written

| premise | re-measurement |
| --- | --- |
| commit 783ae80c exists and landed in whatsapp-read's worktree | `git -C .../whatsapp-read-is-consistent/wt cat-file -p 783ae80c`: parent `2b11c0b3` (that worktree's HEAD then), one file changed, `components.lock`. `git reflog --date=iso`: `783ae80c HEAD@{2026-11-24 08:49:31 -0300}: commit: r8a(12): ...` |
| the two sessions were in two worktrees of ONE repository | `rev-parse --git-dir` of the two trees: `.../checkout/.git/worktrees/wt47` (whatsapp-read) and `.../checkout/.git/worktrees/wt29` (deploy-hold); one common dir, `.../checkout/.git` |
| the deploy-hold command said `cd` into its OWN worktree | re-read from `~/Work/missions/deploy-hold-never-fails-our-load/out.log` (~188740-188800): `const w = ".../deploy-hold-never-fails-our-load/wt"` then `cd ${w} && ... git add -A lua scripts && git commit -q -F m.txt`, with `cwd: w`. The brief is right: an explicit `cd` into its own worktree |
| the session never noticed | `grep -n 783ae80c out.log` in that mission: no hit at all. The `git log --oneline -1` in that same command had nothing to show, because the commit was not in its worktree |

So the working directory was never the question. Only git's own environment can move a commit to another
worktree.

## 2. The mechanism, with file:line

`rust/wa-operation/src/process.rs:76` is the one place every tool child (the `bash` tool, `operation start`, a
hook command, a component launch) is spawned:

```rust
// rust/wa-operation/src/process.rs:75-79
crate::scrub_inherited_env(&mut command);
for (k, v) in &spec.env { command.env(k, v); }
```

`scrub_inherited_env` (`rust/wa-operation/src/lib.rs:117`) removed the names of `DENY_ENV`
(`lib.rs:36`) and the shapes of `DENY_ENV_SUFFIXES` (`lib.rs:54`) - credentials, one and all - and **not one
git name**. Std `Command` hands the parent's environment on when nobody says otherwise, so whatever `GIT_*`
the node itself carried reached every session's bash, in every worktree, for the life of that node.
That is enough to move a commit: with `GIT_DIR` set, `git add`/`git commit` write THAT repository's index
and HEAD, and the `cd` in the command only chooses where relative paths resolve.

What the brief's three candidates measured out to:

* **(a) a process-wide `set_var`/`remove_var` of a `GIT_*` name** - **no site in the product.**
  `rg -n 'GIT_' rust lua`, excluding tests: the only git name the node ever sets is
  `GIT_TERMINAL_PROMPT=0` on its own two git commands (`rust/wa-capabilities/src/disk.rs:456` and
  `:1068`), plus `GIT_CONFIG_NOSYSTEM/GLOBAL/SYSTEM` handed to the harness-evaluator's own child
  (`lua/core/harness_evaluator_reviewer.lua:250`, `lua/core/harness_evaluator_replay.lua:348`). There is
  no `set_var` or `remove_var` of any `GIT_*` anywhere. 544ae50e touched `lua/core/server.lua`,
  `lua/core/tools.lua` and `scripts/test-peer-bash-changes.lua` (`git show --stat 544ae50e`): no git
  environment in it. **The brief's hint (a) is stale.**
* **(b) a node started under a git hook** - plausible (git exports `GIT_DIR` and `GIT_INDEX_FILE` to every
  hook it runs) and **not reconstructable after the fact**: the live serve (`pid 3677384` on :8799) and the
  live `wa chat` processes carry **0** `GIT_*` names in `/proc/<pid>/environ` today. The node that served
  11:49:31Z on 24/11 is not the same process generation, so **the source on that minute is UNKNOWN, and is
  named as unknown here**. It does not have to be known: the fix makes the whole family unable to reach a
  child, whoever exports it.
* **(c) the child's environment built from the serving process's environment** - **this is the mechanism**,
  at the file:line above: an inherited environment with a deny list applied at the boundary, and git was
  not on that list.

One more surface of the same rule, found while looking and fixed in the same mission: the node's OWN git.
`rust/wa-capabilities/src/disk.rs:452` (`fn git`: branch, status, diff that a change list shows) and
`disk.rs:1063` (`fn remove`: `git -C <worktree> worktree remove --force <path>`) ran with the inherited
environment too. With a `GIT_DIR` handed down, the read shows another session's files and the remove
unregisters **another** worktree.

## 3. The fix

One rule, written once, applied at every spawn that crosses it:

* **7eb845ac** - `rust/wa-operation/src/lib.rs`: `GIT_ENV_KEEP` (the names that cannot choose a repository,
an index or a working tree) and `git_env_withheld` (every `GIT_*` name not on that list is withheld, by
FAMILY, so a name git invents later cannot re-open it). `denied_env` now carries the rule, and it already
feeds both `scrub_inherited_env` (`process.rs:76`, unix) and `windows.rs:187` - so it is one place on both
platforms, and `spec.env` (a name a caller explicitly hands over) is still applied afterwards.
* **189d24a0** - `rust/wa-operation/src/lib.rs` adds `pub fn scrub_git_env`; `disk.rs:452` and `disk.rs:1063`
build their `Command` by hand and call it, so the node's own git reads and removes the worktree it names.
* **de290e59** - `scrub_inherited_env` also SAYS it, once per (name, serving pid)
(`report_git_env_withheld`, `rust/wa-operation/src/lib.rs`): the line carries that pid and the SERVING
process's own command line (`/proc/self/cmdline`, with `std::env::args` as the fallback), so the next
occurrence of this accident names its own source instead of costing an investigation like this one. A line
per spawn would bury the log - one session starts hundreds of children a minute.

Withheld now, by shape: `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_COMMON_DIR`,
`GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_NAMESPACE`, `GIT_PREFIX`,
`GIT_QUARANTINE_PATH`, `GIT_CEILING_DIRECTORIES`, `GIT_DISCOVERY_ACROSS_FILESYSTEM`, `GIT_GRAFT_FILE`,
`GIT_SHALLOW_FILE`, `GIT_REPLACE_REF_BASE`, and `GIT_AUTHOR_*`/`GIT_COMMITTER_*` (a commit is authored by
the repository's configured identity, per `AGENTS.md`).

Kept, and why each cannot pick a repository: the config SOURCE (`GIT_CONFIG_GLOBAL`, `_SYSTEM`,
`_NOSYSTEM`, `_PARAMETERS`, `_COUNT`, `_KEY_*`, `_VALUE_*`) - **measured 24/11**: `core.worktree` in a
global config, and in `GIT_CONFIG_PARAMETERS`, does NOT move `git -C <repo> rev-parse --show-toplevel` (git
reads it from the repository's own config); the transport (`GIT_SSH*`), the prompt
(`GIT_TERMINAL_PROMPT`, `GIT_ASKPASS`), the pager/editor and the trace switches. Keeping the config source
is what lets every hermetic `GIT_CONFIG_GLOBAL=/dev/null` in `scripts/*.sh` keep working through a child.

Proof that no process-wide mutation is involved, and none is added: the row asserts BOTH halves - the node
still answers `host.getenv('GIT_DIR')` with the value it was started under, and a child of it sees none.
`rg -n 'set_var|remove_var' rust` still finds no `GIT_*` anywhere (cited above).

## 4. The row: red before, green after

`scripts/test-git-env-isolation.sh` (+ `scripts/test-git-env-isolation.lua`) - **c543918c**. Two REAL nodes,
each with its own scratch `HOME` and its own database, started from a parent that carries `GIT_DIR`,
`GIT_INDEX_FILE` and `GIT_WORK_TREE` (the shape a git hook leaves). Two linked worktrees of ONE scratch
repository; each session commits 50 times into its own worktree **at the same moment**, through
`host.exec` - the same child the `bash` tool runs (`lua/core/tools.lua:1426` -> `host.exec` ->
`wa_operations::foreground` -> `wa_operation::Process::spawn`), never a direct dispatch. Then the staged
half of the incident: one session stages a file and does not commit, the other commits, and the staged file
must still be staged and in no commit of the other.

| run | verdict |
| --- | --- |
| **base 51c2cf62** (`/tmp/base-gitenv`, own `CARGO_TARGET_DIR=.../m-session-isolation-git-base`, no git-env change) | **RED, exit 1**: `session a (.../repo/s1): its bash child inherits NO GIT_DIR, it saw: .../repo/main/.git/worktrees/s1` and `session b (exit 1): Another git process seems to be running in this repository, or the lock file may be stale` - session b (own worktree s2) died inside the 50-commit loop because both sessions were committing into worktree s1's index. The two lines name the whole accident |
| **this branch** (7eb845ac + 189d24a0 + de290e59) | **GREEN, exit 0**: `git env isolation ok (116 checks, two sessions, 50 commits each, one repository)` (110 checks before de290e59 added the reporting section) |

Wired: `scripts/fast.sh:976` as the check `git-env-isolation`; `scripts/test-git-env-isolation.lua` is
declared a helper in `scripts/fast-path.exclude:57` for the same reason `scripts/test-session-isolation.lua`
is - it is one session of the two, and a bare run has no worktree to guard. In the fast path it runs in
3.4 s and passes (`wa-fast-result.json`, `git-env-isolation`, status `pass`).

Rule test in the crate (`rust/wa-operation/src/tests.rs`, 7eb845ac):
`a_git_name_that_can_choose_a_repository_is_withheld_from_tool_children` - `cargo test -p wa-operation --lib`
61 passed, 0 failed. `cargo test -p wa-capabilities --lib disk` 15 passed, 0 failed (189d24a0).

## 5. Rows run with this build

| row | verdict |
| --- | --- |
| `scripts/test-session-isolation.sh` | 154 checks, 0 failed |
| `scripts/test-operation-cwd.lua` | `operation cwd ok (31 checks)` |
| `scripts/test-remote-pending.lua` | `remote pending ok (90 checks)` |
| `scripts/test-git-env-isolation.sh` (new) | `git env isolation ok (110 checks, ...)`, exit 0 |
| `bash scripts/fast.sh` under `flock -o ~/Work/missions/.suite.lock` | 470 checks, **6 failed**, 1 skipped (1000 s) |
| `bash scripts/fast.sh` on base 51c2cf62, same instrument | 467 checks, **7 failed**, 1 skipped (690 s) |

**None of the 6 failures is this branch's.** Each was measured on the base tree, not assumed:

| failed row (this branch) | measured on base 51c2cf62 |
| --- | --- |
| `esc-stops-pty` | failed there too (same assertion: `Esc gives back a usable prompt at once (300 ms idle, ...)`) |
| `install-guards` | failed there too, the same 6 internal checks |
| `test-host-return-docs.lua` | failed there too, run directly in `/tmp/base-gitenv`: `1 of 10 checks failed`, `every capability that answers JSON text says so: ["run_cancelled"]` |
| `test-land-quick-tests.lua` | cascade of the row above (its message names host-return-docs and prompt-tool-names) |
| `test-selfloop-component.lua` | failed there too in the base fast path: `PARITY: schedule a time wake differs` |
| `rust wa-capabilities` | measured directly in BOTH trees: `documented_inventory_matches_the_live_registry` fails with `registered but undocumented in docs/HOST.md: ["run_state"]`, and `await_returns_at_its_own_wait`/`adoption_survives_the_relay_deadline`/`promotion_says_so` fail the same 4 ways - identical in `/tmp/base-gitenv` (`0 passed; 4 failed`) and here |

The base run failed two rows this branch did not: `deploy-bound` and `test-graph-crash-recovery.lua`. They
are not evidence of anything on this branch - they are load-sensitive rows of the base that behaved better
on the second run of the day, and the branch does not touch either surface.

## 6. Texts to approve

The wrapper's operator-visible lines (new):

1. `no binary at %s`
2. `could not create the scratch repository`
3. `could not make the base commit`
4. `could not create worktree %s`
5. `could not read the first worktree's git dir`
6. `could not read the base commit`
7. `git env isolation: session a (exit %s): %s` / `git env isolation: session b (exit %s): %s`
8. `worktree s1 carries a commit that is not session a's: %s` (and the `s2`/`session b` mirror)
9. `session a has %s of its 50 commits in its own worktree` (and the `session b` mirror)
10. `worktree s2 never moved: session b's commits went somewhere else`
11. `session a's staged file is not still staged in its own worktree: '%s'`
12. `session b's commit swallowed session a's staged file`
13. `git env isolation ok (%s checks, two sessions, 50 commits each, one repository)`

The row's own lines (a reader sees one of these when it fails):

14. `this row makes real commits; it refused to run in %s`
15. `the wrapper did not name the two worktrees this session owns and does not own`
16. `session %s (%s): the node itself still carries %s - the wrapper must export it for this row to test anything`
17. `session %s (%s): its bash child inherits NO GIT_DIR, it saw: %s`
18. `session %s (%s): no git name that can choose a repository reaches the child, it saw: %s`
19. `session %s (%s): GIT_TERMINAL_PROMPT still reaches the child (kept): %s`
20. `session %s (%s): commit %s failed: %s`
21. `session %s (%s): the commit ran in my own worktree, not in %s`
22. `session %s (%s): the top of my own worktree is my commit - wanted %s, found %s`
23. `session %s (%s): waited %ss for %s and it never appeared: %s`
24. `session %s (%s): could not stage its own file: %s`
25. `session %s (%s): a-staged-only.txt is staged in my own worktree`
26. `session %s (%s): my staged file is STILL staged after the other session committed: %s`
27. `session %s (%s): the other session's commit did not land on top of mine: %s`
28. `session %s (%s): its final commit failed: %s`
29. `session %s (%s): its final commit is in its own worktree`
30. `session %s: git env isolation ok (%d checks) in %s`

31. The node log line, once per (name, serving pid) - `rust/wa-operation/src/lib.rs`, de290e59:
    `[tool-env] withheld %s from a tool child: this node's own environment carries it, and it can point a git
    command at another repository - the child runs with it removed, whatever directory it cd's into. Reported
    once per name and serving process: pid %s cmdline %s`
    Its row (`scripts/test-git-env-isolation-report.lua`, de290e59) checks four things from the node's own
    stderr: exactly one line per name for two spawns, the serving pid, the serving process's command line,
    and that the child's command line is NOT the one in the line.

Changed operator-visible BEHAVIOUR with no new sentence: a node started under a git hook now lists those
names in the existing `withheld_from_tool_children: ...` note (`rust/wa-operation/src/lib.rs`, unchanged
text), because the rule it describes now covers them.

## 7. Not done, and still unknown

* **Unknown, and said so:** which process exported the `GIT_*` that reached the deploy-hold session's bash at
  11:49:31Z. The product has no site that sets one (measured above), and the live node carries none today,
  so the source cannot be reconstructed. The fix removes the consequence, not the historical cause.
* **Not done:** nothing was pushed, and nothing was run against the live node or the fleet (no `wa call`, no
  `tools.remote`, no `nodes.list`, no land, no deploy). The two nodes in the row are scratch homes with no
  rendezvous and no relay.
* **Instrument kept for re-measuring:** the base build cache
  `/home/victor/wasm-agent/target/m-session-isolation-git-base` (built from a detached worktree of
  51c2cf62, which was removed afterwards so the shared checkout keeps no stray registration; recreate it
  with `git worktree add -f /tmp/base-gitenv 51c2cf62`). The red-before line above is reproduced from
  THIS tree with that binary: `WA_BIN=/home/victor/wasm-agent/target/m-session-isolation-git-base/debug/wa
  bash scripts/test-git-env-isolation.sh` (exit 1, both session lines).
