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

> **Status: developer preview, not a public customer-ready release.** A Windows
> candidate builder, fresh installer, setup and diagnostics are available. Public
> distribution and live customer enrollment remain release gates. A model-free,
> consent-based managed guest bootstrap is under isolated verification; its public
> release descriptor stays disabled until the managed service and package are approved.

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
cd rust
cargo build --release --offline
cd ..
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

### Model-free assisted onboarding

`scripts/bootstrap-windows.ps1` installs a checksum-pinned package in the background
while asking for the node name, then asks for explicit full-account automation
consent. It connects outbound through a **managed** rendezvous, without a model key.
`wa disconnect` revokes access; `wa connect` renews it; `wa access log` shows recent
operator activity. Consent defaults to 24 hours. No automatic Windows-login task is
installed: reconnect after logout when wanted.

An authorized operator can run `wa network role <node-id> master` (or `guest`).
Promotion does not automatically authorize that node to control other customers.

The public descriptor is served by the managed rendezvous only after its package,
operator pins and service protocol pass the live gate. The one-liner fails closed
while that descriptor is unavailable. [Managed onboarding](docs/ONBOARDING.md)
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
