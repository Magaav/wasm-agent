# Installing a node: one command, then the same command to update

A new machine becomes a node with one line, and every later update is the line again:

```sh
curl -fsSL https://raw.githubusercontent.com/Magaav/wasm-agent/main/scripts/install.sh | sh
```

```sh
sh -s -- --check                                        # verify the published bundle; change nothing
sh -s -- --join https://rendezvous.colmeio.com           # announce this node to a fleet registry
sh -s -- --prefix ~/bin --port 8799 --no-service         # passed through to the installer core
```

No compiler, no `git`, no checkout of this repository. `scripts/install.sh` is the front door: it names the
platform, the channel that platform has, the commit the release was built from, and delegates to the
reviewed installer core (`scripts/linux/bootstrap.sh`, or `scripts/termux/bootstrap.sh` on a phone) with the
options translated. The core owns the verifying install - size, `sha256(bundle.manifest)` against the
index, every member against `files.sha256`, the ELF machine, one run of the candidate - and nothing is
written before all of it passes.

**Measured on `wa-desktop` (x86_64 WSL Ubuntu 24.04, glibc 2.39, warm network), 12/11, from an empty
`HOME`:**

| what | wall time | what it did |
| --- | --- | --- |
| fresh install, no service | **6.95 s** | index read, core fetch, 11.9 MB bundle + Node v24.22.1 (SHASUMS256-verified), verify chain, install `wa` + `wa-sentinel` + `ui/` + MCP runtime, `installed.txt`, `wa --version` answers |
| `--check` on an installed node | **0.40 s** | index + core + bundle verified, `install … : current`, nothing written |
| re-run (idempotent) | **0.40 s** | same bundle: `current`, no file replaced, no second Node download |
| before this change (by hand) | ~40 min, ~5 steps | apt toolchain, rustup, clone, provision code-mode assets, prepare, cold release build |

The number that matters for onboarding is the first row: **one command, seven seconds, no toolchain** - and
`wa` works when it returns.

## What the best installers actually do (read 12/11, not remembered)

