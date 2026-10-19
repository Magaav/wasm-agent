# wasm-agent

**Your agent. Your machines. Automation you can hold to account.**

wasm-agent is building a personal agent that remembers what you ask it to,
works with your files and applications, and can use other computers with your
permission. Models provide the reasoning; they are not the agent's identity.

There are **two ways into the same product**:

- **Personal:** run your own agent, connect your model, and automate your work.
- **Assisted:** join an automation provider's environment as a guest. An operator
  helps build and run automations on your machine through access you explicitly
  grant, can observe, and can revoke.

For an automation professional, this means turning expertise, tools and tested
procedures into a service for customers—not asking every customer to become an
agent developer. For the customer, it should mean **“help me automate this”**, not
“configure an infrastructure stack.”

> **Status: live assisted alpha, not a general customer-ready release.** The
> Windows paste-once guest installer and managed service are public and have passed
> one disposable end-to-end operator-effect/revocation check. Clean-VM usability,
> publisher signing, conversation isolation and recovery remain release gates.

## The experience we are building

### My own agent

Install → name the agent → connect my model → choose a workspace → do useful
work → inspect the result → return later with continuity.

A friendly name belongs to the agent, not to a Git branch. Switching models or
adding a device should not replace its identity or erase its memory.

### Help from an automation professional

Accept an invitation → verify the operator → review requested access and data
sharing → connect this computer as a guest → approve a task → see what happened.

The operator can use their models, tools, skills and reusable automations to help
on the customer's machine. A customer should not need a model subscription or a
coding toolchain merely to receive assisted automation. The service must explain
who pays for model use and what data goes to which provider.

The customer remains in control: visible operator access, pause/disconnect,
revocation, and approval before expanding access. Being discoverable on the
network is **not** permission to control a machine. Customers must not be able to
see or operate each other's nodes, tasks, credentials or memories.

These are the target experience and release requirements. See the
[roadmap](ROADMAP.md) and [release contract](docs/release/RELEASE_CONTRACT.md)
for the implementation boundary.

## What exists today

| Capability | Current implementation and boundary |
| --- | --- |
| Local agent | Rust host with an embedded Lua core; terminal chat and a web UI. You supply an OpenAI-compatible model endpoint. |
| Desktop companion | Windows WebView2 window with avatar, compact chat and management views. The shell is Windows-first. |
| Memory and continuity | Explicit remember/recall, resumable conversations and context compaction. Memory retrieval is on demand. |
| Evidence | Stored transcript, tool traces, usage accounting and retrievable large tool results. An answered run is not proof of task success. |
| Tracked file changes | Content-addressed file snapshots, diffs and conflict-aware undo. This does not undo arbitrary shell, network or application effects. |
| Multiple machines | Node keys, signed peer calls, rendezvous discovery and an outbound relay for NAT'd nodes. |
| Guest execution | Managed guests pin operator keys, require expiring local consent, reject unrelated callers and support local revocation. The managed registry—not a node's claimed role—controls promotion. Public rollout remains gated. |
| Reusable procedures | Skills for on-demand instructions; spells for repeatable procedures with postconditions; WASM tool plugins. |
| WhatsApp audio | Persistent linked-device journal and opt-in incoming + own-outgoing original-chat transcription; EN default/PT per-account. [Setup](docs/WHATSAPP-CONNECTOR.md), [mandatory legacy retirement](docs/WHATSAPP-MIGRATION.md). |
| Supervision | A separate sentinel handles requested restarts/upgrades and budgeted event-triggered wakes. |
| Worker pool | On-demand interpreters keep reads responsive and route chat work across workers. Conversation ownership and overlapping streams still need release-level isolation verification. |

Default transcript retention is **seven days**; debug transcripts are retained.
Explicit memories are a separate store. Tool artifacts and telemetry have their
own retention limitations. “Evidence” does not mean unlimited archival storage;
see [memory](docs/MEMORY.md) and [observability](docs/OBSERVABILITY.md).

## Trust before reach

The current runtime is intended for controlled development environments.

- Native shell and desktop tools act with the process/user's authority. Selecting
  a workspace is not an enforced filesystem sandbox.
