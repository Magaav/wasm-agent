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

## This is application isolation, not an OS sandbox

Two instances get different config, keys, databases and ports. That is **application-level home
isolation**. They run as the **same operating-system account**, so a guest node's process can still
read anything that account can read — the operator's files, its shell history, its other
databases. It is not a container, a virtual machine, a user account or a chroot, and it does not
claim that arbitrary file access is impossible. What it prevents is the *application* failure: a
second node silently loading the first node's config, sharing its key, or overwriting its database.

The isolation that *is* enforced at the process boundary is the launch environment: a named guest is
started with an explicit environment and cannot inherit the operator's provider credentials.

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
      "master": "0123456789abcdef0123456789abcdef",
      "shared_env": {},
      "created_at": 1790000000
    }
  }
}
```

The registry lives under the operator's home, not the instance home. It is captured before an
instance is selected, so selecting one cannot move the file that describes it.

**The registry is fail-closed.** A missing file is an empty registry; a file that cannot be read,
cannot be parsed, or carries an invalid schema or entry is an **error**, never an empty registry.
That matters because the next `add` would otherwise overwrite a file it could not read and silently
lose every instance in it. On load *and* before save, every entry is validated:

* `name` equals the registry key, `role` is `master` or `guest`;
* ports are non-zero and distinct, and neither a node nor a client port collides with any other
  instance's node **or** client port (cross-role collisions are rejected);
* a `guest` names a remote master that is a 32-hex **node id**, not a name or alias; a `master`
  names none;
* homes and installs are non-empty, do not overlap each other, and never own the operator's
  home, config or install;
* `shared_env` keys are well-formed and not protected (see below).

## Selecting an instance

`--instance NAME` selects an instance for the whole invocation; `WASM_AGENT_INSTANCE=NAME` does the
same for a supervisor that should always run as that instance. Selection sets
`WASM_AGENT_HOME`, `WASM_AGENT_PORT`, `WASM_AGENT_CLIENT_PORT`, `WA_INSTALL_DIR`, `WA_UI_DIR`,
`WASM_AGENT_NODE_ROLE` and `WASM_AGENT_TRUSTED_MASTERS`, which are the same variables every
existing path already derives from. The operator's own home and install are pinned *before* that
selection, so "the operator install" never becomes the selected instance's install.

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

`start`/`stop`/`status` accept the name positionally or through the already-selected
`--instance NAME`.

`add` refuses, before it writes anything:

* a duplicate name, or any port already claimed by another instance (node **or** client);
* a `--role guest` without a valid `--master` node id, or a `--master` on a master;
* a home or install that is a symlink, that is (or contains) the operator home/config/install, or
  that overlaps another instance's home/install;
* a home that already exists and is **not** an owned instance home (no marker), or that would
  overwrite a non-empty `env`/`config`;
* a `--share` of a protected key.

An owned instance home carries `<home>/.wasm-agent/instance.json` (schema, name, created_at). The
marker is what `remove --purge` requires, so a purge can never recursively delete a directory the
operator pointed at by hand. `remove --purge` also refuses a filesystem root, the operator's own
paths, and a running instance; it deletes the data first and only then forgets the instance, so a
failed delete leaves the registry entry in place and the failure visible rather than a silent
success.

## Protected environment shares

`--share KEY=VALUE` is the only way an environment variable crosses into a guest. Keys that decide
where a node reads and writes or what authority it has are **refused** (case-insensitively, because
Windows environment variables are): `HOME`/`USERPROFILE`/`HOMEDRIVE`/`HOMEPATH`, `PATH`/`PATHEXT`/
`COMSPEC`, `WASM_AGENT_HOME`, `WASM_AGENT_DB`, `WASM_AGENT_NODE_KEY`, `WASM_AGENT_NODE_ROLE`,
`WASM_AGENT_MANAGED`, `WASM_AGENT_INSTANCE`, `WASM_AGENT_PORT`, `WASM_AGENT_CLIENT_PORT`,
`WASM_AGENT_TRUSTED_MASTERS`, `WASM_AGENT_LUA_ROOT`, `WASM_AGENT_PLUGINS`, `WASM_AGENT_UI`,
`WA_INSTALL_DIR`, `WA_UI_DIR`, `WA_SCRIPT`. A key with `=`, a newline or a NUL is refused too.
Non-protected values such as `WASM_AGENT_RENDEZVOUS` may be shared explicitly.

The launch environment applies shares first and the instance's own variables **last**, so even a
share that somehow reached the map cannot override the boundary.

## Lifecycle records and identity proof

The sentinel writes `<instance-home>/.wasm-agent/sentinel/node.json` when it starts a node:

```json
{ "schema": 1, "pid": 12345, "node_id": "…", "home": "…", "binary": "…",
  "binary_sha256": "…", "started_at": 1790000000, "process_start": 134345010891011027 }
