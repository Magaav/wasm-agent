# landing-is-installable-by-download (24/11)

Branch `change/landing-is-installable-by-download`, rebased onto `origin/main` 65e3daef. Five commits, one
per item, plus a report commit, a probe fix, the release-list addition and a rebase commit (de476ed8). The
hashes below are the ones on the branch AFTER that rebase (`git log 65e3daef..HEAD`); the hashes quoted
inside a measured output block are kept verbatim, because they are what the run printed.

| commit | item |
| --- | --- |
| 251356c1 | 5 - the harness: `scripts/test-installable-by-download.sh` (the cut condition), and its row in `scripts/test.sh` |
| 64fcb703 | 4 - the `wa-remap-rustc` "Permission denied" class, and the at-once refusal of a node that cannot build |
| 00e4f54d | 2 - publish completeness: `scripts/lib/release-completeness.sh` + `scripts/check-release-complete.sh` |
| 13aadad3 | 1 - the landing also publishes the components bundle, OFF behind `WA_PUBLISH_COMPONENTS=1` |
| 4330f01d | 3 - the deploy's first lines and `wa update --check` say it before anything is touched |
| e8e308d4 | the harness asks the channel the way a node does (gh first), so a rate-limited API is not a skip |
| 8a5e1104 | the release list: newest by publish time, a stated bound, and what the five were |
| de476ed8 | rebase onto 65e3daef: a covering release is a legitimate answer, and the deploy's second turn refusal |
| df24d6f4 | the landing COMPLETES an existing components release, never replaces an asset (no `--clobber`) |
| 4f496eee | the components question runs to a stated 10 s bound; a request cut by the bound is never a 200 |
| 5be6aa95 | test-deploy-components-shipped green on main: three stale expectations, none loosened |

## What was measured, before and after

**The download path completed end to end for the first time.** `bash scripts/test-installable-by-download.sh
39e862d60bad3e2887882e5c37878a09285eb929` on avell, scratch HOME, no cargo/rustup/rustc/zig on PATH, empty
component/binary/bundle caches, 21:50Z:

```
  binary_verified: x86_64-unknown-linux-gnu .../node-binaries/39e862d60bad/x86_64-unknown-linux-gnu 39e862d60bad
  the published binary runs and names commit=39e862d60bad3e2887882e5c37878a09285eb929
  components staged from components-df6f97708c72: 11 name(s) verified against the lock at 39e862d60bad
  installed 11 component(s) ... every byte the pinned one
  the published binary answers through the installed memory component (check-component-proof.lua)
  no toolchain was fetched (RUSTUP_HOME and CARGO_HOME ... stayed absent)
installable by download: 39e862d60bad (node-39e862d60bad, components-df6f97708c72, 11 components) on x86_64-unknown-linux-gnu
```

The same command was the RED the brief asked for, measured twice before that:

* 21:19Z, `origin/main` 39e862d60bad: `39e862d60bad is NOT installable by download: node-39e862d60bad
  (x86_64-unknown-linux-gnu) missing` (no published binary for main's HEAD at that moment, and no release
  whose `compiled_inputs` digest covered it - the digest search scanned 17 releases and hit its 20 s bound).
