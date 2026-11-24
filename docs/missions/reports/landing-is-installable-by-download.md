# landing-is-installable-by-download (24/11)

Branch `change/landing-is-installable-by-download` from `origin/main` 345e51be. Five commits, one per item.

| commit | item |
| --- | --- |
| 9722cad0 | 5 - the harness: `scripts/test-installable-by-download.sh` (the cut condition), and its row in `scripts/test.sh` |
| 55e5f652 | 4 - the `wa-remap-rustc` "Permission denied" class, and the at-once refusal of a node that cannot build |
| 8a5717a7 | 2 - publish completeness: `scripts/lib/release-completeness.sh` + `scripts/check-release-complete.sh` |
| d3a5bd9c | 1 - the landing also publishes the components bundle, OFF behind `WA_PUBLISH_COMPONENTS=1` |
| 69a309e0 | 3 - the deploy's first lines and `wa update --check` say it before anything is touched |

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

## Item 5 - the row that was missing (9722cad0)

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

## Item 1 - the landing publishes the components bundle too, OFF (d3a5bd9c)

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

## Item 2 - publish completeness (8a5717a7)

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

## Item 3 - say it before anything is touched (69a309e0)

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

## Addition (24ddc690) - the release list line: what the five were, and newest by publish time

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

## Item 4 - `wa-remap-rustc` Permission denied on work (55e5f652)

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

## Pre-existing failures, named (measured on a separate worktree of 345e51be)

* `scripts/test-node-binaries.sh` - FAILS identically on the base commit: its fixture expects `not_on_main:`
  while `scripts/lib/build-target.sh` is absent from the fixture tree, so the publisher refuses earlier with
  `commit_not_on_pushed_branch`. Not this branch's.
* `scripts/test-update-treeless.lua` - 8 of 10 rows fail on the base commit too (run with the node's own
  binary in a scratch home): the fixture's pinned commits are not in this checkout's history. Not this
  branch's.

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

## What this branch did NOT do

* Nothing was published. The bundle that made row 5 green at 21:36Z was published by the operator, not here.
* The orchestrator's `_orch/publish-landing3.sh` is untouched; the block above is a proposal.
* `WA_PUBLISH_COMPONENTS` is OFF: turning it on is Victor's word.
* `scripts/verify-install.sh` was not run green on a scratch install (it needs a live node; see item 5).
* `scripts/test-discriminates.sh` was not run from here; the land gate runs it.
