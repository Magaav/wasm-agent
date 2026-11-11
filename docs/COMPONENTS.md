# WASI components — installable plugins outside the core build

A **component** is a `wasm32-wasip2` program the host runs inside wasmtime with exactly the
capabilities it is granted. It is installed as files, not compiled into `wa`, so:

- adding or changing a component never rebuilds or redeploys the core;
- the same `.wasm` runs on every node (Linux, Windows, arm64, x86_64): one artifact, omni-device;
- a bug or crash stays inside its sandbox (memory cap, deadline, no ambient authority).

The first use is **MCP servers**: a component speaking MCP over stdio is a registry transport like
`stdio` and `http`, so its tools get the same approval, schemas, dispatch and **code mode** routing
as every other connector (`mcp_*` names are connector tools, callable inside scripts).

## Install layout

`WA_COMPONENTS_DIR` (default `~/.wasm-agent/components`):

| file | role |
| --- | --- |
| `<name>.wasm` | the component (`wasi:cli/run`) |
| `<name>.wasm.sha256` | its pin. **Required**: an unpinned or mismatched component is refused by name |
| `<name>.json` | its manifest: name, kind, description, declared `capabilities` |

`bash scripts/build-components.sh [name...]` builds `rust/components/*` for `wasm32-wasip2` and
installs all three atomically (pin last). It reads Cargo's artifact directory from `CARGO_TARGET_DIR`
when one is set, so a build inside a shared target directory (a node that builds everything into one,
and the job harness) finds what it just built. `host.components()` lists what is installed and whether
each pin verifies.

**What a deploy installs is what `components.lock` pins**, and since 08/11 that is every production
component - not `graph` alone. The set is read from the lock by `scripts/lib/deploy-components.sh`
(`wa_components_shipped`), installed as one set (`wa_components_install_set`), recorded before it is
replaced (`<components>/.prev/components.set`) and rolled back as one set. A name is shipped by being
pinned there; nothing else in the tree decides it. **Installed is not enabled**: a feature is switched
on per node in `policy.json` (`docs/FEATURES.md`), and `wa features` says which path is live.

## Distributing components: build once, install everywhere

Wasm is portable: the same `.wasm` runs on Linux, Windows, x86_64 and arm64. A component with C
inside (the graph: tree-sitter + SQLite) needs wasi-sdk, and until 05/11 a build was **not**
byte-reproducible across checkout paths (three panic-location paths were embedded - measured: two
checkouts of the same tree gave 8,185,719 and 8,185,720 bytes). Since then the build remaps the paths
out (next section), so the toolchain is the only machine-specific input left. A machine with no
wasi-sdk, or with a different toolchain, still cannot reproduce the pinned bytes from source - so the
build happens once and every other node installs the pinned bytes instead of rebuilding them,
including openclaw (arm64) and the laptop sandbox, which have no wasi-sdk at all. A deploy on such a
node is one command, with no manual step.

**Build machine** (the one with wasi-sdk):

```
WASI_SDK=<dir> bash scripts/publish-components.sh      # build, verify, bundle, print the gh command
```

It builds from the names `components.lock` pins, verifies each artifact's sha256 (and size) against
its pin - refusing a bundle whose bytes are not the pinned ones, printing the `components.lock` line
that would pin what it measured - and assembles the bundle directory (`graph.wasm`, `graph.json`, and
the `components.lock` the bundle satisfies; `build/components-release` by default). It never publishes
anything: it prints the exact `gh release create` command, so publishing stays a reviewed action.

**Release identity is the lock.** The tag is `components-<first 12 hex of sha256(components.lock)>`.
A node therefore names the exact bundle its pins describe using nothing but its own lock, and a tree
whose lock changed asks for a different tag - it can never install a release from another lock.

**A node** (scripts/deploy.sh stage 3e) resolves the bytes in this order, and every candidate is
verified against `components.lock` (sha256 **and** size) before it is used:

1. the component directory the core reads, when it already holds the pinned bytes (repeat deploy);
2. this node's cache, `<install>/components-cache/<lock sha256>` (a previous deploy's download);
3. the release: `gh release download components-<short> -R <owner/repo>` when `gh` is available, else
   `curl -L` of `https://github.com/<owner/repo>/releases/download/components-<short>/<asset>`.
   What lands is verified first and cached under the lock's sha (the `.complete` marker is written
   last), so a repeated deploy does not refetch and an interrupted fetch leaves nothing usable;
4. nothing reachable: this tree builds the component, which needs wasi-sdk, and the deploy must say
   `WA_DEPLOY_COMPONENT_REPIN=1` (a local build is not the pinned build).

