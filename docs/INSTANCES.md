# Node instances

One machine can run more than one `wasm-agent` node. That is not a convenience: it is the only way
to exercise the failures that live *between* nodes — an operator's own master node beside a guest
node that belongs to another master, each with its own identity, state and port. Before this, a
machine had one implicit node: one `~/.wasm-agent`, one `node.key`, one `memory.db`, one port. A
second `wa serve` would share the key, overwrite the first node's rendezvous registration, and its
stop would kill whichever process happened to hold the port.

An **instance** is a named bundle of everything that must not be shared:

| Concern | Default instance | Named instance |
| --- | --- | --- |
| state home (`WASM_AGENT_HOME`) | the operator's home | its own directory |
| identity (`node.key`) | `<home>/.wasm-agent/node.key` | its own key |
| memory (`memory.db`) | `<home>/.wasm-agent/memory.db` | its own database |
| provider/config (`config`, `env`) | the operator's | its own; never the operator's |
| node port / client-bridge port | `8799` / `8800` | its own pair |
| install (`WA_INSTALL_DIR`) | the machine install | its own binary + `ui/` + `serve.pid` |
| supervisor state | `<home>/.wasm-agent/sentinel` | its own requests, log, pid, records |
| role | `master` | `master` or `guest` |
| remote master | — | a guest's explicit binding |

## The registry

The operator-level registry is `<base>/.wasm-agent/instances.json`, where `<base>` is the ambient
home (`WA_INSTANCE_BASE_HOME`, else `WASM_AGENT_HOME`, else the platform home). Override the file
with `WA_INSTANCE_REGISTRY`. It is schema 1:

```json
{
  "schema": 1,
  "instances": {
    "guest-bob": {
      "name": "guest-bob",
      "home": "C:/Users/op/.wasm-agent/instances/guest-bob",
      "install_dir": "C:/Users/op/.wasm-agent/instances/guest-bob/install",
      "node_port": 8801,
      "client_port": 8802,
      "role": "guest",
      "master": "<remote master node id>",
      "shared_env": {},
      "created_at": 1790000000
    }
  }
}
```

The registry lives under the operator's home, not the instance home. It is captured before an
instance is selected, so selecting one cannot move the file that describes it.

## Selecting an instance

`--instance NAME` selects an instance for the whole invocation; `WASM_AGENT_INSTANCE=NAME` does the
same for a supervisor that should always run as that instance. Selection sets
`WASM_AGENT_HOME`, `WASM_AGENT_PORT`, `WASM_AGENT_CLIENT_PORT`, `WA_INSTALL_DIR`, `WA_UI_DIR`,
`WASM_AGENT_NODE_ROLE` and `WASM_AGENT_TRUSTED_MASTERS`, which are the same variables every
existing path already derives from.

With no name, the ambient/default node is used exactly as before. **A single-node machine needs no
registry and sees no behaviour change.**

## Setup and lifecycle

```
wa-sentinel instance add <name> --port N --client-port N
                                [--role master|guest] [--master <node-id>]
                                [--home PATH] [--install-dir PATH]
                                [--binary PATH] [--ui PATH]
                                [--share KEY=VALUE]...
wa-sentinel instance list
wa-sentinel instance show <name>
wa-sentinel instance remove <name> [--purge]
wa-sentinel instance start <name>      # start (or restart) through the sentinel
wa-sentinel instance stop <name>       # verified stop
wa-sentinel instance status <name>
```

`add` refuses a name that already exists, a node or client port already claimed by another
instance, and a `--role guest` without `--master`. A guest's remote master is explicit: role is a
security boundary, never inferred from a display name. `--binary`/`--ui` install a private copy of
the node into the instance's install directory; `--share KEY=VALUE` is the only way an environment
variable crosses into a guest (see below).

`start`/`stop`/`status` accept the name positionally or through the already-selected
`--instance NAME`.

## Lifecycle records and identity proof

The sentinel writes `<instance-home>/.wasm-agent/sentinel/node.json` when it starts a node:

```json
{ "schema": 1, "pid": 12345, "node_id": "…", "home": "…", "binary": "…",
  "binary_sha256": "…", "started_at": 1790000000, "process_start": 134345010891011027 }
```

`serve.pid` is still written for the install tooling that reads it. The record is the stronger
proof, and **the sentinel refuses to stop a listener it cannot prove it started**:

1. the pid listening on the instance port must equal the recorded pid;
2. the process creation time must equal `process_start` (a recycled pid has a different one);
3. the process image must be the recorded binary;
4. on graceful maintenance, the node's own `/sync/head` must announce the recorded `node_id`.

`recover` is an explicit interruption, so it does not require the identity probe a wedged node may
be unable to answer — but it still proves the pid, creation time and image. A node started outside
the sentinel (only `serve.pid` exists) is proven by pid plus installed image; if neither a record
nor `serve.pid` exists, the stop is refused rather than performed on a port alone. Starting on an
occupied port is refused before a process is spawned.

## Idle before maintenance

A verb that replaces the node waits for idle, and idle is a **positive** proof from `/health`:
`ok` is true, `current` is null, `queue` is zero, no operation is overdue, every `workers[]` entry
is `alive`, and no `subagents` entry is accepted/running (read when the runtime reports it). A
body that is missing a required field is **ambiguous**, and ambiguous health holds graceful
maintenance rather than being read as idle. A node that is down has nothing to interrupt, so
`restart` may still start it.

## Guest environment

A guest node is a device a remote master runs tool calls on; it needs no local model and must not
inherit the operator's provider credentials. It is launched with an **explicit environment**:
a small system allowlist, the instance variables the sentinel owns, and `shared_env` entries the
operator declared. Secrets in the supervisor's environment are absent by construction, not by a
filter that could miss one. The default/master path inherits as it always did, with the instance
variables overridden. A guest home is created empty, so it cannot silently load the operator's
`config` or `env`.

## Tests

`scripts/test-node-instances.sh` starts an operator node and a guest node from the built binaries
(no model, no rendezvous) and asserts: separate homes/keys/databases/ports/records; port collision
refused at add and at start; the guest cannot read the operator's sessions or memory; stopping or
restarting the operator leaves the guest untouched; and a foreign listener on an instance port is
refused. It is wired into `scripts/test.sh`; the unit tests in
`rust/wa-sentinel/src/instance.rs` cover the guest environment, registry collisions and the idle
contract.
