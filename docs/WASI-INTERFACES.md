# WASI interfaces — every one a component may reach, its tier, and its grant

What a `wa:kernel@0.2` component (WASI 0.3, native async) can import from WASI, and what it costs to
get it. The code is `rust/wa-kernel-runtime/src/wasi_grants.rs`; **this table and that file's `TABLE`
constant are kept in step by a test** (`wasi_grants::tests::the_document_lists_every_interface_the_code_knows`),
so an interface cannot be granted in one place and documented in another. Context:
[KERNEL.md](KERNEL.md) (the runners), [GRANT-POLICY.md](GRANT-POLICY.md) (the two layers),
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md) (what a long-lived component is).

## The three tiers

| tier | meaning | who may turn it on |
| --- | --- | --- |
| **A** | always linked, no grant key | nobody has to: nothing outside the component is reachable through it |
| **B** | linked only with a grant and a scope | the manifest declares it, the node policy allows it, one audit record per decision |
| **C** | never linked, to any component | nobody: a component importing it is refused with the interface named |

One asymmetry has a row of its own in the table: `wasi:cli/environment` and `wasi:cli/stdin` are tier B
at `@0.3.0` and **always linked** at `@0.2.x`. The reason is the toolchain, not the policy: a component
built with Rust's `std` - which is every `wasm32-wasip2` build, including all of this repo's fixtures -
imports the whole preview-2 cli surface (`environment`, `stdin`, `stdout`, `exit`, the terminals)
whether or not the program uses it. Refusing the 0.2 import would refuse a component for an import it
never calls. The preview-2 spelling therefore carries **no capability**: with no grant the environment
list is empty and stdin is an empty pipe (EOF). A component built against WASI 0.3 names these
interfaces in its own world, deliberately, and gets the strict answer.

Tier A is `wasmtime`'s default set and the reason `docs/GRANT-POLICY.md` step 4 says log and
lifecycle are never policy-checked: a clock, a random byte, a line on the component's own log. A
component cannot signal another process, read a file, or open a socket with them.

Tier B is everything that reaches outside the component. Every tier B decision is **sensitive** on
the policy side (`rust/wa-grant-policy`, `DEFAULT_SENSITIVE`), which has two consequences an operator
should know before upgrading: on a node **with** a `policy.json`, a tier B interface a component was
granted still needs a rule, or the interface is refused with `no_policy`; on a node **without** one
(manifest mode) the manifest grant is the only gate and every decision is still audited.

Tier C is the list of things this node does not hand a component, whatever its artifact asks for.
There is no grant key to write, and no rule that can turn one on.

## The table

`manifest key` is the key under `capabilities` in the component's manifest (an array of names/addresses,
or `true` for a boolean capability). `policy capability` is what the decision is recorded under in the
audit trail. `served` says whether `wasmtime` 50 can link it at all today; `no` is a documented gap,
refused with `wasi_import_interface_unavailable` (for a `wasi:` package this node has no row for:
`wasi_import_interface_unknown`).