| knob | effect |
| --- | --- |
| `WA_DEPLOY_COMPONENT_SOURCE=<dir>` | use these artifacts (built elsewhere) instead of resolving |
| `WA_DEPLOY_COMPONENT_REPIN=1` | accept a local build whose bytes are not the pinned ones (development) |
| `WA_COMPONENT_RELEASE_REPO=<owner/repo>` | read the release from another repository (fork, mirror); default: origin's GitHub slug, else `Magaav/wasm-agent` |
| `WA_COMPONENT_RELEASE_URL=<dir>` / `file://<dir>` | read the bundle from a directory instead of the network (a hand-copied bundle; what the test uses) |
| `WA_COMPONENT_RELEASE_URL=https://...` | base URL of the assets instead of GitHub's |
| `WA_COMPONENTS_CACHE=<dir>` | cache location; default `<install>/components-cache` |
| `WA_DEPLOY_COMPONENTS_DRY_RUN=1` | resolve, fetch and prove everything, install nothing |

A refusal is never a fallback: `component_hash_mismatch`, `component_size_mismatch` and
`component_release_lock_mismatch` mean the bytes that claim to be pinned are not, and the deploy stops
with nothing installed. Only `component_release_unavailable` (nothing cached, nothing reachable) falls
through to the local-build path.