* 21:26Z, 9a0c589adfa0 (the commit work's update actually used): the binary downloaded, verified, ran and named
  its commit; then `component_release_unreachable: .../components-df6f97708c72/agent-core.wasm`, the fallback
  build found no toolchain, and the verdict was
  `9a0c589adfa0 is NOT installable by download: components-df6f97708c72/agent-core.wasm missing`.

Between 21:19Z and 21:50Z the operator published `node-39e862d60bad` (21:25Z) and `components-df6f97708c72`
(21:36Z); the green above is that same commit with those assets in place. Nothing in this branch published
anything.

## Item 5 - the row that was missing (251356c1)

`scripts/test-installable-by-download.sh [<40-hex commit>]` runs the node's own path, not a description of it:
`wa_node_binaries_prepare` (exact tag, else the newest release whose compiled inputs cover the commit - the
same resolver a deploy uses), `wa_components_prepare` + `wa_components_install_set` for every name
`components.lock` pins (from `components-<sha12 of the lock>`), then the deploy's own pair proof
(`scripts/check-component-proof.lua` with the downloaded binary and the installed components). It removes
every PATH entry carrying cargo/rustup/rustc/zig and refuses by name if one survives, points RUSTUP_HOME and
CARGO_HOME into the scratch root, starts from empty caches, and fails if a toolchain appeared. Scratch home
through `scripts/lib/scratch-home.sh`.

Where it is wired: `scripts/test.sh`, opt-in (`WA_INSTALLABLE_BY_DOWNLOAD=1`), with a named SKIP otherwise and
the reason - a published-asset row cannot be a gate row, because until the assets are published it is red by
design. It is the cut condition the orchestrator runs on the release commit before the fleet step.

What it does NOT prove: `scripts/verify-install.sh` is not run. That verifier checks what a live install has
(served pid, sentinel watching, `/health`) and would fail on a scratch install with no node, so the pair is
proven by the proof a deploy runs on a candidate instead, and this report says so rather than calling it
"verify-install green".

## Item 1 - the landing publishes the components bundle too, OFF (13aadad3)

`scripts/lib/landing-components-publish.sh` (new) holds `components_step` and `publish_report`, sourced by
`scripts/publish-node-binaries.sh` from BESIDE THE SCRIPT (a copy of the publisher in a fixture keeps working;
without the libs a `--publish` run refuses by name). `components_step` runs after the node release and on the
`--ensure` **covered** exit - a landing that only moves the lock publishes no binary at all and is exactly the
landing whose nodes could not update. OFF unless `WA_PUBLISH_COMPONENTS=1`; when on it publishes
`components-<sha12 of the lock>` from `WA_COMPONENTS_BUNDLE=<dir>` (or builds), after the real
`scripts/publish-components.sh` has verified every artifact against the lock, with `--latest=false`, uploading
over an existing tag.

`scripts/test-publish-components-at-landing.sh`: 20 rows, 0 failed. gh is a recording shim (an external
service); every byte check is the real publisher's.

## Item 2 - publish completeness (00e4f54d)

`bash scripts/check-release-complete.sh [<commit>] [--json] [--components] [--manifest-dir DIR] [--repo DIR]`
asks, by HEAD (and a one-byte range GET where HEAD is refused): `node-<sha12>.manifest`, `SHA256SUMS`,
`SHA256SUMS.sig`, both binaries for every triple the manifest publishes, then `<name>.wasm`, `<name>.json`
and `components.lock` for the bundle **that commit's** lock names (read with `git show <commit>:components.lock`,
never the publisher's checkout). Exit 0 complete, 1 not installable by download, 2 unknown - and unknown is
never reported as complete.

Measured against the real channel, 21:31Z, read-only:

```
9a0c589adfa0 is NOT installable by download: components-df6f97708c72/agent-core.wasm missing
39e862d60bad is NOT installable by download: components-df6f97708c72/agent-core.wasm missing
```

`scripts/test-release-completeness.sh`: 23 rows, 0 failed, against a local HTTP stand-in of the channel
(complete; the 24/11 shape; a missing signature; a missing manifest; a channel that does not answer -> unknown;
the bundle named is the COMMIT's, while a complete tag for the working tree's lock exists and must not be
used; and `--components` rows).

### Proposed lines for the orchestrator's `_orch/publish-landing3.sh` (proposed, NOT edited)

After the `row published` / `row covered` line, add a completeness question and record its verdict as a row.
The function `row()` already there takes one `release` string, so a miss is one more row with the asset in it:

```bash
# a2 (24/11): is the landing INSTALLABLE BY DOWNLOAD? Publishing covers the node binary; a node also needs
# the components bundle its lock names. Every URL the release and the lock name is asked by HEAD (~30
# requests, seconds). A miss is a row, not a gate: the landing already happened.
comp=$(bash "$C/scripts/check-release-complete.sh" "$S" 2>&1 | tail -1); crc=$?
case $crc in
  0) row "installable-by-download" ;;
  *) row "$(printf '%s' "$comp" | sed -e 's/^[0-9a-f]\{12\} is //' -e 's/ /_/g')" ;;
esac
echo "  $comp" >> "$H"
```

...which writes, in `$M/_quick/releases.jsonl`, one more row per landed sha - for the 24/11 shape:

```json
{"sha":"<40 hex>","at":"2026-11-24T21:31:07Z","release":"NOT_installable_by_download:_components-df6f97708c72/agent-core.wasm_missing","seconds":0}
```

and in `HANDOVER.md` the sentence itself: `<sha12> is NOT installable by download: <asset> missing`. If a
machine-readable row is preferred over the existing `row()` shape, `--json` prints
`{"sha":...,"at":...,"installable":"no","missing":"components-x/agent-core.wasm","verdict":"..."}` and the
orchestrator can append that line verbatim.

## Item 3 - say it before anything is touched (4330f01d)

`wa_components_preflight` (scripts/lib/deploy-components.sh) answers, in order: local bytes (installed and
matching, or a cache entry for this lock - no network), then the channel, then "can this node build one".
`scripts/deploy.sh` runs it right after the tree is known (before hooks, the landing checks, the
runtime-binding preflight, the clean/main/ancestry gates, the binary decision and the build).

Measured on avell, scratch worktree + scratch install dir, channel answering 404, no toolchain on PATH - the
deploy's **second line**:

```
deploy: refused(component_not_installable): this commit needs components-d8074432f14d, which is not published;
this node cannot build it (cargo rustup missing on PATH), and agent-core codemode graph hooks memory mesh
model-gateway selfloop telemetry-sink wa-email wa-whatsapp are not installed or cached here. The components
are the other half of this install, so nothing was fetched, built or installed. ...
```

and never a `binary_source`, `deploy: building` or `deploy: compiled` line.

`wa update --check` (lua/core/update.lua, `M.check`) asks the same question for a tree that is behind
(`scripts/check-release-complete.sh <origin/main> --components`, one request) and answers with
`components_release`, `components_state`, `can_build_components` and `installable_by_download`
(`true` | `false` | `"by_a_build"` | `"unknown"`), appending the sentence to its message. A tree without the
script, or a question that cannot be answered, is `unknown` - never "fine". Every field that was there
before is unchanged.

## Addition (8a5e1104) - the release list line: what the five were, and newest by publish time

Fable, from the node's own output on 39e862d6: the check printed a five-entry release list whose "newest"
was `node-d2fbd140934e` while node-9a0c589adfa0 and node-525780e13623 were newer. Measured on this node's
cache (`~/.wasm-agent/update-check.json`, written 21:30Z), in the order it stored them:

| stored order | tag | published |
| --- | --- | --- |
| 1 | node-d2fbd140934e | 2026-11-24T16:42:32Z |
| 2 | node-9a0c589adfa0 | 2026-11-24T17:20:43Z |
| 3 | node-8844132aa843 | 2026-11-24T16:16:32Z |
| 4 | node-5bb28d8a1f51 | 2026-11-24T15:50:15Z |
| 5 | node-525780e13623 | 2026-11-24T17:08:58Z |

Three answers to Fable's question: the cap was `M.DEFAULT_PER_PAGE = 5` (the feed URL asked for five); the
order is GitHub's release-list order, which is by CREATION and not by `published_at` (sorted by neither);
and "newest" was `feed[1]`, the first entry as returned - the oldest published of the five - while
node-4615449f4f02 (16:50:51Z) was not in the window at all.

What changed: `by_published()` orders by `published_at` descending (an entry without a publish time sorts
last), applied by the parser AND by the cache reader, so `latest`, `newest_installable`, the verdict and the
line all agree; the bound is 20 and is stated; the line keeps its prefix and adds the order, the newest's
publish time and the bound:

```
release list: 5 entries, read 2026-11-24 21:30Z, newest node-9a0c589adfa0 (published 2026-11-24T17:20:43Z),
ordered by publish time, out of at most 20 asked for
```

...against the same cache, measured with this tree's lua and the node's binary (`wa update --check`), with
item 3's sentence still in the first line:

```
installed 9a0c589adfa0... is 70 commit(s) behind origin/main 65e3daefd089; `wa update` installs it.
components-df6f97708c72 is published; a node can install this commit by download.
release list: 5 entries, read 2026-11-24 21:30Z, newest node-9a0c589adfa0 (published 2026-11-24T17:20:43Z), ordered by publish time, out of at most 20 asked for
```

Row: `scripts/test-update-banner.lua`, 249 checks, 0 failed - a stub of twelve entries with the tags in name
order and publish times shuffled (index 4 = 11:00Z newest, index 10 = 00:00Z oldest, the alphabetically last
at 05:00Z), so position, tag order and the last entry all name the wrong release. Two existing rows moved
with the bound (`per_page` and the feed URL now expect 20 where they expected 5, with the reason in place);
no assertion was loosened.

New string to approve (9): `release list: <n> entries, read <when>, newest <tag> (published <when>),
ordered by publish time, out of at most <bound> asked for[ (so anything older than the oldest entry here is
not in it)]`.

## Item 4 - `wa-remap-rustc` Permission denied on work (64fcb703)

The old install trusted two things it had not measured: that a file it found at the wrapper's path was
executable (`-f` was the whole test) and that the directory it chose would allow executing anything at all.
The path is fixed and guessable by design (`${TMPDIR:-/tmp}/wa-remap-rustc/<hash of the wrapper sources>`), so
both of these produce exactly `could not execute process wa-remap-rustc ... Permission denied (os error 13)`:

1. a wrapper left there by an earlier run without its execute bit - never repaired, because the file existed; and
2. a directory this process may not execute files from: a `noexec` /tmp, a directory another user owns (a
   shared /tmp where another run created the content-addressed path first), or one that is group/world writable.

`scripts/lib/component-remap-wrapper.sh` (new, sourced by `scripts/build-components.sh`) now writes and
**executes** a probe in the directory it is about to use - the only test that answers about the mount and the
mode together - repairs a wrapper without its execute bit and says so, refuses a symlink / not-owned /
group-or-world-writable directory BY NAME, falls back from an unusable TMPDIR to `$HOME/.cache/wa-remap-rustc`
printing which candidate it refused and why, and answers `wa_remap_wrapper_unusable` when no candidate works.
An explicit `WA_REMAP_DIR` is never silently replaced. stdout carries the directory and nothing else (a
reason on stdout used to become part of a PATH entry). The directory is not a build input (docs/COMPONENTS.md,
measured 24/11), so a fallback cannot move a pinned sha256.

The second half of the item: `wa_component_build_blockers` (deploy-components.sh) and the staging step now
refuse AT ONCE with `component_build_impossible: ...` when cargo/rustup are not on PATH, instead of starting a
build that fetches `rustc 1.99.1` for two minutes (that fetch is what most of work's 117 s was).

`scripts/test-component-build-wrapper.sh`: 29 rows, 0 failed - including a wrapper left at mode 644 repaired,
a read-only `WA_REMAP_DIR` refused with the directory left at 500, and a tripwire proving
`scripts/build-components.sh` is never started. The real build path still works: `WA_COMPONENTS_DIR=/tmp/ibd-components
bash scripts/build-components.sh svc-echo` built 191647 bytes with rustc 1.99.1 and printed
`component build wrapper: ... (reused; sources 778bbaafe2fe97a7)`.

**What I could NOT measure**: work's own cause. A `noexec` mount cannot be created here without root, and a
shared /tmp owned by another user cannot be simulated as this uid; the rows reach the same code path through
directories this process cannot write, and the refusal names the reason instead of dying inside cargo. Two
reads on work settle which of the two causes it was, and the fix covers both:

```
findmnt -no TARGET,OPTIONS /tmp
stat -c '%a %U %n' /tmp/wa-remap-rustc/*/ /tmp/wa-remap-rustc/*/wa-remap-rustc
```

## Rebase onto origin/main 65e3daef (de476ed8)

The preflight refused the landing with `land-quick: merge conflict with main 65e3daef in:
lua/core/update_banner.lua`. Main had moved the same file (f24f9ba6, the refresh + `M.covering` + the line
built from `o.read` / `o.refresh_failed`), so the last commit was rebased by hand keeping BOTH sides:

* main keeps its refresh first `read just now` / `refresh_failed` wording, its `M.REFRESH_SECONDS` and
  `M.HTTP_SECONDS`, and `M.covering`; the line is still built once into `line` and still starts with
  `release list: N entries, read <when>`;
* this branch adds, after that prefix, `newest <tag> (published <when>), ordered by publish time, out of at
  most <bound> asked for` (and the "anything older is not in it" clause when the page is full), and keeps
  `M.DEFAULT_PER_PAGE = 20` with `by_published` applied by the parser and the cache reader.

Two rows then went red for reasons main had introduced, and neither was weakened:

1. `scripts/test-installable-by-download.sh` refused a CORRECT release with `binary_commit_mismatch`:
   main's resolution installs an older release built from the same compiled inputs for a commit that
   changes none, so `wa_node_binaries_prepare` prints `binary_release: <tag> <40-hex source commit>`. The
   row now expects the binary to name the requested commit when the release is that commit's own build, and
   the covering release's source commit otherwise - and it CHECKS that the source commit is an ancestor of
   the requested one (`git merge-base --is-ancestor`), refusing `covering_release_not_an_ancestor`
   otherwise. Measured: the row is GREEN for main's own HEAD, with no commit argument:
   `installable by download: 65e3daefd089 (node-65e3daefd089, components-df6f97708c72, 11 components)` - the
   binary is node-39e862d60bad's build (an ancestor, same compiled inputs), 11 components verified against
   65e3daef's lock, the pair proved through the memory component, no toolchain fetched.
2. `scripts/test-components-preflight.sh` counted the deploy's SECOND turn-guard refusal as a failure: the
   guard refuses a turn on the node ("cannot deploy from a turn running on the node it would replace") and a
   CLI turn with no sentinel ("deploying from a CLI turn needs a sentinel supervising the node"). Which one
   fires depends on the process tree the test runs in. The row now skips BY NAME on either, quoting it, and
   every other output still has to be the preflight's own `refused(component_not_installable)` sentence.

Rows re-run after the rebase, all green: test-update-banner 249/0, test-check-listing (main's new row for
the same line) 10/0, test-update-release 16, test-update-all 43, test-update-follow.sh ok,
test-component-build-wrapper 29/0, test-release-completeness 23/0, test-publish-components-at-landing 20/0,
test-components-preflight 11/0 + 1 named SKIP, test-deploy-components 74, test-installable-by-download
green on 65e3daef.

## Three changes from the review (df24d6f4, 4f496eee, 5be6aa95)

**1 - complete, never replace (df24d6f4).** `gh release upload --clobber` is gone from
`scripts/lib/landing-components-publish.sh`. `components_step` no longer reads "the tag exists" as "the
bundle is complete" - which is exactly the 24/11 shape (the node binary published, the bundle made later, a
node refusing an asset nobody uploaded). It names the set the lock owes, asks every asset for its status
whether the tag exists or not, and then: complete -> "already holds every asset (N of N); nothing was
uploaded and nothing was replaced"; incomplete -> upload ONLY the assets that answered 404, saying which
("holds 2 of 3 assets; uploading only the missing: svc-alpha.json"); no tag -> create; a status that
cannot be read -> `components_publish_unanswerable` with the flag on (an upload there could replace an
asset nobody can see) or `installability is UNKNOWN, not assumed` with it off. The upload runs without
`--clobber`, so gh itself refuses to overwrite. Rows: 29 checks, 0 failed - the missing one uploaded and
named, the present ones not re-uploaded, no `--clobber` anywhere, a complete tag left alone, an unreadable
status refused.

**2 - a stated 10 s bound, and a cut request is never a 200 (4f496eee).** `wa_release_seconds()` in
`scripts/lib/release-completeness.sh` (WA_RELEASE_SECONDS, default 20) bounds every request that file makes;
`check-release-complete.sh --components` states 10 seconds (the same bound as the update refresh) and
`lua/core/update.lua` carries `CHECK_COMPONENTS_SECONDS = 10` plus a `timeout 15` guard around the call.
The row found a real defect on the way: `curl -s -o /dev/null -m N -w '%{http_code}'` prints the status it
read from the headers even when -m cuts the transfer, so a host that accepts a connection and sends nothing
looked like 200 - "published" about an asset nobody sent. Both status functions now ask curl's EXIT STATUS
first and answer `unknown (... the request did not complete: curl 28)`. Row: a stub that accepts and stalls
(`scripts/lib/http-stub.py`, `.stall` of 0 bytes) answers `components=unknown`, exit 2, elapsed 10 s - the
row fails if it answers sooner than 8 s or later than 20 s, so the bound is measured, not claimed.

**3 - the pre-existing red, fixed (5be6aa95).** `scripts/test-deploy-components-shipped.sh` had three
stale expectations, each hidden behind the one before it: `SHIPPED` listed ten components while the lock
pins eleven (wa-whatsapp has been pinned since 11/11); the row looked for `graph component ok` in
deploy.sh after the deploy moved its proof to the memory component (the graph is off by default) - it now
asserts three things about the current contract; and two `active:component` rows sat outside the
`$missing` guard whose SKIP said they were skipped, so a run with no artifacts asserted a component it
never installed. `publish-components.sh --check` is now called with the publisher's own named exception
(ALLOW_UNPUSHED_COMMIT=1 + reason), because pushability is a fact about the branch and that row is about
the plan. Measured: 56 checks, 0 failed, 2 named SKIPs without artifacts; 64 checks, 0 failed WITH the
real artifacts (all 25 components built here with rustc 1.99.1 and wasi-sdk 34), so the rows behind the
new guard really run.

## Pre-existing failures, named (measured on a separate worktree of 345e51be)

* `scripts/test-node-binaries.sh` - FAILS identically on the base commit: its fixture expects `not_on_main:`
  while `scripts/lib/build-target.sh` is absent from the fixture tree, so the publisher refuses earlier with
  `commit_not_on_pushed_branch`. Not this branch's.
* `scripts/test-update-treeless.lua` - 8 of 10 rows fail on the base commit too (run with the node's own
  binary in a scratch home): the fixture's pinned commits are not in this checkout's history. Not this
  branch's.
* `scripts/test-deploy-components-shipped.sh` - fails on origin/main 65e3daef itself (measured in a separate
  worktree of 65e3daef): `components.lock pins 'agent-core codemode graph hooks memory mesh
  model-gateway selfloop telemetry-sink wa-email wa-whatsapp', expected '... wa-email'` - the test's
  expected list is stale by one component (wa-whatsapp is pinned). Not this branch's, and not
  touched here: it belongs to whoever moved the lock.

## Texts to approve (new or changed operator/model-facing strings, verbatim)

1. `<sha12> is NOT installable by download: <asset> missing` - `scripts/lib/release-completeness.sh`,
   `scripts/test-installable-by-download.sh`.
2. `this commit needs components-<x>, which is not published; this node cannot build it (<tool> missing on
   PATH), and <names> are not installed or cached here` - deploy preflight.
3. `refused(component_not_installable): <that sentence>. The components are the other half of this install, so
   nothing was fetched, built or installed. Publish that bundle where its bytes were pinned (bash
   scripts/publish-components.sh, then the gh line it prints), install it from a directory
   (WA_DEPLOY_COMPONENT_SOURCE=<dir> ...), or give this node a toolchain (cargo and rustup) and let the deploy
   build them.` - scripts/deploy.sh.
4. `component_build_impossible: <name> has no pinned bytes here and this node cannot build it (<tools> missing
   from PATH), so the release <tag> is the only way to install it. ...` - deploy-components.sh.
5. `components=published|missing|unknown tag=<tag> buildable=yes|no note="<sentence>"` and
   `this commit needs <tag>, which is not published; this node can build it, so a deploy would spend a build` -
   `scripts/check-release-complete.sh --components`.
6. `components: <tag> is NOT published, so this landing is not installable by download on a node without a
   toolchain (the node binary above is). WA_PUBLISH_COMPONENTS=1 publishes the bundle from this landing - a
   components release is fleet-wide, so that is the operator's word to give` - landing-components-publish.sh.
7. `wa_remap_wrapper_not_executable: ...`, `wa_remap_dir_noexec: ...`, `wa_remap_dir_unwritable: ...`,
   `wa_remap_dir_not_owned: ...`, `wa_remap_dir_group_or_world_writable: ...`, `wa_remap_dir_is_a_symlink: ...`,
   `wa_remap_wrapper_unusable: ...` - component-remap-wrapper.sh.
8. `installable by download: <sha12> (node-<sha12>, <tag>, <n> components) on <triple>` (harness),
   `installable-by-download: <verdict>` (publisher report), and update.lua's fields
   `components_release`, `components_state`, `can_build_components`, `installable_by_download`.
9. `release list: <n> entries, read <when>, newest <tag> (published <when>), ordered by publish time, out
   of at most <bound> asked for` - see the Addition above.
10. `components: <tag> already holds every asset (<n> of <m>); nothing was uploaded and nothing was
    replaced` / `components: <tag> holds <n> of <m> assets; uploading only the missing:<assets>` /
    `components: <tag> exists but holds <n> of <m> assets (missing:<assets>); a node cannot install this
    commit by download until they are there. WA_PUBLISH_COMPONENTS=1 uploads only the missing ones -
    nothing already published is replaced` / `<tag> is at <url> (completed: added <assets>; no published
    asset was replaced)`.
11. `components_publish_unanswerable: <tag>/<asset> answered '<status>', so this run cannot tell whether it
    is published - uploading could replace an asset nobody can see; nothing was uploaded and nothing was
    replaced`.
12. `unknown (the request did not complete: curl <code>)` - a transfer cut by the bound is not an answer.

## What this branch did NOT do

* Nothing was published. The bundle that made row 5 green at 21:36Z was published by the operator, not here.
* The orchestrator's `_orch/publish-landing3.sh` is untouched; the block above is a proposal.
* `WA_PUBLISH_COMPONENTS` is OFF: turning it on is Victor's word.
* `scripts/verify-install.sh` was not run green on a scratch install (it needs a live node; see item 5).
* `scripts/test-discriminates.sh` was not run from here; the land gate runs it.
