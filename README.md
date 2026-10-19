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