`bash scripts/test-deploy-components.sh` proves this with no network, no wasi-sdk and no node: the pin
and size checks, the install/rollback, and the distribution paths with a local artifact directory and
a local release bundle (dry run, cache hit, `file://`, a tampered bundle, a foreign lock, an
unreachable release, and the publish script's verification).

### The node binary itself

A component is portable; `wa` is not. So the same idea needs one row per target triple and a release
per commit, because a deploy installs *the commit it holds* - "the latest binary" is another commit's
build and is refused.

```
release tag   node-<first 12 hex of the source commit>
pins          node-<sha12>.manifest
                schema=wasm-agent-node-binaries/1, source_commit=<40 hex>, source_tree=, rustc_version=,
                zig_version=, glibc_floor=2.31, codemode=embedded|empty, built_utc=,
                compiled_inputs=<sha256>
                <triple> <wa sha256> <wa bytes> <wa-sentinel sha256> <wa-sentinel bytes>
payload       wa-<triple>-<sha12>, wa-sentinel-<triple>-<sha12>
```

**`compiled_inputs` - why a docs-only commit needs no release of its own.** The tag names a commit, so
any later commit had no release at all, and a node whose disk cannot pay for a rebuild (openclaw) had no
path: a README fix would leave it unable to deploy. But a commit that changes no *compiled* input does
not need a new binary. The manifest therefore records a digest - sha256 over the sorted `<path> <blob
sha>` lines of every compiled-input path in that commit's tree, prefixed with
`wasm-agent-compiled-inputs/1` - and a deploy accepts **the newest published `node-*` release whose
digest matches its own commit's**, even though that release's `source_commit` differs. The exact
commit's release is always preferred when it exists; a refusal is still never a fallback; and the
bytes are verified against the manifest they came with exactly as before.

Which paths are compiled inputs is **one definition**, `wa_compiled_input` in
`scripts/lib/node-binaries.sh`, used by both halves: `deploy.sh`'s Lua fast path asks it about the paths
that changed, the digest asks it about every path in a tree. So "this change needs no new binary" and
"that release IS this commit's build" cannot disagree about the same file. Today it is `rust/`, `wit/`,
the Cargo and lock files, `config/`, and the scripts that build the binary (`scripts/codemode*`,
`scripts/build-*`, `scripts/provision-codemode*`); *not* `lua/` (the tree the binary loads from disk and
pins by capability digest), `docs/`, `tests/`, `ui/`, `modules/`, `skills/`, `jobs/`, `benchmarks/`,
`reviews/`, `review-evidence/`, `fixtures/`, `vault/`, other `scripts/`, or a top-level `<name>.md`. A
`.md` *inside* a compiled directory (`rust/README.md`) is still an input. Bumping the digest's schema
string is how a change to that classification invalidates old manifests instead of silently re-matching.

**Why.** `deploy.sh` ends in `cargo build` of `wa` and `wa-sentinel`. That is fine on a 16-thread
machine with a warm cache. openclaw (Ubuntu arm64, 2 cores, disk 99% full) needed the wasmtime 50
upgrade, which is a full rebuild of ~600 crates it can neither fit nor afford - so it installs the
bytes a machine with the toolchain built, and its deploy runs the same prove/install/rollback gate.

**Build machine** (any host with cargo; a Linux binary from Windows or macOS is a cross build):

```
pip install ziglang                      # or unpack a zig tarball; zig is the C compiler and the linker
cargo install cargo-zigbuild
bash scripts/publish-node-binaries.sh    # build both Linux targets, verify, print the gh command
bash scripts/publish-node-binaries.sh --from <dir>   # verify artifacts a CI built, pin them
bash scripts/publish-node-binaries.sh --check        # the plan; build nothing
```

The build is `cargo zigbuild --release --offline --locked -p wa-host --target
<triple>.2.31` (and the same for `wa-sentinel`). `.2.31` is zig's glibc floor: it links against no
symbol newer than glibc 2.31, so the binary runs on Ubuntu 20.04 and everything newer - and the script
reads the floor back out of the bytes (`GLIBC_2.x` symbol versions) and refuses a binary that needs
more than the manifest claims. Every member is verified before anything is printed for upload: sha256,
size, ELF machine (`b7` aarch64, `3e` x86_64). The candidate is executed when the host can run it
(natively, or through `--runner 'wsl -d Ubuntu --'`); when it cannot, the line says `run: SKIPPED`, and
the deploy proves the binary on the node before installing it.

Measured on wasm_the_first (Windows x86_64, 16 threads, rustc 1.98.1, zig 0.17.1, cargo-zigbuild
0.24.1), from a warm cargo cache of the crates and no cross artifacts:

| target | wa | wa-sentinel | built in | executable here |
| --- | --- | --- | --- | --- |
| `aarch64-unknown-linux-gnu.2.31` | 28,676,528 B | 5,292,696 B | ~7 min | no (no qemu/binfmt) -> SKIPPED |
| `x86_64-unknown-linux-gnu.2.31` | 33,895,504 B | 5,853,008 B | 4m44s (`CARGO_BUILD_JOBS=6`) | yes, through WSL Ubuntu 22.04 |

Both link with `GLIBC_2.30` as their newest symbol version (floor 2.31 accepted, openclaw's 2.35 fine).
`ring`, bundled SQLite, `zstd` and the vendored Lua all compile through `zig cc`; nothing needed a
patch. Two things are Windows-specific and measured: at the default 16 jobs cc-rs dies with
`Not enough quota is available to process this command. (os error 1816)` (desktop heap, not disk), so
the script caps `CARGO_BUILD_JOBS=6` on a Windows host; and `strip --strip-all` removed 16 bytes, so
the binaries are what they are (a release profile keeps no symbols worth stripping).

**How a landed commit gets its binary (the normal path).** A commit that touches a compiled input needs a
`node-<sha12>` release before a node that cannot compile can install it, so a landing is not finished until
that release exists. The last step of a landing (`skills/git-orchestrator/SKILL.md`,
`docs/FACTORY.md`) is one command on the canonical checkout, after `origin/main` has been read back:

```
CARGO_TARGET_DIR=<canonical>/build/node-binaries/target \
  bash scripts/publish-node-binaries.sh --ensure --publish \
    --target aarch64-unknown-linux-gnu --commit "$(git -C <canonical> rev-parse HEAD)"
```

`--ensure` asks the published releases whether one already carries this commit's `compiled_inputs=`
digest - the same rule the deploy's fallback uses - so a Lua-only or docs-only landing answers in seconds
and publishes nothing, while a commit that changed a compiled input builds once. `--publish` creates
`node-<sha12>` with the manifest and both binaries, or uploads over it, so re-running the step is
idempotent. `CARGO_TARGET_DIR` keeps the cross target bounded under the untracked `build/` directory
instead of mixing it into the native `rust/target`. Measured on wasm_the_first 2026-11-10
(16 threads, `CARGO_BUILD_JOBS=6`): **73 s** for `wa` and `wa-sentinel` together (42.8 s + 29.0 s) with
the dependency graph already built; a cold graph had reached 616 compiled dependencies at the 5-minute
mark, so the first build after a toolchain or cache reset pays the ~7 min in the table above. A covered
commit answered in **5.9 s** (release list plus one manifest read, nothing built). There is no watcher
and no recurring wake behind this: the landing runs it, and nothing else does.

The first deploy through this path was openclaw itself: `ad488c22` installed `node-4147192f2725` in 55 s
(preflight 1.7 s, fetching 12.6 s, proving 2.8 s, installing 38.0 s; no compile), its deploy log carrying
`deploy: binary_source: aarch64-unknown-linux-gnu ... (verified against node-4147192f2725, the build of
4147192f2725; this commit changes no compiled input)` and its install record
`binary_source=prebuilt-release binary_release=node-4147192f2725`. The published aarch64 pair is
42,783,232 B (`wa`) and 5,355,632 B (`wa-sentinel`).

**A cross build does not embed the code-mode assets by default** - `rust/wa-host/build.rs` exempts a
cross build from the `WA_CODEMODE_BUILD_ASSETS` rule, because a cross build is not the *build host's*
artifact. It is the node's, though, and a node without them starts every run with
`codemode_not_ready`. So `publish-node-binaries.sh` sets `WA_CODEMODE_BUILD_ASSETS` itself when the
prepared, pinned assets are present, records `codemode=embedded` in the manifest, and refuses by name
when they are not (`--allow-empty-codemode` is the deliberate development escape). The deploy refuses a
manifest that records `codemode=empty` unless the operator says `WA_DEPLOY_ALLOW_EMPTY_CODEMODE=1`.

**A node** (`scripts/lib/node-binaries.sh`, `deploy.sh` step 3d) resolves the bytes in this order, and
every candidate is verified against the manifest (sha256 **and** size, plus the ELF machine):

1. `WA_DEPLOY_BINARY_SOURCE=<dir>` when an operator says so (`wa`, `wa-sentinel`, and a
   `node-<sha12>.manifest` if one is there - when it is, its pins are enforced);
2. this node's cache, `<install>/node-binaries/<sha12>/<triple>` (a previous deploy's download; the
   `.complete` marker is written last, so an interrupted fetch leaves nothing usable);
3. the release: `gh release download node-<sha12> -R <owner/repo>` when `gh` is present, else the
   public asset URL. The manifest is fetched first, because it is the release's identity;
4. only when 3 answers "nothing usable is published for this commit and this target": the **digest
   fallback** - the newest `node-*` release (the last `WA_NODE_RELEASE_SEARCH`, default 20, from
   `gh api` or the public API) whose `compiled_inputs=` equals this commit's digest. Its bytes are
   cached under *its* source commit, and a later deploy of the same commit answers from that cache even
   when the release is gone. A manifest with no `compiled_inputs=` row (an artifact published before
   this existed), a different digest, or no row for this triple is *skipped*, not refused - none of
   those is a statement about this commit; once the digest matches, everything the manifest says is.

| knob | effect |
| --- | --- |
| `WA_DEPLOY_BINARY_SOURCE=<dir>` | install binaries another machine built (the supported path for a node with no toolchain at all) |
| `WA_DEPLOY_BUILD_ONLY=1` | build this tree, never install a published binary |
| `WA_DEPLOY_ALLOW_EMPTY_CODEMODE=1` | accept a published binary whose manifest records `codemode=empty` |
| `WA_NODE_RELEASE_REPO=<owner/repo>` | read the release from another repository; default: origin's GitHub slug, else `Magaav/wasm-agent` |
| `WA_NODE_BINARIES_URL=<dir>` / `file://<dir>` / `https://...` | read the assets from there instead of GitHub (a hand-copied release; what the tests use) |
| `WA_NODE_BINARIES_CACHE=<dir>` | cache location; default `<install>/node-binaries` |
| `WA_NODE_TARGET=<triple>` | name the triple instead of detecting it |
| `WA_NODE_DISK_FLOOR_BYTES=<n>` | the floor the fallback-to-build is measured against |
| `WA_NODE_RELEASE_SEARCH=<n>` | how many of the newest releases the digest fallback looks at; default 20 |

A refusal is never a fallback. `node_hash_mismatch`, `node_size_mismatch`, `node_machine_mismatch`,
`node_manifest_commit_mismatch`, `node_binary_missing` (a manifest that pins a target the release does
not carry) and `node_codemode_empty` stop the deploy. Only "nothing is published for this commit and
this target" (`node_release_unavailable`, `node_target_unpublished`) falls through to the build - and
only when the disk can pay for one: below the floor the deploy refuses with
`refused(no_prebuilt_binary_and_disk_floor)` and names both paths (`scripts/check-disk-floor.sh`). A
release whose manifest *matches* the digest is a statement about the bytes this deploy would install, so
from that point on every one of those refusals applies to it unchanged (a tampered, mis-sized,
wrong-machine or empty-code-mode matching release stops the deploy; it is not skipped in favour of the
next candidate).

What the deploy still does with a published binary: it stages the Lua tree against it, checks its
capability digest, proves a graph call through the staged component, proves the embedded runtime, and
answers `/health` on a scratch port - then `upgrade.sh` installs it and rolls back if the restart fails.
`installed.txt` keeps `source_provenance=clean-built-by-deploy` (the bytes are a clean build of exactly
this commit and this deploy verified them) and adds `binary_source=prebuilt-release|
prebuilt-source`, `binary_release=node-<sha12>`, `binary_commit=<40 hex>` and
`binary_source_commit=<40 hex>`, so "where did this node's binary come from" is a record and not a
guess. Its `commit=` is the release's **40-hex** commit id (the id the manifest's `source_commit` was
checked against), not the short id a build records. For a digest-fallback install the two ids differ and
both are recorded: `commit=` is the commit whose tree was installed (the Lua tree the node runs, always
the tree the deploy holds) and `binary_commit=`/`binary_source_commit=` is the commit whose build the
bytes are - the id a later fast-path deploy reads back as the binary's commit.