| interface | tier | manifest key | policy capability | served | note |
| --- | --- | --- | --- | --- | --- |
| `wasi:clocks/monotonic-clock` | A | - | - | yes | elapsed time and timers; a component's only clock |
| `wasi:clocks/system-clock` | A | - | - | yes | wall clock; the 0.2 spelling is `wall-clock` |
| `wasi:clocks/wall-clock` | A | - | - | yes | the preview-2 spelling of the wall clock (0.3 renamed it `system-clock`) |
| `wasi:clocks/types` | A | - | - | yes | duration/instant records the other clocks and sockets use |
| `wasi:random/random` | A | - | - | yes | the OS CSPRNG |
| `wasi:random/insecure` | A | - | - | yes | the non-cryptographic PRNG |
| `wasi:random/insecure-seed` | A | - | - | yes | a seed for the above; never a secret |
| `wasi:cli/exit` | A | - | - | yes | a component's own exit; the supervisor decides whether it restarts |
| `wasi:cli/stdout` | A | - | - | yes | the component's service log, never the node's console |
| `wasi:cli/stderr` | A | - | - | yes | as stdout: the same log file |
| `wasi:cli/terminal-input` | A | - | - | yes | a capability query; the host answers `false` |
| `wasi:cli/terminal-output` | A | - | - | yes | a capability query; the host answers `false` |
| `wasi:cli/terminal-stdin` | A | - | - | yes | a capability query over stdin; graded with terminal-input |
| `wasi:cli/terminal-stdout` | A | - | - | yes | a capability query over stdout; graded with terminal-output |
| `wasi:cli/terminal-stderr` | A | - | - | yes | a capability query over stderr; graded with terminal-output |
| `wasi:cli/types` | A | - | - | yes | the `error-code` record the 0.3 cli streams report |
| `wasi:io/error` | A | - | - | yes | a resource handle for an error another interface produced |
| `wasi:io/poll` | A | - | - | yes | preview 2 polling; only reachable through a resource another interface made |
| `wasi:io/streams` | A | - | - | yes | preview 2 streams; only reachable through a resource another interface made |
| `wasi:filesystem/types` | B | `dirs` | `wasi.filesystem` | yes | named preopens only, read-only unless the preopen is granted write |
| `wasi:filesystem/preopens` | B | `dirs` | `wasi.filesystem` | yes | the list is exactly the granted preopens; never `/` and never the node home |
| `wasi:sockets/types` | B | `net` | `wasi.sockets` | yes | outbound host:port allowlist; inbound only on 127.0.0.1 unless `net_bind` names the address |
| `wasi:sockets/ip-name-lookup` | B | `dns` | `wasi.sockets` | yes | a name lookup is an outbound request; its own `dns` grant |
| `wasi:sockets/network` | B | `net` | `wasi.sockets` | yes | preview 2's network handle, under the same address check |
| `wasi:sockets/instance-network` | B | `net` | `wasi.sockets` | yes | preview 2's default network, under the same address check |
| `wasi:sockets/tcp` | B | `net` | `wasi.sockets` | yes | preview 2 TCP, under the same address check |
| `wasi:sockets/tcp-create-socket` | B | `net` | `wasi.sockets` | yes | preview 2 socket creation, under the same address check |
| `wasi:sockets/udp` | B | `net` | `wasi.sockets` | yes | preview 2 UDP, under the same address check |
| `wasi:sockets/udp-create-socket` | B | `net` | `wasi.sockets` | yes | preview 2 socket creation, under the same address check |
| `wasi:cli/environment` | B | `env` | `wasi.env` | yes | only the variable names the grant lists; never the node's environment - and the 0.2.x spelling is linked for every component (std imports it) with an empty list when nothing is granted |
| `wasi:cli/stdin` | B | `stdin` | `wasi.stdin` | yes | an empty pipe, never the node's own stdin - and the 0.2.x spelling is linked for every component (std imports it) as an empty pipe |
| `wa:kernel/keyvalue` | B | `storage` | `wasi.keyvalue` | yes | wa's `wasi:keyvalue` shape over this component's own kv namespace |
| `wa:kernel/config` | B | `config` | `wasi.config` | yes | wa's `wasi:config` shape over the non-secret config this component was granted |
| `wasi:http/types` | B | `http` | `http.request` | no | no wasi:http crate ships with wasmtime 50; outgoing HTTP is `wa:kernel/http`, gated per host:port |
| `wasi:http/outgoing-handler` | B | `http` | `http.request` | no | as wasi:http/types: use `wa:kernel/http` |
| `wasi:keyvalue/store` | B | `storage` | `wasi.keyvalue` | no | the proposal itself is not shipped by wasmtime 50; `wa:kernel/keyvalue` is the served shape |
| `wasi:config/store` | B | `config` | `wasi.config` | no | the proposal itself is not shipped by wasmtime 50; `wa:kernel/config` is the served shape |
| `wasi:nn/inference` | B | `nn` | `nn.run` | no | wasmtime-wasi-nn has no 50 release: not linkable, so a component importing it waits |
| `wasi:tls/*` | C | - | - | no | TLS terminates in the kernel; a component never holds a key or makes a trust decision |
| `wasi:vault/*` | C | - | - | no | credential values reach a component only through `wa:kernel/credentials.get`, one named secret per grant |
| `wasi:secrets/*` | C | - | - | no | as wasi:vault |
| `wasi:logging/logging` | C | - | - | no | `wa:kernel/log` is the one log a component may write, into its own bounded file |
| `wa:host/policy` | C | - | - | no | node policy is the operator's: `host.policy_*` is not reachable from a component |
| `wa:host/deploy` | C | - | - | no | deploy/upgrade belongs to Sentinel and to the operator's session |
| `wa:host/mesh` | C | - | - | no | a mesh call upward is the node's, never a component's |
| `wa:host/client` | C | - | - | no | machine control (the `client` machine actions) is the operator's |
| `wa:host/exec` | C | - | - | no | shell and operation are the operator's session, not a component's |

