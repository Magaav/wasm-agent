# A deploy never silently goes backwards

Four rules, one place each. They exist because of one day.

MEASURED 18/11. The node on `work` ran a binary built from 8 commits that were on no landed branch, shipped by
a helper that fetched a ref into a detached HEAD and built it. Its `installed.txt` said `commit=14963b6f` — the
id of an older landed commit those 8 contained. A sentinel deploy of `main` compared itself against that record,
saw an ancestor, replaced the node, and the features in those 8 commits were gone. Earlier the same day three
rollbacks were made by hand (mail and nextcloud back to their glibc-2.30 binaries, `work` back to the codeact
build) and none of them was recorded anywhere, so nothing knew a node had been put somewhere on purpose.

## 1. The binary answers for itself

`rust/wa-host/build.rs` compiles in the commit, the git tree, whether the checkout was dirty, and every ancestor
of the commit. Two commands read it, and both run before the home directory, the environment file, the database
or the Lua tree are touched — a rollback runs on a node where those are broken:

```
wa --build-info          version, commit, tree, dirty, source, built_epoch, ancestors
wa --contains <commit>   exit 0 yes · 1 no · 2 unknown (no ancestry embedded, or a malformed id)
```

A build that no git could identify says `commit=unknown`; it never invents one.

## 2. Every install path writes its record FROM the binary

`scripts/lib/install-record.sh` is the only writer (`wa_record_install`) and the only ancestry verdict
(`wa_ancestry_verdict`). `scripts/deploy.sh`, `scripts/upgrade.sh`, `scripts/fleet-install.sh`,
`scripts/linux/bootstrap.sh` and `scripts/rollback-node.sh` all route through it, and it drops any `commit=` a
caller hands it (the drop is written into the record as `dropped_caller_field=`). A deploy whose installed bytes
report a different commit from the one it meant to install refuses: `refused(build_commit_mismatch)`.

The record carries `build_info=yes|absent`, so a reader can tell "the bytes said so" from "nobody could say".

## 3. The ancestry guard, asked of what is RUNNING

Before replacing anything, a deploy asks the installed binary for its commit and whether the target contains it
— git where there is a checkout (`deploy.sh`, `upgrade.sh`), the candidate binary's own embedded ancestry where
there is not (`fleet-install.sh`, `bootstrap.sh`, and the previous pair a `rollback-node.sh` restores). If the
target does not contain it, the deploy refuses and lists the commits that would be lost:

```
downgrade refused(node_not_contained): the running binary is commit <sha> (1 commit(s) would be lost) and this
tree <sha> does not contain it ...
lost commits, newest first:
  <sha> the subject of the commit that would be lost
```

A binary older than `--build-info` cannot answer, and the record is then the only evidence left - and the
record can be a lie. MEASURED on this machine's own node and on `work`, 18/11: `installed.txt` said
`commit=14963b6f sha256=4248d61b` while the bytes were `fc6a9d80`, and `14963b6f` IS an ancestor of main.
So the fallback is checked against the bytes first: `wa_record_describes` compares the record's `sha256=` with
the installed binary's, and a mismatch refuses as `downgrade_unprovable(record_not_this_binary)`, quoting both
hashes. The override is the same `--force --reason`, and it records `ancestry_unverified=yes`.

Three answers, and every one of them is used: yes (0) may proceed, no (1) refuses, and "cannot tell"
(2) REFUSES TOO, unless the operator records `--force --reason <text>`. It is not the same refusal as a known loss:
it says what could not be established and how to make it answerable. An earlier revision let "cannot tell" through
with a note, on the argument that refusing out of ignorance blocks installs; MEASURED 18/11, that is what let a
deploy replace a build of 8 commits nobody else had - the running commit was simply absent from the deployer's
checkout, the verdict was 2, and the deploy went on. The one case that is not a refusal is a FIRST install: no
record and no binary naming a commit is a machine that never had one, and the callers check it before they ask.

What "the running commit is missing from this checkout" means depends on why, and the verdict says which:

| the checkout | the running commit | verdict |
| --- | --- | --- |
| complete history, commit present, target contains it | - | 0 |
| complete history, commit present, target does not contain it | - | 1, with the commits that would be lost |
| complete history, commit ABSENT (never pushed here) | - | **1** - nothing from this history can contain it (18/11) |
| shallow, commit absent | - | 2, naming `git fetch --unshallow`; the running binary is asked first |
| shallow, commit present but its walk hits the `.git/shallow` boundary | - | 2 (a "not an ancestor" there is the clone's ignorance) |
| any | the RUNNING binary reports it contains the target commit | **1** - no commit is its own ancestor |

The last row is why the running binary is a source of evidence and not only a thing being replaced: `wa --contains
<target>` answered by the bytes that are running settles the question with no checkout at all.

`deploy.sh` tries one bounded `git fetch --unshallow` (or `git fetch origin <commit>`) before refusing on a
missing commit (`wa_ancestry_fetch_missing`), and asks the verdict again after it.

A running binary that reports `dirty=true` refuses as `downgrade refused(dirty_running_binary)`: its bytes are a
commit PLUS uncommitted edits, no commit contains those, and the commit-level question cannot see them at all.
`dirty=unknown` from a binary that answered `--build-info` is refused as `refused(ancestry_unknown)`.

The override is `--force --reason <text>` and nothing else: a `--force` with no reason is refused at the parser,
before anything is resolved or built, and every force is written down - `force_requested reason= by= at=` plus the
rule it overrode (`ancestry_override=`, `ancestry_replaced=`, `ancestry_target=`, `ancestry_by=`,
`overrode=`) in `deploy.log` and in `installed.txt`.

## 4. Only a shared commit may be published

`scripts/lib/shared-commit.sh` is the one answer to "is this commit on a branch anybody else can see?", and it
asks the INCOMING repository (`git ls-remote`) rather than this clone: a local `refs/remotes/*` ref is a memory of
a fetch, and it can name a branch the remote has deleted. It answers shared (0), not shared (1) or cannot tell (2).

It is used by `scripts/publish-node-binaries.sh` (refuses `commit_not_on_pushed_branch` on 1 and on 2, and names
the local branches that do contain the commit), `scripts/publish-components.sh` (exit 7), `scripts/deploy.sh`
(before it builds, so a refusal leaves the node untouched; it then requires the same answer of the ship step),
`scripts/ship-wave.mjs` and `scripts/codemode-build.mjs` (which records `source_shared` in its receipt and only
writes a ready receipt for a shared commit), and `scripts/lib/fast-binary.sh` (which records it in the build
itself as `source_shared=` in `wa --build-info` rather than refusing to build an unlanded branch - this
repository lands a change after building it). A detached HEAD is not refused as such - a publisher with no
checkout works that way - but the commit it points at has to be on a branch the remote has.

The named, printed development override is `ALLOW_UNPUSHED_COMMIT=1`, and the manifest then records
`unpushed=yes`.

## 5. Going back is a record: pins

`lua/core/pins.lua` is the store (`<config>/pins.txt`, append-only key=value blocks). A pin is a node (by name
AND by `node_id`: a pin written under one is found by the other), the commit it is held at (or the sha256 of
bytes that cannot name one), a reason, who, when, an optional `until` (a date that passes is reported OVERDUE)
and an optional `await` (the commit whose landing releases it).

```
wa update <node> --rollback [--reason <text>]   put back the pair the last install replaced, and pin it there
wa update <node> --to <sha> [--reason <text>]   move it to that commit on purpose, and pin it there
wa update <node> --pin [--commit <sha>] [--bytes <sha256>] [--reason <text>] [--until <text>] [--await <sha>]
wa update <node> --unpin --reason <text>        release it; the clear is a record, not a deletion
```

A pin gates the coordinator's deploys of that node: a deploy is refused `node_pinned`, quoting the pin and naming
the ways out.

A ROLLBACK PIN NAMES THE COMMIT IT WENT BACK FROM (`rolled_back_from=`) and defaults its `await` to it, because a
pin whose awaited fix lands in a DESCENDANT could otherwise never release: "released" used to mean target == await
exactly, and a plain deploy of main never matched, so the only way out was `--unpin` by hand. A pin now releases
in three ways - the target IS the pinned commit, the target IS the awaited commit, or the target CONTAINS the
awaited commit (asked of git in the coordinator's tree; "cannot tell" never releases). The release is written as a
record (`kind=released`), so the ledger says when and why a node was let go.

A pin is also kept ON THE NODE IT HOLDS. A coordinator's store protects a node from requests made through that
coordinator and from nothing else: an install started on the node - its sentinel's tree deploy, a hand-run
`upgrade.sh`, `fleet-install.sh` or `linux/bootstrap.sh` - reads nothing there. So a rollback writes the same
pin into the node's own `pins.txt` (refreshed with the restored commit when the outcome is read), and
`scripts/lib/node-pins.sh` is what those three scripts read; each refuses `node_pinned` unless
`--force --reason <text>` (or `WA_UPGRADE_FORCE_REASON` for `upgrade.sh`), which is recorded.

What protects a node from going backwards when nobody asked either path is rule 3, which lives where the install
happens. The two are complementary and neither replaces the other.

## Tests

`scripts/test-build-info.sh` (the binary's identity, `source_shared`, `ancestors_complete` and every
`--contains` verdict), `scripts/test-install-record.sh` (the writer, the shallow/full/absent-commit verdicts, and
a real rollback through it), `scripts/test-deploy-ancestry.sh` (refusal with the commit list, the 18/11 case, the
shallow case, the dirty running binary, `--force` without a reason, every force recorded),
`scripts/test-install-guards.sh` (the fleet path end to end: record-vs-bytes, dirty, unknown, a recorded
`--force`; and no installer runs a command inside its own message), `scripts/test-publish-shared-commit.sh`,
`scripts/test-node-pins.sh`, `scripts/test-remote-update.lua`.