The supervisor is part of the same install, and a prebuilt deploy installs the prebuilt one. The release
carries `wa-sentinel-<triple>-<sha12>` beside `wa-<triple>-<sha12>`; the sentinel install step takes it
from the verified directory `wa_node_binaries_prepare` names (its `binary_verified:` line), re-reads the
manifest's pinned sha256 for that sentinel at that moment, and installs nothing when the file is not
those bytes (`refused(prebuilt_sentinel_mismatch)`, and `refused(prebuilt_sentinel_missing)` when the
directory holds no supervisor). Two reasons this is not read from the staging directory the fetch wrote:
`deploy.sh` removes that staging directory as soon as the proved node has been copied to its hash-named
candidate, and the cache-hit path only re-checks the *node's* sha256 (`.complete`) - a cached supervisor
can be swapped under a deploy that would otherwise install it. The build path is unchanged: with no
prebuilt step, the step installs `rust/wa-sentinel/target/release/wa-sentinel` exactly as before.
`scripts/lib/node-binaries.sh` is shipped beside the installed `deploy.sh` (as the component lib already
is), because `request deploy` runs that installed copy: without it the copy notes "no node-binaries
helper" and builds, which is the one thing the node this path exists for cannot do.

`bash scripts/test-deploy-node-binaries.sh` and `bash scripts/test-node-binaries.sh` prove both halves
with no network, no cargo, no zig, no node and no `gh` (a shim records any call): the plan, the cache,
the cache hit with the release gone, every refusal, the disk-conditioned fallback, the publisher's
`--check`/`--from` and every way a manifest can be wrong, the order of the calls inside `deploy.sh` (a
prebuilt install must never reach the toolchain check or the build), and two blocks read out of
`deploy.sh` by their own markers and executed against fixtures: the prebuilt branch (which resolves the
bytes and hands the sentinel step the verified supervisor) and the sentinel install step itself
(prebuilt supervisor installed with the staging directory already removed, the build path's own artifact
installed unchanged, the unpinned operator directory, a swapped cached supervisor refused by name) -
plus the install record step for a prebuilt install. The digest fallback is proved the same way: a real
git fixture whose docs-only and Lua-only commits digest the same while a rust change does not, an exact
release preferred over a matching older one, the newest match winning, the search bound, a rust change
falling back to the build (and refusing by name below the disk floor), a manifest with no digest skipped,
a matching-but-tampered release refused, and a docs-only HEAD installed end to end through the block
read out of `deploy.sh`. So a change there cannot pass by never running.