### What wasmtime 50 actually ships

Checked against the crates in `rust/Cargo.lock`, not against the proposals: `wasmtime-wasi` 50.0.1
with its `p3` feature implements `wasi:cli`, `wasi:clocks`, `wasi:filesystem`, `wasi:random` and
`wasi:sockets` at `@0.3.0` (the interfaces above), and `wasi:cli`, `wasi:clocks`, `wasi:filesystem`,
`wasi:random`, `wasi:sockets` plus `wasi:io` at `@0.2.0`. It ships **no** `wasi:http` (neither
version: `p2`'s HTTP world was removed with the crate split and no `wasmtime-wasi-http` is in the
lock), no `wasi:keyvalue`, no `wasi:config`, no `wasi:tls` and no `wasi:logging`. `wasmtime-wasi-nn`
exists only at 37.0.3 (preview 2), which is a different runtime than this runner.

That is why the table has three different answers for "the job asked for it": `http`, keyvalue and
config are **served by wa** (`wa:kernel/http`, `wa:kernel/keyvalue`, `wa:kernel/config`) so the
capability exists with a different package name; `nn` is **not available** at all on this runtime; and
the proposal packages a component might import (`wasi:keyvalue/store`, `wasi:config/store`,
`wasi:http/*`) are refused by name instead of being silently absent.

## Scope, per tier B interface

**Filesystem** — `capabilities.dirs: ["/data"]` in the manifest, and the grant request names the host
directory: `{"dirs": [{"host": "/srv/wa/data", "guest": "/data", "write": false}]}`. Rules:

* Only the listed directories exist for the component; `wasi:filesystem/preopens` returns exactly
  them. There is no `/`, no `C:/`, no node home, no state root, no component directory: a host path
  that *is* one of those, or that contains one, is refused at grant time (`filesystem_root`,
  `node_home`, `state_root`, `component_dir`) and audited under `wasi.filesystem`.
* `write: false` (the default) preopens read-only; a write open is `not-permitted`.
* `..` and absolute paths inside the preopen are refused by the preopen's own confinement
  (`wasmtime`'s `cap-std`-style resolution): `open-at("../escape.txt")` fails `not-permitted`, and the
  file outside is never touched. The grant also refuses a guest path containing `..`.
* Audit: one record per preopen per run. The per-path escape is enforced by confinement and appears
  as the guest's error, not as a policy record - a *named gap*: the host never sees the path string.

**Sockets** — `capabilities.net: ["127.0.0.1:*"]` in the manifest, the grant names the exact
addresses: `{"net": ["127.0.0.1:8080"]}` (a `host:*` port wildcard is allowed in the manifest
declaration, never in the grant). `wasi:sockets` is linked only when at least one address survives.

* Every connect/bind/listen/datagram goes through `wasmtime`'s socket address check, which this
  module installs: outbound is allowed only for an address in the grant (`host:port`, `*.suffix:port`
  or `host:*`) **and** a `net.dial` policy allow; anything else is `access-denied` to the guest.
* Inbound: only loopback, and only on a granted port (or an ephemeral one), unless the manifest names
  the exact address in `capabilities.net_bind` - a non-loopback bind has to be asked for twice, in
  the artifact and in the policy (`net.bind`). A bound listener's accepted clients
  (`TcpAccept`/`UdpReceive`) are not re-checked: the bind already was.
* UDP rides on the same grant unless the manifest says `"udp": false`.
* DNS (`wasi:sockets/ip-name-lookup`) needs `"dns": true`, separately: a name lookup is an outbound
  request to the node's resolver, not a lookup in the grant.
* Audit: `wasi.sockets` per granted address at start, `net.dial`/`net.bind` per address at call time.

**Environment** — `capabilities.env: ["WA_MODE"]` in the manifest, the grant maps guest name to host
name: `{"env": {"WA_MODE": "WA_MODE"}}`. Only those names exist in the component's environment; the
node's own environment is never inherited, and a name the policy denies is dropped (audited
`wasi.env` per name). The value is read from the node's environment at start.