```

`serve.pid` is still written for the install tooling that reads it. The record is the stronger
proof, and **the sentinel refuses to stop a listener it cannot prove it started**:

1. the pid listening on the instance port must equal the recorded pid;
2. the recorded `home` must be the selected instance's home, and the recorded `binary` must be the
   installed node;
3. the process creation time must equal `process_start` (a recycled pid has a different one);
4. the process image must be the recorded binary;
5. on graceful maintenance, the node's own `/sync/head` must announce the recorded `node_id`.

A record that exists but is unreadable, unparseable, or missing a required field (`schema`, `pid`,
`node_id`, `home`, `binary`, `process_start`) is an **error**: the sentinel refuses rather than
falling back to the weaker `serve.pid` path. `start` will not leave a node running if it could not
write a verifiable record or read the creation marker; it stops the child and reports.

**Legacy adoption.** A node started outside the sentinel (by `upgrade.sh`, which writes only
`serve.pid`) has no record. On a graceful stop the sentinel may adopt it, but only with positive
proof: `serve.pid` names the listener, the image is the installed node, the creation marker is
readable, the home's own key derives an expected node id, and the live node announces exactly that
id. The record is written **before** the stop, so the marker is saved while the process is alive.
`recover` is an explicit interruption of a possibly wedged node and does not probe identity, so a
legacy node with no record is **refused** rather than killed on a port alone.

Starting on an occupied port is refused before a process is spawned.

## Idle before maintenance

A verb that replaces the node waits for idle, and idle is a **positive** proof from `/health`:
`ok` is true, `current` is null, `queue` is zero, no operation is overdue, every `workers[]` entry
is a well-formed object whose `state` is `alive`. Every one of those fields is **required**: a body
missing any of them is ambiguous, not idle.

Active **operations** are read from the `operations[]` array, not only from `operation_overdue`:
a background command can outlive the run that launched it, and `operation_overdue` flags only the
tardy ones. Any entry that is not settled, or is overdue, or has `cleanup: "unknown"`, is busy. A
settled entry is idle only when its `state` is a known terminal one (`done`, `cancelled`, `failed`,
`exited`, `completed`, `ok`); a settled state this sentinel does not know is ambiguous. The live
array omits `settled` (it lists only unsettled entries), so an absent marker means busy. A
malformed entry — not an object, no `state`, a non-boolean `settled` — is ambiguous.

The runtime's execution summary is read strictly. `health.execution_schema` declares the schema;
schema 1 **requires** both `health.operations` and `health.subagents`, the latter an object
`{queued, running, active}` with `active == queued + running`, where a non-zero `active` means busy.
A legacy body may omit both. Any other `execution_schema` is one this sentinel cannot read, so it is
ambiguous. A `subagents` field that is present in any other shape — a scalar, an array, a partial or
contradictory object — is ambiguous. Any `runs[]` entry with `pending > 0` or a busy state is work.
Ambiguous health holds graceful maintenance rather than being read as idle. A node that is down has
nothing to interrupt, so `restart` may still start it.

## Guest environment

A guest node is a device a remote master runs tool calls on; it needs no local model and must not
inherit the operator's provider credentials. A named guest is launched with an **explicit
environment**: a small system allowlist, non-protected `shared_env` entries the operator declared,
and the instance variables the sentinel owns. Secrets in the supervisor's environment are absent by
construction, not by a filter that could miss one. The default/master path inherits as it always
did, with the instance variables overridden. A guest home is created empty, so it cannot silently
load the operator's `config` or `env`.

Again: this is application isolation. The guest process runs as the same OS account and can read
the operator's files; it does not get the operator's *node configuration* by accident.

## Tests

`scripts/test-node-instances.sh` starts an operator node and a guest node from the built binaries
(no model, no rendezvous) and asserts: separate homes/keys/databases/ports/records; port collisions
(node-vs-node, node-vs-client) and home collisions refused; a nonempty foreign home never
overwritten; a protected share refused and a smuggled registry entry never spawned; the guest cannot
read the operator's sessions or memory; stopping or restarting the operator leaves the guest
untouched; a foreign listener, a corrupt record, a forged legacy pid and a wrong-home/forged-id/
stale-marker record are refused without killing the node; a proven legacy node is adopted; a corrupt
registry is an error and is left byte-for-byte unchanged; and `remove --purge` refuses an unowned
home. It is wired into `scripts/test.sh`; the unit tests in `rust/wa-sentinel/src/instance.rs`
cover the registry validation, the guest environment, path collisions, the lifecycle record and the
idle contract.