**Does this node run a newer release?** `lua/core/update_banner.lua` answers what an update would
actually install, in the two channels the updater has. A **tree** install compares `installed.txt`'s
`commit=` with the tree's local `origin/main` (a build), and never reads a release feed. A
**no-tree release** install picks the newest `node-<sha12>` release that carries this machine's
manifest, node and sentinel assets, so an aarch64-only release is never offered to x86_64. It then
shows `Update available (<sha12>): run wa update or /update` in the CLI footer, once at session
start, and as one yellow line above the composer footer plus a topbar badge in the window (one line,
in the layout - not a toast over the text area, and never hidden by `ui-resting`). It is not the
deploy and it changes nothing: no fetch, no merge, one cached feed read per fifteen minutes on the
release channel in `<state>/update-check.json` (the tree channel is local git only), and the verdict
is recomputed from the current install record so the indicator disappears after the swap without
waiting for a request. `git` is consulted only for local ancestry (`merge-base --is-ancestor`),
which is what tells a tree ahead of `origin/main` (no banner) from one behind it (banner). Details
and knobs: `docs/RELEASE-UPDATE.md`.
## Reproducible builds: the checkout path is not an input

Same source, same toolchain, same bytes - wherever the tree is checked out. What embedded absolute
paths, and what removes them:

| what | where it came from | what removes it |
| --- | --- | --- |
| panic locations and `file!()` strings of this tree and of a path dependency | Rust embeds the source path of every panic site, and a path dependency's path is **absolute** (measured: `rust/wa-graph`'s `audit.rs`, `extract.rs`, `store.rs`) | `--remap-path-prefix=<checkout>=/wasm-build`, added by `scripts/wa-remap-rustc` |
| the same for registry crates | Cargo hands rustc `CARGO_HOME`'s absolute path (measured: `rusqlite`, `ring`, `serde_json`) | `--remap-path-prefix=<CARGO_HOME>=/cargo-home`, same wrapper |
| C sources (tree-sitter, SQLite) | clang embeds `__FILE__`, and tree-sitter's assertions carry it - measured: `tree-sitter-0.24.7/src/language.c` under `CARGO_HOME`, unremapped until this flag was added | `-ffile-prefix-map=<checkout>=/wasm-build -ffile-prefix-map=<CARGO_HOME>=/cargo-home` in `CFLAGS_wasm32_wasip1` / `CFLAGS_wasm32_wasip2` (and `CXXFLAGS_*`); wasi-sdk itself is remapped too, though no SDK path is in today's artifacts |
| a stamped build time | clang honours `SOURCE_DATE_EPOCH` for `__DATE__`/`__TIME__` | `SOURCE_DATE_EPOCH=0` when the environment sets none |

`scripts/build-components.sh` exports all of it, so every caller gets it: the script itself, the local
build a deploy falls back to, and `scripts/publish-components.sh` (which calls it). `WA_COMPONENTS_REPRO=0`
turns the remapping off, which is how a diff-sized demonstration is made.