- WASM plugin isolation does **not** sandbox the entire agent or native tools.
- HTTP authentication, origin checks and cross-worker state isolation need
  hardening before public/customer use. Localhost alone is not authentication.
- Peer signatures establish identity; they do not establish customer consent.
  Existing master/guest roles and optional trusted-master configuration are not
  a substitute for explicit enrollment, scoped grants and revocation.
- Do not expose the development HTTP service publicly or enroll customer
  machines as though those release gates had already passed.

Remote assistance will be opt-in. There will be no silent enrollment, copied
operator credentials, hidden control, or fallback to unrestricted access when
a provider or authorization service is unavailable.

## Running the developer preview

There are currently no published release assets. `scripts/install.ps1` and
`scripts/install.sh` are **legacy operator provisioning scripts** tied to the
maintainers' infrastructure; they are not public installation instructions.
Do not use them to onboard customers.

From a source checkout with the Rust/C build prerequisites and cached crates:

```bash
cargo build --release --offline --manifest-path rust/Cargo.toml
```

The executable is `rust/target/release/wa` (`wa.exe` on Windows). Use its `help`,
`paths` and `status` commands. Configure your own endpoint through the existing
`<config>/env` file reported by `paths`, or process environment:

```text
WASM_AGENT_LLM_BASE_URL=https://your-compatible-provider.example/v1
WASM_AGENT_LLM_MODEL=your-model
WASM_AGENT_LLM_API_KEY=your-own-key
```

Keep that file private and out of Git. Do not copy a maintainer's configuration.
Then run `wa chat`, or `wa serve --ui <absolute-path-to-ui>` and open
`http://127.0.0.1:8799/` in a trusted local browser. Here `wa` means the built
executable, not an assumed installed command. Without a model, local memory and
ledger commands remain available.

Public packaging work starts with `scripts/package-windows.ps1`: it builds a
versioned **candidate archive**, not a release approval. The archive includes a
fresh-install script and `bin/wa.cmd setup`, `doctor` and `ui`. Setup stores your
own credentials with restricted file permissions; guest mode stays disconnected.
See the [candidate guide](docs/release/RUNTIME.md) and
[release status](docs/release/RELEASE_STATUS.md) for instructions and verification.

### Android / Termux developer preview