| project | one command | channel | verification | install dir | self-update |
| --- | --- | --- | --- | --- | --- |
| Claude Code | `curl -fsSL https://claude.ai/install.sh \| bash` ([install.sh](https://claude.ai/install.sh)) | `downloads.claude.ai/claude-code-releases/latest` names a version, then `/<version>/manifest.json` names the per-platform artifact | per-platform `checksum` (64-hex SHA-256) read from `manifest.json`; refuses nothing but refuses to run under `sudo` (`CLAUDE_INSTALL_ALLOW_SUDO=1` is the explicit opt-in) | under `$HOME` (`~/.local/bin`, downloads in `~/.claude/downloads`); the downloaded binary then runs its own `claude install` to place the launcher and shell integration | the CLI updates itself from the same release service |
| opencode | `curl -fsSL https://opencode.ai/install \| bash` ([install](https://opencode.ai/install), 484 lines) | `github.com/anomalyco/opencode/releases/download/v<version>/<os>-<arch>`; the version comes from the npm registry or the GitHub releases list | probe of the asset URL (`curl -sIL`, status) before download; no checksum file in the script | `$HOME/.opencode/bin` (`INSTALL_DIR`), `mv` from a temp dir, `chmod 755` | `opencode upgrade` (and `--major`) |
| OpenAI Codex CLI | GitHub release assets per triple plus `npm i -g @openai/codex` ([releases API](https://api.github.com/repos/openai/codex/releases/latest): `codex-<triple>.tar.gz`, `.zst`, `.exe`, `.dmg`) | a versioned GitHub release, one asset per target triple | **sigstore bundles** ship beside the Linux musl assets (`codex-x86_64-unknown-linux-musl.sigstore`) | npm prefix, or the unpacked asset | `codex update` / npm |
| rustup | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` ([sh.rustup.rs](https://sh.rustup.rs), 930 lines) | `$RUSTUP_UPDATE_ROOT/archive/<version>/<arch>/rustup-init`, pinned by a `RUSTUP_VERSION` in the script | HTTPS only (no checksum in the script); the toolchain it installs is then hash-pinned by rustup itself | `~/.cargo/bin`, `--no-modify-path`, `--default-host`; PATH is prepended in `~/.profile`/`env` files | `rustup self update` / `rustup update` |
| bun | `curl -fsSL https://bun.sh/install \| bash` ([install](https://bun.sh/install), 326 lines) | `github.com/oven-sh/bun/releases/latest/download/bun-<target>.zip` (or a named tag) | none in the script | `$BUN_INSTALL` (default `~/.bun/bin`), `mv` out of the unpacked dir; PATH written into `.bashrc`/`.zshrc`/fish config | `bun upgrade` |
| deno | `curl -fsSL https://deno.land/install.sh \| sh` ([install.sh](https://deno.land/install.sh), 116 lines) | `dl.deno.land/release-latest.txt` names the version, then `dl.deno.land/releases/download/v<version>/deno-<target>.zip` | none in the script | `$DENO_INSTALL` (default `~/.deno/bin`) | `deno upgrade` |
| uv | `curl -LsSf https://astral.sh/uv/install.sh \| sh` ([install.sh](https://astral.sh/uv/install.sh), 2191 lines) | `INSTALLER_DOWNLOAD_URL` / the GitHub release for the resolved version | archive-internal digests; `UV_NO_MODIFY_PATH` | `$XDG_BIN_HOME`-ish (`~/.local/bin`) **and an install receipt** (`RECEIPT_HOME/<app>-receipt.json`, "$RECEIPT_HOME/$APP_NAME-receipt.json") | `uv self update`, which reads that receipt |
| Homebrew | `install.sh` (tap/bottle model) | a git tap: formulae pin a URL and a `sha256` per bottle | `sha256` per bottle in the formula; optional signatures for casks | `/opt/homebrew` or `/home/linuxbrew`, no sudo, `brew` manages its own prefix | `brew update && brew upgrade` |

The eight things they agree on - this is the "best path" the mission asked to extract:

1. **One line, HTTPS, no `sudo`.** Every one of them. Claude Code refuses `sudo` outright, because an
   install into `root`'s home behind a user's shell is how a machine ends up with two installs and no
   owner. Nothing here needs root; the one privileged step (a systemd unit) is the operator's.
2. **Platform/arch detection first, and a named refusal otherwise.** `uname -s`/`uname -m` maps to a
   target triple; the script says what it detected before it downloads anything.
3. **A prebuilt artifact per target, never a build on the target.** A compiler on the target is a
   support burden (toolchain versions, hours of CPU) that the publisher can pay once.
4. **A small index or manifest in front of the artifacts.** `latest` + `manifest.json` (Claude),
   `release-latest.txt` (deno), the releases list (opencode, bun), a tap's formula (Homebrew). It answers
   "what is current for *this* machine" in one small request, and it is where the pin lives.
5. **Verify the bytes before placing them.** Claude Code checks a per-platform SHA-256 from its manifest;
   Codex ships sigstore bundles; Homebrew checks the bottle's `sha256`. The projects without a checksum
   (rustup, bun, deno) are the exception, and they are older than the norm.
6. **An install directory in the user's home, and a PATH line they own.** `~/.local/bin`, `~/.bun/bin`,
   `~/.cargo/bin`, `$HOME/.opencode/bin` - and one guarded block in the shell startup file, added once.
7. **Idempotent re-run.** Paste the line again: same version means nothing is replaced (uv writes a
   receipt, rustup compares, opencode compares the version, bun/deno re-unpack the same artifact).
8. **Self-update through the same channel.** `bun upgrade`, `deno upgrade`, `uv self update`,
   `opencode upgrade`, `rustup self update`, the Claude CLI's own updater, `brew upgrade`. Not one of them
   asks the operator to re-run the installer to stay current.

Two things they do that this project cannot copy as-is, and the reason:

- **"latest" is enough for them.** An agent CLI is a leaf: it talks to an API. A wasm-agent node is a
  *peer* - it holds state, serves a UI, is driven by other nodes - so "install the newest thing" would
  silently move a fleet member across schema migrations. The channel here is a **release tag** and
  `installed.txt` records it (`release=`, `source_commit=`, `manifest_sha256=`), so "which build is this
  node" is answerable months later, and `/update` compares commits, not a moving `latest`.
- **Replacing the running binary in place.** Every CLI above ships one executable and replaces it in
  place, because nothing else is inside it. A node runs *two* long-lived processes (`wa-sentinel`
  supervising `wa serve`), so the swap has to come from outside them, and has to be reversible.

## The torus: the updater is a neighbour of the binary, never the binary itself

The idea the mission called "on the torus": a process may not replace its own image. Three consequences,
all implemented:

1. **Update is a different process, beside the binary.** On a Linux node, `wa update` (and `/update`)
   does not write `wa`; it starts the installer as a transient `systemd --user` unit
   (`lua/core/update.lua`, `run_release_updater`), which stops the sentinel service, stages the verified
   release, swaps the files and starts the service again. A node is never the thing that overwrites it.
2. **The updater travels with the release.** A bundle carries `scripts/install.sh` and
   `scripts/linux/bootstrap.sh` as ordinary members, pinned by `files.sha256` and by the index entry that
   names the bundle. The installer installs them beside `wa`, so `<prefix>/scripts/install.sh --update` is
   both the front door and the update path - **one command**, and the bytes that update a node are the
   bytes its release was verified with. An install from before this change keeps the update path it had
   (a bootstrap clone); nothing is invented for it, and the front door says `updater=absent` instead of
   fetching a file called `install.sh` from an older ref - before 11/11 that name held an SSH client
   wrapper.
3. **Slots, and a named rollback.** Every install keeps the pair it replaced in `<prefix>/.prev/` (both
   binaries and `installed.txt`), and `--rollback` puts them back with renames, offline, no index read. It
   restores the binary pair and the record - not `ui/`, and it says so: a half-restored tree is a worse
   answer than a narrow, honest one. (The phone channel has the full A/B slot switch: `scripts/termux/
   release-lib.sh`, `rl_recover`, `wa update --rollback`.)

## The channels, per platform, and what each one honestly is

| platform | one command | channel | state |
| --- | --- | --- | --- |
| Linux, glibc or musl, x86_64/aarch64 | `curl … install.sh \| sh` | `releases/index-linux.json` → bundle (`wa-linux-<arch>[-musl]-<sha12>.tar.gz`) | **works, measured (6.95 s)**; static musl bundle runs on any libc |
| Android / Termux, aarch64 | same line, detected from `PREFIX`/`uname -o` | the phone updater track (`scripts/termux/bootstrap.sh`), bundles from `releases/index.json` | works (the phone installer is the mature one; `docs/WHATSAPP-ARM64.md`) |
| Windows x86_64 | **no node bundle is published** | - | `scripts/install.ps1` is the legacy SSH-client installer, not a node install. `releases/windows-service.json` names a pilot zip (`package_url`, `sha256`) and `scripts/bootstrap-windows.ps1` is the source build. The front door refuses by name and says both. |
| macOS (arm64/x86_64) | **no node bundle is published** | - | refuses by name; a Mac builds with `scripts/deploy.sh`, and the front door then installs published bundles from that checkout (`--repo`) |

The refusal is a feature: the failure mode it replaces is a download that 404s halfway, or - worse - an
installer that download an asset for the wrong libc. The front door asks the channel question before any
download, and answers it in the operator's words.

## What this replaced, and what went away with it

Before 12/11 `scripts/install.sh` installed a **client**: an `ssh -t <host> wasm-agent "$@"` wrapper named
`wa`, aimed at a laptop that talks to somebody else's node, plus a copy of the MCP runtime, a pinned Node,
`mail-mcp` and the self-update skill in `~/.local/bin`. It never installed a node, and the measured cost of
actually bringing one up by hand was ~40 minutes - which is what an operator following the front door
experienced.

That client behaviour is **gone from this file**, on purpose, and nothing else in the tree depended on it
(no test, script or doc pinned the wrapper). A laptop that used it wants one of two things instead:

- a node of its own: the one command above;
- a client for a node elsewhere: `ssh <host> wa …` directly, or a published release's `wa` with
  `WA_REMOTE`-style configuration - the wrapper only ever saved typing.

Windows keeps `scripts/install.ps1` as the legacy SSH-client installer until a Windows node bundle is
published; the front door says so in its refusal rather than pretending to install a node there.

## The trust chain, end to end

```
releases/index-linux.json          # reviewed and committed; the trust root
  └─ entry: tag, commit(40-hex), target, size, manifest_sha256, installer_sha256
       ├─ bundle.tar.gz            # size + sha256 verified; the index names it
       │    ├─ bundle.manifest     # sha256(bundle.manifest) == entry.manifest_sha256
       │    │    ├─ source_commit  # == entry.commit
       │    │    ├─ target_triple  # == the target this machine asked for
       │    │    └─ files_sha256   # == sha256(bundle's files.sha256)
       │    ├─ files.sha256        # every member, including scripts/install.sh and scripts/linux/bootstrap.sh
       │    └─ wa, wa-sentinel     # ELF machine of the target, and `wa --version` is run before install
       └─ installer_sha256         # sha256 of scripts/linux/bootstrap.sh at that commit; the front door
                                   # refuses a core that is not these bytes (installer_hash_mismatch)
```

`SHA256SUMS` is published beside the assets as well - one line per asset, `sha256sum -c`-able, merged
across targets so publishing x86_64 after aarch64 keeps both rows (`scripts/release-linux.sh`,
`scripts/publish-node-binaries.sh`). It is the flat, conventional view of the same bytes, and it is
**signed** (`SHA256SUMS.sig`), see below. The index chain above is still what the installer reads first;
the signature is what makes a checksum worth checking at all, because a checksum from the same release as
the bytes proves only that the release agrees with itself.

## Signed releases

Every release asset a node installs is covered by `SHA256SUMS`, and `SHA256SUMS` is signed by an ed25519
key that **never leaves wa-vault** (`release-signing`). A node verifies that signature against a public
key it already holds, so swapping a binary and its checksum together stops working: the attacker would
need the key, and the key is behind an admin listener the agents cannot reach.

```
release-signing (wa-vault, admin listener only)  --signs-->  SHA256SUMS.sig
                                                                 │ verified by
config/release-keys.txt  (embedded in the wa binary)  ───────────┤ scripts/lib/release-signing.sh
<home>/.wasm-agent/release-keys.txt  (the node's copy) ──────────┤ rust/wa-host/src/release.rs  (`wa release verify`)
                                                                 └ the deploy, `wa update`, the binary-only updater
```

**Create the key** (operator, once, on the vault's admin page - never from a node):

1. open the vault's admin origin, enter the admin token;
2. *Release signing key* -> **Generate the key**. The vault makes the seed inside its own process, shows
   the **public** key and its key id (`release-signing-<16 hex>`), and offers the backup below;
3. take the ONE backup: either **write it to a file** on the vault's volume (`/data/backups/...`, mode
   0600, an existing file is never overwritten) and copy that to offline media, or **show it once** and
   write it down. After that call the seed is not readable by any route again - not by the admin API, not
   by a page reload, not with the admin token. If it is lost, rotate;
4. put the public key in `config/release-keys.txt` (`key release-signing-<id> <64 hex>`) and commit it.
   That is the anchor: the value is compiled into the `wa` binary, and a node also reads its own
   `<home>/.wasm-agent/release-keys.txt` so it can trust a rotation before it rebuilds.

**Publish** - the publisher needs the admin token where the vault's operator tooling already reads it
(`WA_VAULT_ADMIN_TOKEN`, or `WA_VAULT_ADMIN_TOKEN_FILE`, never on a command line): the release is signed
between building the sums and printing the `gh` line, and **a release that could not be signed is not
published** (`release_not_signed`, exit 6). Every signature is one line in the vault's log, with the key id
and the manifest's sha256 - never key material.

**Rotate** - a new key is trusted only when a release announces it:

1. generate the new key on the page (rotation replaces the seed; the new key gets its own single backup);
2. publish a release that carries `TRUSTED-KEYS` (the `wa-trusted-keys v1` list) and `TRUSTED-KEYS.sig`,
   signed by a key that is trusted **now**, and sign that release's `SHA256SUMS` with either key;
3. nodes accept the announced list for that release and can then be rebuilt/configured with it. A
   `TRUSTED-KEYS` signed by an unknown key is refused (`release_signature_invalid`, exit 5).

**What this does not do**: the signing host is the publishing host, so a compromised publisher account can
ask the vault for one signature - the differences are that the key itself is not on that host and every
signature is logged (key id + digest) where an operator can see it. The shell paths
(`scripts/install.sh`, `scripts/linux/bootstrap.sh`) verify against the key list in the commit they run
from, which is the same anchor the installer itself already rests on (`installer_sha256`); a node that has
a `wa` binary verifies against the list embedded in it. Until `config/release-keys.txt` holds a key every
release is refused **by name** and a node falls back to building its tree - that refusal is the feature.

## Choices, knobs, refusals

| knob | default | meaning |
| --- | --- | --- |
| `--check` | off | resolve, download and verify; install nothing |
| `--join URL\|none` | unset | `WASM_AGENT_RENDEZVOUS` for the fleet registry. **Not** a binding: binding operators to a device is `wa bind <fabric-url>` + a typed `BIND`, and an installer must never type consent for the operator |
| `--prefix DIR` | `~/.local/bin` | install directory (Linux) |
| `--no-service` / `--port` / `--client-port` | service on, 8799/8800 | the systemd unit and its ports (Linux) |
| `--adopt` | off | take over an install this channel did not make (it is backed up first) |
| `--rollback` | off | restore the binary pair the last install replaced |
| `--ref` / `--base` / `--repo DIR` | `main` / raw.githubusercontent.com / unset | which core to run: a ref, a mirror, or a local checkout |
| `WA_OFFLINE=1` | unset | never touch the network; the core must come from `--repo` |
| `WA_INSTALL_ALLOW_LOCAL=1` | unset | allow `file:` bases (fixtures) |

Named refusals, all before anything is written: `prerequisites_missing` (with the exact package line),
`os_unsupported`, `arch_unsupported`, `no_published_bundle_for_macos`,
`no_published_bundle_for_windows`, `index_unreachable`, `index_invalid`, `no_release_for_target`,
`installer_hash_mismatch`, `local_url_refused`, `url_scheme_refused`, `offline`,
`join_unsupported_on_android`, `prefix_unsupported_on_android`, `rollback_unavailable`, plus the core's own
names (`download_truncated`, `hash_mismatch`, `bundle_manifest`/`manifest_target`/`manifest_commit`
mismatches, `elf_machine_mismatch`, `candidate_does_not_run`, `node_busy`, `existing_install_not_ours` …).

## Tests

```sh
bash scripts/test-install.sh                 # 56 checks, no network, no systemd - in the fast path and the gate
scripts/fast.sh                              # the row: `check install-front-door`
```

`scripts/test-install.sh` pins, in order:

- the **platform matrix** by putting a fixture `uname` on `PATH`: Linux x86_64/aarch64 → the Linux
  channel; `PREFIX=…com.termux` or `uname -o Android` → the phone channel; macOS, Windows/MSYS and an
  unknown OS/arch → their named refusals, *before* any download;
- the **argument map** read from a stub core's own `$@`: `--join` → `--rendezvous`, `--check` → `--check`,
  `--prefix`/`--port`/`--client-port`/`--no-service` passed through in order, nothing invented when the
  operator did not ask;
- the **pin**: a correct `installer_sha256` runs the core, a wrong one refuses with
  `installer_hash_mismatch` and the core never runs;
- **one path with real bytes** (`/bin/true` as `wa`, so the ELF and "candidate runs" checks are real):
  fresh install → `installed.txt` says `release=`, `via=linux-bootstrap`, `updater=scripts/install.sh`;
  re-run → `current`, bytes unchanged; next release → bytes change, `.prev/` keeps the pair;
  `--rollback` → previous bytes back and `rollback_of=` recorded;
- a **tampered bundle** (index pin vs bundle) → the core's `hash_mismatch`, installed release unchanged;
- **offline** (`WA_OFFLINE=1`) and a `file:` base without the opt-in → refusals that name themselves.
- `scripts/test-update-release-updater.lua` (14 checks) pins the node side: `/update` prefers the installed
  front door, reports `behind`/`current` from the core's own words, and reports a refusing core as
  `release_check_failed` with its output.

Known limit of this suite: it runs on Linux only (it installs ELF files) and it cannot prove the Windows
installer, because this node has no PowerShell. That is why Windows is a named refusal in the front door
rather than an untested code path.

## Building and publishing a release

Nothing here publishes by itself; a release is a reviewed action (`docs/RELEASE-UPDATE.md`):

```sh
bash scripts/release-linux.sh --target x86_64-unknown-linux-musl --publish v0.1.0-alpha.16 --reason "…"
bash scripts/release-linux.sh --target aarch64-unknown-linux-musl --publish v0.1.0-alpha.16 --reason "…"
```

Each run builds the bundle with the shipping code-mode assets embedded (`scripts/codemode-build.mjs`),
verifies it, uploads the bundle plus `SHA256SUMS` (merged, not replaced), and writes the index entry -
including `installer_sha256`, so the installer a node fetches is the installer of the release it installs.
The index entry is the trust root and is committed by hand, reviewed like code.