**Why the Rust half travels in a wrapper and not in `RUSTFLAGS`.** A remap has to name the checkout it
remaps, and Cargo hashes the whole `RUSTFLAGS` string into `-C metadata`. Two checkouts would then be
built with two different metadata hashes, which changes symbol mangling, which changes the order of
functions and constants in the artifact. Measured: with the remap in `RUSTFLAGS` every path was gone
and the graph still differed by 1 byte (8,216,117 vs 8,216,118; the two rlibs were
`libwa_graph-9830e40f60165081.rlib` and `libwa_graph-abe6a18e041567c3.rlib`). So the remap travels in
`scripts/wa-remap-rustc`, which Cargo reaches through `RUSTC_WRAPPER` resolved from `PATH`: the value
Cargo sees is the bare name, the same string in every checkout, and the paths are computed per
invocation. It fails loudly (exit 2) when it cannot find the tree, because a remap that matches
nothing is silent - that bug was measured too.

**The wrapper is compiled on Windows, and installed at one path for every checkout.** Two effects, each
measured:

* A `.cmd` cannot do this job, and no longer does. Cargo cannot start a `.cmd` itself: `CreateProcess`
  starts `cmd.exe`, which re-parses the arguments, expands `%VAR%` on its own and refuses a command
  line over 8191 characters ("The command line is too long"). `wa-whatsapp` failed exactly there: its
  `windows-sys` dependency passes one `--check-cfg cfg(feature, values(...))` argument naming ~250
  features, which the components in the gate happened to stay under. `rust/wa-remap-rustc` is the
  compiled twin (no dependencies): Cargo starts it directly, it adds the same flags, waits for the
  real compiler and forwards its exit code. `scripts/build-components.sh` compiles it on demand.
* The wrapper is installed once per wrapper source at a path every checkout shares -
  `${TMPDIR:-/tmp}/wa-remap-rustc/<first 16 hex of the sha256 of the wrapper sources>` (`WA_REMAP_DIR`
  overrides) - and that directory goes first on `PATH`. `RUSTC_WRAPPER` is the bare name
  `wa-remap-rustc` everywhere, and `WA_REMAP_CHECKOUT` / `WA_REMAP_CARGO_HOME` tell the installed copy
  which roots to remap: it lives outside the checkout, so its own path says nothing. On a POSIX host
  the script itself is installed instead of the binary: the same remap with `exec` and no compile.

**What is still part of the identity.** The toolchain (rustc, wasi-sdk) and the crates.io versions
(`Cargo.lock` travels with each component crate). `-C metadata` is Cargo's and cannot be pinned from
outside: rustc combines every `-C metadata` it is given, so a fixed one in `RUSTFLAGS` only adds a
constant to Cargo's part.

**Status, measured (06/11, cargo 1.98.1, wasi-sdk 34, two checkout paths):** a component without a path
dependency reproduces byte for byte - `svc-echo` 194,439 bytes, sha256 `480d8bed…` from both paths, the
same bytes the `.cmd` produced before this change, so the compiled twin does exactly what the script
did. A component with a **path dependency** still does not: `graph` 8,216,117 bytes at both paths with
no path string in either (`764ce5fb…` vs `39be1068…`) and `wa-whatsapp` 8,362,334 vs 8,362,462 bytes
(`2aa885af…` vs `7e6d1c55…`). The difference is ordering, not content: the code section shifts (7,795,727
of 8,362,334 bytes differ, from offset 4,164, which is why the size barely moves).

**That gap is Cargo's, not the wrapper's - measured, correcting an earlier guess in this file.** Both
builds ran the *same installed wrapper*, and what differs between them is Cargo's own metadata:
`libwa_graph-945e490b3b712fc9.rlib` in one tree, `libwa_graph-8c2a82544f1e05bf.rlib` in the other. Three
measurements pin it down:

1. One crate at two tree paths, wrapper path identical: identical `-C metadata`, identical artifact.
2. A component with a path dependency at two tree paths, wrapper path identical: different
   `-C metadata` for both units. Cargo's source identity for a path package is its **canonical absolute
   path**, and that hash travels into the dependent's metadata.
3. `-C metadata` is what moves the bytes: one tree, one path, only `RUSTFLAGS=-C metadata=ALPHA` vs
   `=BETA`, gave 8,216,117 bytes with sha256 `e1a83838…` vs `0cef95aa…`.

A wrapper cannot take that input over from outside: rustc *combines* every `-C metadata` it is given
(measured: `-C metadata=aaa`, `=bbb`, and both together are three different artifacts), so adding a
constant removes nothing, and replacing Cargo's value would mean inventing the crate disambiguator -
the one thing that keeps two versions of one crate apart - which fails silently as a symbol collision.
Not done. What would close it, in the order worth trying:

* Make the path dependency a **member of the component's own workspace**: measured, identical
  `-C metadata` and identical bytes from two tree paths. A package cannot be a member of two
  workspaces (measured: `package … is a member of the wrong workspace`), so this needs
  `rust/Cargo.toml` to give up `wa-graph` (and `wa-whatsapp-outbox`, `wa-whatsapp-index`) - a
  workspace decision, not a build-script one.
