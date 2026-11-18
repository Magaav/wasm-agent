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

Three answers, and "cannot tell" is never treated as "no": refusing on your own ignorance blocks a first
install. Unknown is recorded as `ancestry_unverified=yes`.

The override is `--force --reason <text>` and nothing else: the reason is required, and it lands in
`deploy.log` (`ancestry_override=`, `ancestry_replaced=`, `ancestry_by=`) and in `installed.txt`.

## 4. Only a shared commit may be published

`scripts/publish-node-binaries.sh` refuses a commit that is reachable from no pushed branch
(`commit_not_on_pushed_branch`), names the local branches that do contain it, and calls the incident by name. A
detached HEAD is not refused as such — a publisher with no checkout works that way — but the commit it points at
has to be on a pushed branch. The manifest records `pushed_branches=` and, for the named development override
`ALLOW_UNPUSHED_COMMIT=1`, `unpushed=yes`.

## 5. Going back is a record: pins

`lua/core/pins.lua` is the store (`<config>/pins.txt`, append-only key=value blocks). A pin is a node, the commit
it is held at (or the sha256 of bytes that cannot name one), a reason, who, when, an optional `until` (a date that
passes is reported OVERDUE) and an optional `await` (the commit whose landing releases it).

```
wa update <node> --rollback [--reason <text>]   put back the pair the last install replaced, and pin it there
wa update <node> --to <sha> [--reason <text>]   move it to that commit on purpose, and pin it there
wa update <node> --pin [--commit <sha>] [--bytes <sha256>] [--reason <text>] [--until <text>] [--await <sha>]
wa update <node> --unpin --reason <text>        release it; the clear is a record, not a deletion
```

A pin gates the coordinator's deploys of that node: a deploy is refused `node_pinned`, quoting the pin, unless the
target contains the awaited commit or `--force --reason` is given. The fleet view lists the pins and names the
overdue ones (`pins`, `pins_overdue`).

A pin is enforced where the DECISION is made: on the node that runs `wa update <node>`. What protects a node from
going backwards when nobody asked that coordinator is rule 3, which lives where the install happens. The two are
complementary and neither replaces the other.

## Tests

`scripts/test-build-info.sh` (the binary's identity and every `--contains` verdict),
`scripts/test-install-record.sh` (the writer, the fallbacks, and a real rollback through it),
`scripts/test-deploy-ancestry.sh` (refusal with the commit list, `--force` without a reason, `--force --reason`
recorded, the record as a fallback), `scripts/test-publish-shared-commit.sh`, `scripts/test-node-pins.sh`.
