# The published Android release index

`wa update` on a Termux node installs a **published release**. It does not compile this
workspace. That is the operator's decision, and it is grounded in a measurement rather than a
preference: on the operator's phone every rung of the on-device build ladder died inside
rustc with `(signal: 11, SIGSEGV)` while compiling `cranelift_codegen`, with the runtime's
own memory budget already reduced to one job at a time (the measurement is recorded in
`scripts/termux/release-lib.sh` and `scripts/termux/cross-build-android.sh`).

This file documents the channel: the index file, its schema, the trust chain behind one
entry, what the phone does with it, and what it refuses.

## The file

`releases/index.json`, committed on `main`, fetched by the phone as
`https://raw.githubusercontent.com/Magaav/wasm-agent/main/releases/index.json`.

- The repository is **public**, so no token is used and none is needed. A phone that needed a
  credential to read a release would be a phone that cannot update itself after the
  credential is lost.
- Any other URL can be named for a test with `--index URL` or
  `WA_TERMUX_RELEASE_INDEX_URL`; the default is the URL above.
- `file:` URLs are refused unless `WA_TERMUX_RELEASE_ALLOW_LOCAL=1` is set. That opt-in
  exists for the fixture suite, which serves real bundles from local files with no network;
  a published index must name an `https://` (or `http://`) asset.

## Schema

`schema_version` is **1**. An index this phone does not understand is refused by name
(`index_invalid`) rather than parsed optimistically.

```json
{
  "schema": "wasm-agent-release-index",
  "schema_version": 1,
  "doc": "docs/release/RELEASE_INDEX.md",
  "notes": "newest release first; one entry per published Android arm64 bundle",
  "trust_chain": [
    "1. this file is fetched over HTTPS from the public repository",
    "2. one entry pins one bundle by sha256(bundle.manifest)"
  ],
  "generated_utc": "2026-10-19T00:00:00Z",
  "releases": [
    {
      "commit": "0123456789abcdef0123456789abcdef01234567",
      "commit_short": "0123456789ab",
      "manifest_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "url": "https://github.com/Magaav/wasm-agent/releases/download/android-0123456789ab/wa-android-bundle-0123456789ab.tar.gz",
      "size": 30526112,
      "target": "aarch64-linux-android",
      "ndk": "27.3.13750724",
      "rustc": "1.98.1 (48a229cea 2026-09-01)",
      "built_utc": "2026-10-19T00:00:00Z"
    }
  ]
}
```

Fields, and what the phone checks about each one:

| field | format | checked |
| --- | --- | --- |
| `commit` | 40 lowercase hex (SHA-1) | is 40 hex; matches what the bundle records as `source_commit` |
| `commit_short` | 12 hex | is 12 hex, and is the first 12 characters of `commit` |
| `manifest_sha256` | 64 lowercase hex | **sha256 of the downloaded `bundle.manifest` must equal it** |
| `url` | `https://` or `http://` (or `file://` with the fixture opt-in only) | scheme; the asset is fetched from exactly this URL |
| `size` | decimal bytes | the downloaded asset must be exactly this size |
| `target` | `aarch64-linux-android` | must be the phone's triple; the bundle restates it and `rl_bundle_verify` re-checks it |
| `ndk` | free text, no tabs | recorded and shown; the bundle records `ndk_version` |
| `rustc` | free text, may contain spaces, no tabs | recorded and shown; the bundle records `rustc_version` |
| `built_utc` | ISO-8601 UTC | shown in `wa update --check` |

Top-level keys the parser accepts: `schema`, `schema_version`, `releases`, `doc`,
`trust_chain`, `notes`, `generated_utc`. Anything else is `index_invalid` — a typo must be a
refusal, not a silently ignored field.

**Entries are newest first.** `wa update` with no `--commit` installs the first entry.

**The file is line-oriented on purpose.** One `"key": value` pair per line, one entry per
`{ ... }` block. The phone has no JSON library and the channel must not add one: the parser is
`sed` plus `case` in `scripts/termux/release-lib.sh`, POSIX sh, no dependency. A published
index that has been reformatted by hand (several pairs on one line) is refused as
`index_invalid`; the format is the publisher's contract, not a suggestion.

### The bootstrap (empty) state

The committed index starts as exactly this, and it is valid:

```json
{
  "schema": "wasm-agent-release-index",
  "schema_version": 1,
  "trust_chain": ["..."],
  "releases": []
}
```

With no published release, `wa update` cannot name a revision from the channel. It falls back
to `git ls-remote` for the upstream's `HEAD` (or to `--commit`) and then takes the loud build
fallback described below. An empty index is a valid index, not an error; it is an index with
nothing in it.

## The asset

One `tar.gz` per release, named `wa-android-bundle-<commit_short>.tar.gz`, containing one top
directory with the bundle inside it:

```
wa-android-bundle/bundle/bundle.manifest
wa-android-bundle/bundle/installed.sha256
wa-android-bundle/bundle/installed.txt
wa-android-bundle/bundle/wa
wa-android-bundle/bundle/bin/wa
wa-android-bundle/bundle/bin/wa-update
wa-android-bundle/bundle/bin/release-lib.sh
wa-android-bundle/bundle/ui/<assets>
wa-android-bundle/bundle/LICENSE
```

`scripts/termux/cross-build-android.sh` already produces that bundle (and an archive in the
same shape); publishing it is a separate, manual step today.

## The trust chain, link by link

1. **Origin.** The index is fetched over HTTPS from the public repository on `main`. The
   anchor is that origin plus the repository's committed history — the same anchor anyone
   reviewing this repository already trusts.