* Build inside a **content-addressed copy** at a fixed path: a copy is not a symlink, so the canonical
  path is stable for every checkout of the same source. A junction is not enough (measured: Cargo
  canonicalises it and the metadata stayed the tree's). Costs a copy per build, a shared target dir
  and disk per source revision.
* Upstream Cargo: a source identity for path packages that does not embed the checkout path, or
  `trim-paths` reaching `-C metadata` (still nightly-only here: `feature \`trim-paths\` is required`).

**The proof.** `bash scripts/test-repro-components.sh [name...]` extracts the tree into two differently
named paths (`clone-a` and a deeper, longer `clone-b-deeper-path`), builds the named components in each
with this same script, greps both artifacts for a leaked path, and compares the sha256 of every
artifact - including a component with C inside (`graph`). It exits 1 while anything differs and says
whether the difference is a leaked path or Cargo's metadata. It is not in `scripts/fast.sh`: it needs
wasi-sdk and two full component builds (minutes), and a landing does not have to wait for it.

## Capabilities: declared by the manifest, granted by the caller

Nothing is ambient: no filesystem, no network, no inherited environment. The manifest **declares**
what the component may ever need; the registry definition **grants** a subset; the host refuses a
grant the manifest did not declare (`component_capability_not_declared:<field>:<key>`) before the
component is instantiated.

| capability | grant shape | what the component sees |
| --- | --- | --- |
| `env` | `{KEY: "HOST_ENV_NAME"}` | `KEY` = value of the host variable (a reference, never a literal) |
| `file_env` | `{KEY: "HOST_ENV_NAME"}` or `{KEY: "/abs/path"}` | the **host** reads that file (named by a host variable, or directly: a path is a location, not a secret) and the component sees its trimmed contents as `KEY`. Secrets stay file references; the component has no filesystem |
| `net` | `["127.0.0.1:28787"]` | TCP connect to exactly these socket addresses. A manifest may declare `host:*` (any port on that host) |
| `config` | `{...}` (registry `config`) | non-secret JSON in `WA_COMPONENT_CONFIG`. Data, not a capability |
| `dirs` | `[{"host":"/abs","guest":"/graph/root","write":false}]` | the host directory preopened at the guest path, read-only unless `write`. The manifest declares the guest paths (`"dirs":["/graph/root"]`); the caller chooses the host directories. Used by the kernel for the `graph` component (root read-only, a private database directory writable) |

Limits per run: 256 MiB memory, stdin ≤ 4 MiB, stdout ≤ 16 MiB, stderr tail 64 KiB, deadline =
the definition's `timeout_seconds` (epoch interruption, ≤ 600 s). A run that hits the deadline after
a `tools/call` was sent reports `outcome: unknown`, never ok.

## MCP over a component

Registry definition (`mcp` tool, `put`):

```json
{"id":"whatsapp","name":"WhatsApp","transport":"component","component":"mcp-whatsapp",
 "env":{"WA_MCP_WHATSAPP_ACCOUNT":"WA_WHATSAPP_ACCOUNT","WA_MCP_WHATSAPP_GENERATION":"WA_WHATSAPP_GENERATION","WA_MCP_WHATSAPP_URL":"WA_WHATSAPP_CONNECTOR_URL"},
 "file_env":{"WA_MCP_WHATSAPP_TOKEN":"WA_WHATSAPP_TOKEN_FILE"},
 "net":["127.0.0.1:28787"],
 "config":{"allowed_conversations":["<exact chat id>"]},
 "timeout_seconds":60,"tools":{"read_newest":"read","read_snapshot":"read","list_chats":"read","lookup_self":"read","inspect_chat":"read"}}
```

Then `probe` → `enable`, exactly as for a stdio server. Per request the host runs the component
once with `initialize`, `notifications/initialized`, `tools/list` and (for a call) `tools/call` on
stdin, parses the JSON-RPC answers with serde (schemas stay byte-exact: `{}` is never `[]`), and
returns the same answer shape as `scripts/mcp-client-core.mjs`.

**Schema hash = the component's pinned sha256.** The same bytes answer with the same tools, so a
changed component is refused before anything is sent (`mcp_tool_schemas_changed`) and must be
probed and enabled again: an upgrade is an explicit approval, as for any MCP server.

## Add a component

1. `rust/components/<name>/` with its own `Cargo.toml` (`[workspace]` empty: never a member of the
   core workspace), `manifest.json`, `src/main.rs` reading stdin / writing stdout.
2. `bash scripts/build-components.sh <name>` — builds and installs it.
3. `bash scripts/publish-components.sh` on the build machine, then run the `gh release create` line it
   prints — that is what lets a node without wasi-sdk deploy it.
4. Register it (`mcp put` with `transport:"component"`), `probe`, `enable`.

Rust's std works on `wasm32-wasip2`, including `std::net::TcpStream` for granted addresses.
Other languages work if they emit a WASI preview 2 command component.

## Test a component without a node

`rust/wa-fake-kernel` serves `wa:kernel@0.2` in memory, so a service component's tests run under
`cargo test` against the real `.wasm`: the same runner the node uses, with kv, http, websocket,
speech, secrets, log and health scripted. An exchange no rule names is refused by name (never an
empty 200), an ungranted capability is refused as the node refuses it, and a secret's value never
enters a record. `kernel.record()` / `kernel.save_replay()` / `kernel.replay_from()` are the
`wa-bounded` record/replay hooks, and `wa dev <component-dir>` runs the edit-build-hot-swap loop
(new instance healthy, then the old one stops). Design, the refusal rules and the timings are in
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md), "Iterating on a component".