An Android arm64 phone can build and run the local agent inside
[Termux](https://termux.dev/). This is a source-based developer preview, not an
APK, Play Store release, background Android service, or unrestricted controller
of other apps. It runs with Termux's Android app authority and serves the existing
UI only on the phone's loopback interface.

**One command**, for a fresh phone, an older preview, or a node already on the
update track. It clones only if `~/wasm-agent-bootstrap` is absent, then runs the
reviewed script from that clone (there is no `curl | sh`):

```sh
d=~/wasm-agent-bootstrap; [ -d "$d/.git" ] || git clone --depth 1 https://github.com/Magaav/wasm-agent.git "$d" || exit 1; exec bash "$d/scripts/termux/bootstrap.sh"
```

`bootstrap.sh` picks the step from the installation's own state: a fresh install,
the one-time migration of a preview older than `wa update`, or `wa update` on a node
that already has it. Its options are `--checkout DIR`, `--repo URL`, `--upstream URL`
and `--check` (report without changing anything). The upstream recorded for later
updates defaults to the checkout's own `git remote`, so `upstream_url_unknown` cannot
happen on a normal clone. Paste the same line again later to update: the clone is
reused and the update runs.

Then:

```sh
wa setup
wa doctor
wa ui
```

The explicit form is still supported and does the same thing by hand. A fresh
install, from a checkout in Termux:

```sh
bash scripts/install-termux.sh
wa setup
wa doctor
wa ui
```

The installer obtains build prerequisites through Termux `pkg`, builds the locked
Rust workspace on the phone, and installs it under `$PREFIX/opt`. `wa ui` remains
in the foreground and opens `http://127.0.0.1:8799/`; keep that Termux session
running. Reinstallation currently refuses an existing preview so it cannot
overwrite a running or stateful installation silently. Agent state and credentials
live under `~/.wasm-agent`, outside the replaceable runtime directory.

#### Building on a phone: the build ladder

A phone is not a build server: several rustc processes at once, on a device that is
also running Android and the UI, is more memory than it has. A measured failure on an
Android 10 arm64 phone was rustc killed by a signal while compiling
`cranelift_codegen` (the Wasmtime engine), with ~2.7 GB available on 8 cores. So the
Android build sets the knobs it can justify for exactly that failure, on every attempt:

* `CARGO_BUILD_JOBS=1` - one rustc at a time, so peak memory stops scaling with the
  core count. This is the lever that matters most, and the one worth losing build time
  to.
* **no** `RUSTFLAGS=-C codegen-units=1`. That flag puts a whole crate into one LLVM
  codegen unit and therefore *raises* peak memory inside that rustc - the opposite of
  what a memory-starved compiler needs - and the crashing build was already running
  it. Default codegen units let LLVM split a crate that size into several units, each
  finished and released in turn.
* `RUST_MIN_STACK=33554432` from the second attempt on: a SIGSEGV is as much the
  signature of a stack overflow as of a wild pointer, and rustc's query and const-eval
  recursion is legitimately deep in crates like this one. It costs address space, not
  memory - thread stacks are mapped lazily - so on a memory-starved device it is close
  to free.
* `CARGO_INCREMENTAL=0` only on the debug attempt, where it does something: a
  `--release` build already has incremental off, and cargo's `dev` profile turns it on
  for a fresh build that has nothing to reuse.

If the compiler crashes, the script walks a **ladder** instead of stopping at the first
attempt, reports each rung, and keeps one log per attempt under
`$PREFIX/opt/wasm-agent-update/build-logs/`:

| attempt | profile | what it does |
| --- | --- | --- |
| 1 | `default` | one job; everything else cargo's own default |
| 2 | `conservative` | one job and a 32 MiB compiler stack |
| 3 | `debug` | `cargo build --profile dev`: a debug, unoptimized build |

The third rung is not another mitigation, it is a way through: a debug build does the
type checking but almost none of the optimizer work, so it can build a crate the
release build cannot, and **an unoptimized runtime that starts is better on a phone
than no install**. It is slower to run and a larger binary on disk, and it *is* the
installed runtime: the attempt that succeeds decides which binary is installed,
`installed.txt` records `build_profile=dev`, and `wa doctor` reports it.

A value **you** set is never overridden: the build reports it as kept, e.g.
`CARGO_BUILD_JOBS=3 (yours, kept)`, and says where every value came from. A value the
script sets for a rung is labelled as the script's, for that rung - never as yours.
Non-Android hosts are untouched: one rung, host defaults, no profile variables, so CI
and Windows build exactly as before (and a host whose compiler crashes is refused after
that one rung, because the phone's knobs exist for the phone's memory, not to be walked
onto CI).
`WA_TERMUX_BUILD_PROFILE=default|conservative|debug` forces one rung anywhere (one
attempt, no ladder); an unknown value is refused by name.

#### If all three attempts fail

When the compiler dies of a signal, cargo reports it as `process didn't exit
successfully: \`rustc ...\` (signal: 11, SIGSEGV)` and a build that stops there says
nothing useful. This one recognises that shape (`signal: 11`, `SIGSEGV`, `process
didn't exit successfully`), prints `THE COMPILER CRASHED` instead of a build error, and
moves to the next rung. If every rung fails it stops with a named refusal
(`compiler_crash_build_refused`) that names every attempt, every retained log, the
crate the last log points at (from its `crate-name` line - that is how
`cranelift_codegen` was identified) and where each build setting came from, and asks
you to paste three lines:

```sh
rustc -V
free -m | head -3
nproc
```

No release is assembled, switched or installed, and node state is not read or written.

#### When the phone cannot compile it: a prebuilt bundle

The ladder above is the right first answer. On one measured device it ran out of answers:
all three rungs died inside rustc with `(signal: 11, SIGSEGV: invalid memory reference)`,
`cranelift_codegen` was the last crate in every log, and that same dependency at the same
version had already built and installed successfully on that phone. The code did not
change; the device's toolchain and memory state did. So the runtime can also be built **on
a desktop** and installed **from bytes** - the phone then never compiles cranelift at all.

Build the bundle on any desktop (Linux, macOS, or bash on Windows) with the Android NDK:

```sh
rustup target add aarch64-linux-android
# Android NDK r27d (NDK 27.3.13750724). Official archive and checksum from Google's
# repository2-3.xml: windows 781506724 bytes sha1 56607cbccd3642d4a1991f6bb3114a00f884f426,
# linux 663956036 bytes sha1 22105e410cf29afcf163760cc95522b9fb981121. The sha256 below was
# computed from the windows archive this repository was verified with.
curl -LO https://dl.google.com/android/repository/android-ndk-r27d-windows.zip   # or -linux / -darwin
printf '%s  %s\n' 82094f53e66a76b6a9ec4fc35a5076091a92de3b91d13c5d4a7cfdb226304c59 \
  android-ndk-r27d-windows.zip | sha256sum -c -
unzip -q android-ndk-r27d-windows.zip
bash scripts/termux/cross-build-android.sh --ndk "$PWD/android-ndk-r27d"
```

`--check` prints the resolved toolchain and the exact command without building anything.
The script sets exactly these variables and makes exactly this one cargo call:

```
CC_aarch64_linux_android                  <ndk>/toolchains/llvm/prebuilt/<host>/bin/clang
CFLAGS_aarch64_linux_android              --target=aarch64-linux-android21
AR_aarch64_linux_android                  <ndk>/toolchains/llvm/prebuilt/<host>/bin/llvm-ar
CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER <ndk>/toolchains/llvm/prebuilt/<host>/bin/clang
RUSTFLAGS                                 -C link-arg=--target=aarch64-linux-android21

cargo build --release --locked --target aarch64-linux-android \
  --manifest-path rust/Cargo.toml -p wa-host --bin wa
```

Three choices are deliberate. `clang --target=` is used rather than the NDK's
`aarch64-linux-android<api>-clang` wrapper, because the wrappers are shell scripts or
`.cmd` files that a native desktop cargo cannot exec on every host, while one clang driver
with an explicit `--target` works the same everywhere (the NDK clang finds its own sysroot
next to itself). None of the phone's memory knobs are set - `CARGO_BUILD_JOBS`,
`RUST_MIN_STACK` and codegen units exist for a memory-starved compiler, and this is a
build host, so it builds with cargo's own defaults exactly like any non-phone host in the
ladder. `--locked` is used because a bundle must be the tree, not the tree plus whatever
dependency resolution felt like that day. Nothing is downloaded implicitly: if the local
rustc has no Android std the script refuses and names `rustup target add`, the Rust form of
this repository's `GOTOOLCHAIN=local` rule.

What comes out (nothing of it is versioned):

```
build/android-bundle/
  wa-android-bundle/            the closure the phone installs:
    wa                          the aarch64 Android runtime
    bin/wa  bin/wa-update  bin/release-lib.sh
    ui/index.html ... icon-512.png    the nine assets the launcher serves
    LICENSE  installed.txt  installed.sha256
    bundle.manifest             what produced these bytes
  wa-android-bundle.tar.gz      the same bundle plus the installer scripts, for the phone
  wa-android-bundle.tar.gz.sha256
  bundle.manifest.sha256        the one hash to paste (also printed at the end)
```

`bundle.manifest` records the target triple, the ELF machine, the Android API level, the
source commit and tree, the built-at time, the host triple, the rustc version and commit,
the NDK version and the archive it came from, `build_profile=cross-android`, the release
manifest's own sha256, and one `artefact <sha256> <path>` line per file. That gives one
chain: `sha256(bundle.manifest)` -> `release_manifest_sha256` -> `installed.sha256` ->
every byte, which is why a single pasted hash pins the whole bundle.

Install it on the phone. Two lines, no compiler, no network, one `adb push` beforehand:

```sh
# from the desktop:  adb push build/android-bundle/wa-android-bundle.tar.gz /sdcard/Download/
cd ~ && rm -rf wa-android-bundle && tar -xzf /sdcard/Download/wa-android-bundle.tar.gz
bash ~/wa-android-bundle/scripts/install-termux.sh --bundle ~/wa-android-bundle/bundle --manifest-sha256 <sha>
```

That is the same installer and the same release rules as the source path, with the same
guarantees as `--adopt-existing`, and it refuses by name rather than guessing:
`manifest_sha256_invalid` (not a 64-character hex sha256), `bundle_missing`,
`bundle_manifest_sha256_mismatch` (a partial copy, a modified bundle, or the wrong hash),
`bundle_incomplete` (a required file is absent), `bundle_modified` (a member changed, was
added, or was truncated), `bundle_member_mismatch` (a file disagrees with its per-artefact
hash), `wrong_abi` and `wrong_target_triple` (the ELF machine is read from the header, not
the filename), `bundle_manifest_mismatch` (the records contradict each other),
`installed_release_modified`, `state_inside_install`, `backup_conflict`, and the Termux
guards (`run this inside the Termux app`, `android_required`, arm64 only). The current
installation is copied aside byte-for-byte, verified file by file against a manifest, and
kept under its own commit as the rollback release, so `wa update --rollback` works offline.
`installed.txt` records `build_profile=cross-android`, `source_provenance=cross-built-android`,
the bundle's manifest hash, the NDK and the rustc version; `wa doctor` prints all of that.
A release also records the name it was switched in under (`release_key`), which is what lets
a source-built and a cross-built release **of the same revision** replace each other and roll
back to each other instead of one being dismissed as already active. `~/.wasm-agent` is never
read, copied or written, and `wa setup` is never run.

**Honest limit:** a cross-built Android binary is verified on the desktop by hashes and by
its ELF machine, and on the phone by the same hash chain, the same ELF check, and the
installer's candidate probe (the new runtime is executed once against a scratch home before
it is switched in). That it really runs is proven only when it runs **on the phone**, which
is the coordinator's device step and not something this repository can claim from a
fixture. The fixture suite (`scripts/test-termux-bundle.sh`) exercises the hash chain, every
refusal above, the backup, the switch and the rollback with a fabricated ELF and announces
what it cannot represent on a non-Android host - 41 checks plus one announced host skip on a
Windows fixture host. One more limit is deliberate: `wa update` on
the phone still builds locally, so until the updater learns to fetch a bundle, a
bundle-installed node is updated by installing the next bundle.

