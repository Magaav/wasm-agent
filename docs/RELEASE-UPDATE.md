# Release awareness: "this node is behind", and what `/update` does about it

A node that cannot tell whether it is current will be current only by its operator's memory. This is
the small, bounded piece that removes that: one request, one comparison, and a banner or a line that
names the release the node is behind.

It is modelled on Pi's version check (read from the installed `@earendil-works/pi-coding-agent`
1.3.0, `dist/utils/version-check.js` and `dist/modes/interactive/interactive-mode.js`), because that
implementation gets four things right that a hand-rolled check usually gets wrong:

| Pi does | here |
| --- | --- |
| one tiny JSON endpoint (`/api/latest-version`) | one GitHub endpoint: `GET /repos/Magaav/wasm-agent/releases?per_page=20`, newest **versioned, non-draft** tag on the node's channel (`stable` skips pre-releases; a node on a pre-release follows pre-releases; `WA_RELEASE_CHANNEL` overrides) |
| compares with `semver` and reports `1.0.0-beta` below `1.0.0` | `release.compare` implements prerelease precedence (numbers numeric, release above its prereleases) |
| checks on start without blocking, and swallows every error | one cached check on start / on load; a failure is silent and the state is `unknown` |
| "already up to date (vX)" when it is | `current` says so; `unknown` never says "up to date" |
| `PI_OFFLINE` / `PI_SKIP_VERSION_CHECK` | `WA_OFFLINE=1` / `WA_SKIP_UPDATE_CHECK=1` (and `WA_RELEASE_FEED=off`) |

## The states

`lua/core/release.lua` answers exactly one question, and `unknown` is a real answer:

| state | when | message |
| --- | --- | --- |
| `behind` | installed tag < published tag | `installed v0.1.0-alpha.11 is behind the latest release v0.2.0` |
| `current` | installed tag >= published tag | `installed v0.2.0 is the latest release` |
| `unknown` | feed unreachable / unparseable, or no recorded release | `cannot tell whether this node is behind: <reason>` |

The reasons are named (`feed_unreachable`, `feed_status_404`, `feed_invalid`, `checks_disabled`,
`not_checked`, `no_recorded_release`, `uncomparable_versions`). A node whose check failed must not
read as "up to date" - that is the silent success this module exists to prevent.

## The commit banner: `Update available (<short sha>): run wa update or /update`