2. **Pin.** One entry pins one bundle by `sha256(bundle.manifest)`. This is the value the
   operator used to paste by hand into `install-termux.sh --manifest-sha256`, now read from
   the index. The channel is exactly as strong as the manual install it replaces, and no
   stronger.
3. **Size.** The downloaded asset must be exactly `size` bytes. Fewer is `download_truncated`;
   more is `download_size_mismatch`. Neither is retried forever and neither installs.
4. **Hash.** `sha256(downloaded bundle/bundle.manifest)` must equal `manifest_sha256`.
   Otherwise: `hash_mismatch`, nothing is installed, and **there is no fallback**. A mismatch
   means the publisher and this phone disagree about the bytes; building from source would
   answer a different question.
5. **The bundle chain, unchanged.** The bundle then goes through `rl_bundle_verify` exactly as
   a hand-copied bundle does: `bundle.manifest` names `sha256(installed.sha256)`;
   `installed.sha256` names every member and nothing else; every `artefact <sha256> <path>`
   line is checked against the bytes; the ELF machine is read from the header (`aarch64`); the
   triple must be `aarch64-linux-android`; the candidate is executed once against a scratch
   home before it is switched in.
6. **Install.** The install is the same code a manual bundle install runs
   (`rl_bundle_install`): the current release is backed up byte-for-byte as the rollback
   release, the new release is staged and verified, and the switch is the same two-rename,
   intent-recorded switch every other path uses.

What this chain does **not** prove: that the bundle was built from the commit it claims (the
hashes bind the bytes, the desktop build is what asserts provenance), and that the runtime
works on a real phone beyond the one candidate probe. Those gaps are the same ones a manual
bundle install has, and they are not closed here.

## What `wa update` does with it

Rung 1 — `fetch-prebuilt`:

1. fetch and parse the index (`index_unreachable`, `http_client_missing`, `index_invalid`);
2. choose the entry: `--commit <sha>`, or `--ref <branch|tag|commit>` resolved with git, or
   the newest entry;
3. if there is no entry for that commit, go to rung 2 — loudly;
4. download the asset to a private temp directory, check size, unpack it only after every
   member path has been checked (`archive_unsafe`), check `bundle.manifest`'s hash
   (`hash_mismatch`), cross-check the bundle's `source_commit` against the entry
   (`release_commit_mismatch`);
5. hand it to `rl_bundle_install`, the same function `install-termux.sh --bundle` uses.

`wa update --check` is read-only, exits 0 when up to date, and reports the installed revision,
the target revision, the index, the newest entry's build facts, and **which channel it would
use**.

Rung 2 — the on-device build ladder — runs only when the index parsed and has no entry for
the requested commit. It says so before it starts, in these terms:

```
termux-update: WARNING: no published release for <commit_short>
termux-update:   index:  <url> (N entry/entries, none for <commit_short>)
termux-update:   fallback: build on this device. THIS DEVICE CANNOT COMPILE THIS WORKSPACE:
termux-update:   on the operator phone every rung of the build ladder died in rustc with
termux-update:   (signal: 11, SIGSEGV) while compiling cranelift_codegen. A compiler crash is
termux-update:   the expected result of this rung, and then nothing is installed.
```

## Refusals

Every refusal is named, and on every one of them **nothing is installed** and the installed
release is left untouched:

| name | when |
| --- | --- |
| `http_client_missing` | the node has neither `curl` nor `wget` |
| `index_unreachable` | the index could not be fetched (DNS, TLS, 404, empty body) |
| `index_invalid` | the index does not match the schema above (bad version, malformed entry, unknown field, `file:` URL without the opt-in) |
| `release_missing_for_commit` | the index has no entry for the requested commit → loud build fallback |
| `hash_mismatch` | the downloaded `bundle.manifest` does not hash to the entry's `manifest_sha256`; no fallback |
| `download_truncated` | the downloaded asset is smaller than the entry's `size` |
| `download_size_mismatch` | the downloaded asset is larger than the entry's `size` |
| `download_failed` | the transfer failed (not a size or hash disagreement) |
| `archive_invalid` | the asset is not a readable `tar.gz`, or unpacks to no bundle / to several |
| `archive_unsafe` | a member path would escape the extraction directory |
| `release_target_mismatch` | the entry (or bundle) is not built for `aarch64-linux-android` |
| `release_commit_mismatch` | the bundle's own `source_commit` is not the entry's `commit` |

The installed-side refusals (`installed_release_modified`, `installed_revision_unknown`,
`update_in_progress`, `state_inside_install`, …) are unchanged and are documented next to the
code that raises them.

## Publishing a release (today: a manual step)

The publisher side is **not** implemented in this repository yet. What a publish has to do,
using the existing cross-build:

1. build the bundle: `bash scripts/termux/cross-build-android.sh --out <dir>` — it writes
   `<dir>/bundle/`, `<dir>/bundle.manifest.sha256` (which is the value of
   `manifest_sha256`) and, unless `--no-archive`, `<dir>/wa-android-bundle.tar.gz`;
2. upload the archive where it is publicly readable over HTTPS, named
   `wa-android-bundle-<commit_short>.tar.gz`;
3. add an entry at the **top** of `releases/index.json` with that commit, that manifest hash,
   that URL, the archive's byte size (`wc -c`), `aarch64-linux-android`, the NDK version, the
   rustc version and the build time — all of which the bundle's `bundle.manifest` already
   records;
4. commit the index on `main`, so the entry and the bytes are both pinned by history.

No script does steps 2–4 yet, and nothing here has performed a real HTTPS download or a real
install on the phone: the fixture suite (`scripts/test-termux-release-fetch.sh`) proves the
index parse, the entry selection, the download, the hash refusal and the loud fallback with
real local bundles and no network.