### Keeping the preview current: `wa update`, and the one-time bootstrap

An installation that already carries `wa update` stays current with two commands
in Termux, and **nothing about your node state is recreated**:

```sh
wa update --check    # read-only: installed revision vs upstream; exits 0 when current
wa update            # fetch pinned revision -> build -> verify -> switch
wa update --rollback # back to the previous release, no network needed
```

The update fetches the exact resolved commit into a private staging directory,
builds the locked Rust workspace on the phone, verifies the candidate (manifest,
ELF machine, it runs), then switches and prints `updated <from> -> <to>` plus the
rollback path. It refuses rather than guessing: unknown installed revision, unknown
or unreachable upstream, a candidate that is not a descendant of what is installed,
a modified installation, a wrong-ABI candidate, a failed build, a concurrent update,
or an interrupted leftover release. **Preserved byte-for-byte** (and asserted with
sha256 before/after in the fixture suite): the node key/identity, `memory.db` and
history/sessions, bindings and grants, provider environment and credentials, the
workspace path, instructions and unrelated files. No state file is ever copied into
a release or staging area; `wa setup` is never re-run and no provider key is asked
for again.

An installation **older than this feature** has no working `wa update` by design.
Migrate it once, from a checkout in Termux:

```sh
cd ~ && git clone https://github.com/Magaav/wasm-agent.git wa-bootstrap
cd wa-bootstrap && git checkout main
bash scripts/install-termux.sh --adopt-existing
#   upstream_url_unknown -> the checkout has no remote; pass --upstream <git-url>
#   state_inside_install:<path> -> it refuses to move your state; fix the layout first
```