**stdin** — `"stdin": true`. The component gets an empty pipe, never the node's own stdin; a service
is not a terminal, and handing it the operator's input would be a capability nobody granted.

**keyvalue** — `"storage": true`. Same namespace as `wa:kernel/kv` (keys are UTF-8 strings on the
same bytes), same `__wa/` guard, same `kv.read`/`kv.write` rules and audit. A component cannot use
one spelling to reach what the other cannot.

**config** — `"config": true` and a `config` object in the grant. The component reads the non-secret
data the operator wrote; every read is `config.read`, which is *not* sensitive by default (it is the
component's own configuration) but is auditable and refusable.

## Decision order and refusals

For one run (`service_components_v2::run_once`):

1. `Scope::build` — manifest first, then policy, one audit record per scope element. A host path that
   may never be preopened is refused before either (`record_deny` with its own reason word).
2. `check_imports` — every `wasi:` import of the artifact, in the order the artifact wrote them. The
   first one the scope does not grant refuses the whole start, so a component never runs half-served.
   The outcome is `wasi_import_<reason>:<interface>`, which the supervisor records as `last_exit` and
   the component's log shows; at install/supervise time the same import is reported as
   `waiting for <interface>` (`imports.rs`), because a tier C interface is not "served" at all.
3. `wasi_grants::link` — tier A always, tier B per plan, tier C never.
4. The component runs; call-time checks (`net.dial`, `net.bind`, `kv.read`, `kv.write`, `config.read`)
   charge their own capabilities exactly as the `wa:kernel` path does.

Reason words (`docs/GRANT-POLICY.md` keeps the vocabulary): `manifest_not_declared`,
`invalid_address`, `filesystem_root`, `node_home`, `state_root`, `component_dir`, `not_absolute`,
`relative_segments`, `import_not_granted`, `interface_never_served`, `interface_unavailable`,
`interface_unknown`, plus the policy's own (`no_policy`, `target_not_allowed`, `policy_denied`, …).

## What is deliberately not here

* **No whole-environment, whole-filesystem, whole-network grant.** There is no `"env": true`, no
  `"dirs": ["/"]`, no `"net": ["0.0.0.0/0"]`. The grant is a list of names, directories and
  `host:port` pairs, and a request for `/` or for the node home is refused, not narrowed silently.
* **No per-call filesystem policy.** The preopen's confinement decides, and the decision is audited
  once per run. A per-path rule would need the host to see each `open-at` path, which would mean
  re-implementing `wasi:filesystem` (600 lines of WIT, one resource with 40 methods) - named as a
  gap rather than half-done.
* **No `wasi:nn`.** There is no `wasmtime-nn` for wasmtime 50, so there is nothing to apply a model
  allowlist or a memory cap to. When a 0.3 `wasmtime-nn` exists, the row is already tier B with
  `nn.run` and `capabilities.nn`.
* **No tier C escape hatch.** Node policy, credential values, deploy/upgrade, mesh calls upward,
  machine control and shell are not reachable from a component by any spelling this node links; the
  Lua surface (`host.*`) is not a WASI import and is never linked into a component.