`lua/core/update_banner.lua` is the Claude Code/pi-shaped indicator the tags above cannot give a tree
install: it compares the **installed commit** (`installed.txt` `commit=`, plus `binary_source=` and
`binary_release=` when the binary came from a published release) with the newest `node-<sha12>`
release of this repository - the per-commit binaries `scripts/lib/node-binaries.sh` publishes and the
deploy downloads (owner/repo resolved by `wa_node_release_repo`'s rule, `WA_NODE_RELEASE_REPO` first).

| state | when | what is drawn |
| --- | --- | --- |
| `behind` | the installed release is in the published window but not first, a prebuilt install's release fell out of it, or local git proves the release commit descends from the installed one | `Update available (<latest sha12>): run wa update or /update` on the CLI's **session-status-content** line (yellow, directly above the session status bar), once at session start, and as a dismissible toast + topbar badge + standing footer line in the window |
| `current` | installed == newest release | nothing; an existing badge/toast is cleared on the next load |
| `ahead` | local git proves the installed commit descends from the release | nothing - a tree ahead of the feed is not told to update |
| `unknown` | no recorded commit, no feed, or a tree commit the feed does not mention and local ancestry cannot order | nothing (the reason is in the cache and the JSON) |

The check **never fetches and never merges**. Local git answers one question only (`merge-base
--is-ancestor`, on objects already on disk); the release feed is the only network fact.

Caching: `<state>/update-check.json` (`host.paths().config`, i.e. `~/.wasm-agent`) holds the feed and
when it was last asked for - **not** the verdict, which is recomputed on every read from the cached
feed and the *current* install record. So the indicator disappears the moment the node runs the
release, without waiting for a request. The window is claimed (written) before the request, so fifteen
minutes is at most one call even across a failure, a crash or three processes; a failed refresh keeps
the last good feed, so a known update survives transient outages. `POST /update {"check": true}` now
also returns `banner` (cache only - a page load never costs a request). The served node refreshes the
cache on its quiet housekeeping tick (`wa_sync_tick`, which only runs in a real node); the CLI asks at
session start. A bus fact `kernel.update.available` is published per completed refresh when the host
exposes a bus to Lua (today it does not - docs/BUS.md - so the cache is the whole surface).

Knobs: `WA_UPDATE_CHECK=off`, the existing `WA_OFFLINE=1` / `WA_SKIP_UPDATE_CHECK=1`, a feed override
`WA_UPDATE_CHECK_FEED=<url>|off`, `WA_UPDATE_CHECK_FIXTURE=<file>` (no network), `WA_UPDATE_CHECK_CACHE=<file>`
and `WA_UPDATE_CHECK_TRANSPORT=gh|curl|http` (default: `host.http`, then `gh`, then `curl`) and `WA_UPDATE_CHECK_PER_PAGE=<n>` (the published window, default 5).

## session-status-content: the line the notice lives on (07/11)

One line directly **above** the session status bar is reserved for transient session notices, in
both surfaces. It exists because the notice used to be drawn *inside* the status bar's own row: on
the CLI footer it competed with the session numbers and pushed them right, and on the window it had
no row at all. Now:

- **empty takes no line.** With nothing to show the row returns to the chat (the output region ends
  on the status row's edge) and the window removes the element - there is never a blank gap.
- **the sentence is unchanged**, and yellow (`cli_view`'s `warning` role, #ffc107; the stylesheet's
  `--warn` in the window), one row, clipped with an ellipsis and never wrapped at any width.
- **a rebuild replaces it.** While `build-status.json` says `building`, the `⟳ building wasm-agent ...`
  loader is that line (with the progress bar in the Rust renderer) and the notice disappears; a
  finished build shows `✓ wasm-agent rebuilt ...` for a moment, a failed one shows
  `✗ wasm-agent build failed ...` for `FAILED_FOR` (60s) and then the notice is back - a failed build
  leaves the update available, so the notice is never the thing that is lost. `BUILDING_FOR` (120s),
  `INSTALLED_FOR` (30s) and `FAILED_FOR` are `lua/core/update_banner.lua`'s and
  `rust/wa-term/src/build_status.rs`'s, and the tests pin them against each other.

The precedence is `update_banner.session_content({notice, build, now})` - one function, so the CLI
cannot disagree with itself. The renderers are three, and the tests pin all three: the Lua view's
framed screen (`lua/core/cli_view.lua` `session_draw`, `region_bottom`; plain text in a captured
transcript), the native editor's row (`wa_term::terminal_editor::Editor::session_row`,
`session_content` - the editor owns the row whenever it owns the screen, because it also reserves it
out of the output region), and the window's footer (`ui/app.js` `paintSessionNotice`, above
`.composer-footer`).

One integration point is still pending and is the host's, not a renderer's: the native editor draws
the **loader** today (from `build-status.json`) but has no source for the *notice* text, so the CLI
draws that one itself through the host's `{S}` status-row token. Wiring it exactly is one call from
`rust/wa-capabilities/src/host.rs` next to `editor_footer` (`editor.session_notice = text` plus the
`layout_frame` redraw `refresh_build` already does); until then the line is correct, the region is
reserved by this module rather than by the editor, and the transcript may repaint it until the next
frame.

## The installed side: `release=` in `installed.txt`

The comparison is on tags, so the install has to name one. `scripts/deploy.sh` writes
`release=<tag>` when the commit it installed is exactly a tag (`git describe --tags --exact-match`);
`/update` goes through that deploy, so the ordinary path stamps every node from now on.

An install from before this change carries a commit and no tag, and answers `unknown`
(`no_recorded_release`) until its next deploy. That is deliberate: resolving a tag back to a commit
would cost a second and third request, and a guess is worse than a named gap. `scripts/upgrade.sh`
still writes an interim record with no tag - the deploy owns the final record.

## Where it surfaces

- **CLI**, on start: one line, only when actually behind. The commit banner prints
  `Update available (<latest sha12>): run wa update or /update` and puts the same sentence on the
  session-status-content line above the status bar (see above); when the commit feed cannot decide,
  the tag line above is the fallback -
  `update available: installed v0.1.0-alpha.11 is behind the latest release v0.2.0 - /update installs it`.
  Silent for `current`, `ahead` and `unknown`, and never inside the transcript.
- **CLI**, `/update`: the deploy verdict, then `release: ...` when behind.
- **Window**, on load: a dismissible toast and a topbar badge with the node's sentence, drawn once
  after the first paint from `POST /update {"check": true}` (`banner`) - and the same sentence on the
  session-status-content line directly above the composer footer, in yellow, for as long as the node
  is behind (the toast can be dismissed; the line is the standing state). Not a transcript row.
- **Window**, `/update`: the same sentence in its notice.