The one command above does this migration for you (`bootstrap.sh` picks it, and
defaults `--upstream` from the clone's own remote).
The bootstrap takes a verified byte-for-byte copy of the old installation as the
rollback release, builds the checked-out revision and switches it in; the checkout
itself is not installed into the runtime. If a switch is ever interrupted badly
enough that `wa` is gone, run `bash scripts/install-termux.sh --recover` from that
checkout. Restart the UI (`Ctrl-C`, then `wa ui`) to run the new runtime.

**Honest limit:** this is developed and fixture-tested on a non-Android host. A real
`pkg install rust` build, real ELF execution of the candidate, real `$PREFIX`
symlinks, a real rustc crash and the phone's actual `~/.wasm-agent` layout are **not**
proven here: the build ladder (`CARGO_BUILD_JOBS=1`, default codegen units, the raised
compiler stack and the debug rung), which rung's binary gets installed, and the refusal
are exercised by fixtures with a fake compiler, and the Windows fixture announces the
checks it skips (`WA_TERMUX_HOST_PROBES=0`, the symlink case). A debug rung install has
never been built on the phone either.

### Bind an existing CLI to the fabric

In `wa chat`, `/bind https://rendezvous.colmeio.com` inspects the managed service
and requests explicit 24-hour current-user-account automation consent. Compare
the pairing phrase on both consoles; an existing service administrator uses
`/nodes pending` and `/accept <code>`. Acceptance joins as guest; `/promote <id>`
and `/demote <id>` are separate confirmed network-role decisions, not fabric
administrator grants. `/unbind` locally revokes remote access; `/revoke <id>` is
the administrator's matching control. Identity, conversation and local provider
settings remain unchanged. Commands make no model call. Keep the CLI open for
outbound relay access; `wa bind run` is the explicit model-free foreground path.
Both runtime and rendezvous need the binding protocol; unavailable versions
refuse rather than falling back. See [binding/recovery limits](docs/BINDING.md).

### Model-free assisted onboarding

`scripts/bootstrap-windows.ps1` installs a checksum-pinned package in the background
while asking for the node name, then asks for explicit full-account automation
consent. It connects outbound through a **managed** rendezvous, without a model key.
`wa disconnect` revokes access; `wa connect` renews it; `wa access log` shows recent
operator activity. Consent defaults to 24 hours. No automatic Windows-login task is
installed: reconnect after logout when wanted.

An authorized operator can run `wa network role <node-id> master` (or `guest`).
Promotion does not automatically authorize that node to control other customers.

The public descriptor is served by the managed rendezvous after its package,
operator pins and service protocol pass the live gate. The current assisted-alpha
one-liner is:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://rendezvous.colmeio.com/releases/install.ps1)))
```

It installs in the background, asks for a node name, then requires explicit
`CONNECT` consent for broad Windows-account automation. The one-liner fails closed
when its descriptor is unavailable. [Managed onboarding](docs/ONBOARDING.md)
documents the service, publication and verification gates.

## Architecture

```text
                 Your agent / automation operator
                   identity · task · model access
                              │
                    Rust host + Lua agent core
                  tools · memory · evidence · policy
                              │
            ┌─────────────────┼────────────────────┐
       own computer      own remote nodes    customer guest nodes
                                            explicit authorization
```

This is the product direction; shared agent identity and customer authorization
are not all implemented. Today the runtime has node identities and per-node state.

| Part | Responsibility |
| --- | --- |
| `lua/core/` | Agent loop, prompt/context policy, tools, memory, sessions and node policy. |
| `rust/wa-host/` | Files, processes, HTTP/SSE, SQLite, cryptography, Lua and WASM execution. |
| `ui/` and `rust/wa-window/` | Conversation, evidence and control surfaces; Windows desktop shell. |
| `rust/wa-sentinel/` | External lifecycle supervision. |

The core currently runs as embedded Lua, **not** a WASI component. Plugins use a
small core-module ABI, not WIT/Component Model. Portability work remains on the
roadmap; it does not block proving the first useful customer journey.

## Development and verification

Read [AGENTS.md](AGENTS.md) before editing. It governs contributor worktrees,
commit provenance, testing and live-node safety; it is not an end-user identity.

```bash
bash scripts/test.sh
powershell -File scripts/test-ui.ps1
bash scripts/handoff.sh
```

Build from your own change branch. Deploy existing developer nodes only through
`scripts/deploy.sh` and the external sentinel procedure—never copy over a running
binary or restart someone else's session. Public candidate packaging does not
install or deploy anything.

Further reading: [architecture](ARCHITECTURE.md), [UI contract](DESIGN.md),
[host boundary](docs/HOST.md), [node fabric](docs/RENDEZVOUS.md),
[sentinel](docs/SENTINEL.md), [self-evolution](docs/EVOLUTION.md).

## License

MIT. Vendored Lua is MIT; see `rust/wa-host/vendor/lua`.
