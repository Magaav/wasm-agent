# Release awareness: "this node is behind", and what `/update` does about it

A node that cannot tell whether it is current will be current only by its operator's memory. This is
the small, bounded piece that removes that: one request, one comparison, and a banner or a line that
names the release the node is behind.

It is modelled on Pi's version check (read from the installed `@earendil-works/pi-coding-agent`
1.3.0, `dist/utils/version-check.js` and `dist/modes/interactive/interactive-mode.js`), because that
implementation gets four things right that a hand-rolled check usually gets wrong:

| Pi does | here |
| --- | --- |
| one tiny JSON endpoint (`/api/latest-version`) | one GitHub endpoint: `GET /repos/Magaav/wasm-agent/releases/latest` |
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

## The installed side: `release=` in `installed.txt`

The comparison is on tags, so the install has to name one. `scripts/deploy.sh` writes
`release=<tag>` when the commit it installed is exactly a tag (`git describe --tags --exact-match`);
`/update` goes through that deploy, so the ordinary path stamps every node from now on.

An install from before this change carries a commit and no tag, and answers `unknown`
(`no_recorded_release`) until its next deploy. That is deliberate: resolving a tag back to a commit
would cost a second and third request, and a guess is worse than a named gap. `scripts/upgrade.sh`
still writes an interim record with no tag - the deploy owns the final record.

## Where it surfaces

- **CLI**, on start: one line, only when actually behind -
  `update available: installed v0.1.0-alpha.11 is behind the latest release v0.2.0 - /update installs it`.
  Silent for `current` and `unknown`.
- **CLI**, `/update`: the deploy verdict, then `release: ...` when behind.
- **Window**, on load: a banner - `Update Available - <message>. Run /update to install it` - drawn
  once, after the first paint, from `POST /update {"check": true}`.
- **Window**, `/update`: the same sentence in its notice.

`POST /update {"check": true}` is **read-only**: it never synchronizes the tree, never takes a backup
and never writes a sentinel request. A window reload cannot install anything. `fresh: true` bypasses
the cache.

## Caching, and the one risk

A check is cached for ten minutes in `<config>/release-cache.json`, so a reload is not a request. The
cache is re-validated on the way out: a hand-edited or half-written file answers `unknown` rather than
a version nobody published.

The risk this names: the check runs on the interpreter thread, and this repository has already
measured what a network call in a request path costs (`lua/core/model_window.lua` blocked `/models`
for 4.7 MB and the node looked wedged while `/health` kept answering). The mitigation is the cache
plus a route that is only asked on load and on `/update` - **not** a `/version` poll, which runs every
second. If a future editor moves this onto a hot route, that measurement is the reason not to.

## What this does not do

- **It does not download or install a release.** `/update` still queues a *deploy of this node's own
  tree* through the sentinel; a node with no tree (installed from a package, no checkout) has nothing
  for that path to build. `scripts/release/install.ps1` is a fresh installer and refuses to overwrite
  an existing install ("use the external upgrade procedure"), and that procedure takes a binary, not a
  published package. Closing this needs a release artifact + a sentinel verb that fetches, verifies
  and installs it - `docs/release/RELEASE_INDEX.md` calls the publisher side a manual step today.
- **It does not pick a channel.** There is no stable/beta split; whichever release GitHub marks latest
  is the answer. `prerelease` is carried in the parsed release and unused.
- **It is not a security boundary.** The feed is GitHub over HTTPS and its body is only rendered as
  text; nothing is installed from it, so a forged body can annoy a reader but cannot place a byte.

## Tests

`scripts/test-release.lua` - 55 checks, no network: precedence (`alpha.12` below `0.1.0`, numeric
prerelease identifiers, build metadata ignored), the published body, every verdict, the installed
record, the cache hit/miss/stale/corrupt cases, offline and a missing fixture. Run it the way the
gate does:

```sh
WASM_AGENT_LUA_ROOT=$PWD WASM_AGENT_HOME=$(mktemp -d) WA_SCRIPT=scripts/test-release.lua wa --db "$WASM_AGENT_HOME/t.db"
```