`POST /update {"check": true}` is **read-only**: it never synchronizes the tree, never takes a backup
and never writes a sentinel request. A window reload cannot install anything. `fresh: true` bypasses
the tag cache; the commit banner in the same answer is always cache-only.

## Caching, and the one risk

A check is cached for ten minutes in `<config>/release-cache.json`, so a reload is not a request. The
cache is re-validated on the way out: a hand-edited or half-written file answers `unknown` rather than
a version nobody published.

The risk this names: the check runs on the interpreter thread, and this repository has already
measured what a network call in a request path costs (`lua/core/model_window.lua` blocked `/models`
for 4.7 MB and the node looked wedged while `/health` kept answering). The mitigation is the cache
plus a route that is only asked on load and on `/update` - **not** a `/version` poll, which runs every
second. If a future editor moves this onto a hot route, that measurement is the reason not to.

## One command, both kinds of node

`/update` (chat and window) and `wa update` / `wa --update` (shell) are the same request:

- **tree install** (`runtime-worktree.txt` names a checkout): fast-forward the tree to `origin/main`, then
  queue a Sentinel deploy, which builds, proves on a scratch port, installs and restarts once idle;
- **release install** (`installed.txt` says `via=linux-bootstrap`, no tree): refresh the bootstrap clone,
  run `scripts/linux/bootstrap.sh --check` (which bundle, verified, current or not), then run the
  bootstrap for real in a transient `systemd-run --user` unit - it stops `wa-sentinel.service`, so it must
  not be a child of the node it replaces. Its log is `<config>/release-update.log`.

`wa update --check` only asks the release feed whether a newer release is published.

## What this does not do

- **Channels are two, and inferred.** `stable` follows releases; a node that runs a pre-release follows
pre-releases (every Linux/desktop version published so far is an alpha, so skipping them made every node
answer `unknown`). `WA_RELEASE_CHANNEL=stable|prerelease` overrides. Android bundles are published as releases of
their own (`wa-android-<commit>`, see `releases/index.json`), so they are filtered out by exactly that
rule - `/releases/latest` would have handed a desktop node a commit name and the check would have
answered `unknown` forever.
- **It is not a security boundary.** The feed is GitHub over HTTPS and its body is only rendered as
  text; nothing is installed from it, so a forged body can annoy a reader but cannot place a byte.

## Tests

`scripts/test-release.lua` - 68 checks, no network: precedence (`alpha.12` below `0.1.0`, numeric
prerelease identifiers, build metadata ignored), the published body, every verdict, the installed
record, the cache hit/miss/stale/corrupt cases, offline and a missing fixture.

`scripts/test-update-banner.lua` - 174 checks, no network: the `node-<sha12>` tag parser, the commit
prefix rules, the identity a build and a prebuilt record produce, the release-list filter (version
tags, Android bundles and drafts skipped, no note text carried), every compare outcome
(older/equal/newer/unknown), the exact banner line, the fifteen-minute window (hit at `CACHE_MS - 1`,
request at `CACHE_MS`), the claim that makes a failed request cost one call not one per tick, offline
with and without a cache, the banner clearing when the installed record names the release and
returning when it does not, the bus fact's shape (no message text), the served-node memo, and the
default paths. The last third is **session-status-content**: the `building`/`installed`/`failed`
precedence and the notice coming back, the freshness windows pinned against
`rust/wa-term/src/build_status.rs` and the notice's yellow pinned to `#ffc107` on both sides, the
build-status file reader (a fixture, a broken file, a missing one) - and the view itself, driven with
its screen set: no notice takes no row, the notice is drawn yellow on the row above the status bar
while the bar keeps its own content, a build replaces it on the same row, a failure hands it back,
and 40 columns is 40 columns with an ellipsis. `tests/update-banner.js` - 68 checks in the gate's
`js:` set: reads the real `ui/app.js` functions and runs them against a stub DOM (toast + badge
drawn, dismiss keeps the badge, badge acts, current clears all three), the session-status-content line
above `.composer-footer` in the stylesheet's yellow, removed when there is nothing to say and
ellipsised rather than wrapped, and pins the one sentence across `lua/core/update_banner.lua`,
`app.js` and the CLI. `rust/wa-term`: `cargo test -p wa-term` covers the same layout rule on the
native editor's side (`session_row`, `session_content`, 55 tests). Run them the way the gate does:

```sh
WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=$(mktemp -d) WA_SCRIPT=scripts/test-release.lua wa --db "$WASM_AGENT_HOME/t.db"
WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=$(mktemp -d) WA_SCRIPT=scripts/test-update-banner.lua wa --db "$WASM_AGENT_HOME/t.db"
node tests/update-banner.js
(cd rust && cargo test -p wa-term)
```