## A Lua test that needs a real component

`host.graph_*` is served by the `graph` component, so a test that asserts a graph *answer* needs one
installed in the directory its node reads (`WA_COMPONENTS_DIR`, else `$HOME/.wasm-agent/components`).
A test declares that with `scripts/lib/test-components.lua`:

```lua
local components = dofile('scripts/lib/test-components.lua')
local seeded, why = components.require('graph')
if not seeded then components.skip('test-graph-freshness', why); return end
```

`require` copies the component, with its pin and manifest, from the set the runner built
(`WA_FAST_COMPONENT_SOURCE`) into the test's *own* component directory, and re-checks the pin the
loader would check. Absent - no wasi-sdk, the docker fast path, a checkout that never built one - it
returns the reason and the test prints `SKIP <test>: <reason>`: a named hole, never a silent pass.

`scripts/fast.sh` builds that set once from this tree with `scripts/build-components.sh` (so it
carries the pin a deploy would install) and caches it under the worktree's own git dir; a row that
needs no component pays nothing, and a test that asserts what an *absent* component does keeps
seeing an absent one. The full gate exports a single `WA_COMPONENTS_DIR` for its whole run
(`scripts/test.sh`) because its home is shared; the fast path's rows are hermetic and parallel, so
each installs into its own home - which is also the only directory `scripts/test-features-gate.lua`
will write its stubs into ("never a node's component directory").

## Components so far

Shipping: what `components.lock` pins, i.e. what every deploy installs.

| component | kind | what | default path |
| --- | --- | --- | --- |
| `graph` | mcp | tree-sitter code graph in SQLite: index, search, source, explain, path, impact, patch audit | **component** - every `host.graph_*` call runs it, there is no native fallback |
| `agent-core` | core | the Lua core as one component (`wa:kernel/host.call`), the whole turn inside the sandbox | native node core, until the `agent_core` gate is wired |
| `codemode` | tool | the code-mode guest protocol and tool table over `wa:kernel/quickjs` | native `lua/core/codemode.lua` (`codemode`) |
| `hooks` | hooks | hook/mods matching, ordering, timeouts and the Claude Code protocol's interpretation | native `lua/core/hooks.lua` (`hooks`) |
| `memory` | memory | recall ranking, transcript search, scope rules, retention decision | native `lua/core/memory.lua` (`memory`) |
| `model-gateway` | model | task classes, data-label gating, route/fallback/breaker/budget over the provider edges | native gateway, until the `gateway` gate is wired |
| `selfloop` | selfloop | the wake/notes/probe state machine | native `lua/core/selfloop.lua` (`selfloop`) |
| `telemetry-sink` | service | subscribes to the bus, batches spans/metrics/events into the node's bounded sink | native sink, until the `telemetry_sink` gate is wired |
| `wa-email` | service | IMAP in / SMTP out through `email.outbox`, indexed in its own kv | installed and inert until an operator enables it |

Not shipped, built by the gate only: the fixtures `svc-*`, `memory-crash`, `memory-wedge`, `mcp-echo`,
and the MCP servers `mcp-whatsapp` (a registry definition an operator enables with `mcp put`/`enable`)
and `wa-whatsapp` (installed by hand on the node that runs it, `scripts/build-whatsapp.sh`).

`components.lock`'s own header says how a pin is regenerated, and why a build is not byte-reproducible
across checkout paths. `scripts/test-deploy-components-shipped.sh` proves the shipped set: the lock,
the real artifacts (when this checkout has them), install, rollback and the deploy's use of the set.

## Next: service components

MCP components are one request per run. The WhatsApp connector itself (`connectors/whatsapp`) needs
a **long-lived** component: a persistent socket, scoped storage, timers, and a host-provided
speech-to-text capability (native faster-whisper stays outside wasm: the Candle-in-wasm `small`
model measured ~17x slower, `benchmarks/whisper-wasm`). That is the next host class on this same
manifest/grant model; it is not built yet. Design and the feasibility spike (whatsmeow compiles to
wasip1; a guest reached WhatsApp's websocket through host TCP): [SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md).
