# Feature switches: which path a node runs, and why

A **feature** is one part of the node that has two implementations: a WASI component and the native
path that was there before it. Since 08/11 every feature is **on by default** — the components are
built, pinned and shipped, so a node that has them runs them — and each one has its own live off switch:
one line in `policy.json`, no restart. Victor, 08/11: *"turn every component on, every evolution we did
on"*, *"each with a live per-feature off switch"*.

This page is the rule, the table and the surfaces. The components themselves are
[COMPONENTS.md](COMPONENTS.md); the install is [RELEASE-UPDATE.md](RELEASE-UPDATE.md).

## The finding this exists for

`components.lock` pinned `graph` alone until 08/11. agent-core, codemode, hooks, memory,
model-gateway, selfloop, telemetry-sink and wa-email were built and tested, and **never shipped**, so
their `WA_*_COMPONENT` flags had nothing to turn on: the gate fell back to the native path and the node
looked like it ran a component it did not have. Two things were wrong and both are fixed here:

* the deploy installs **every** component the lock pins (not a name written into `deploy.sh`), and
* a feature that is on with no component behind it is **reported by name** (`component_missing`) instead
  of falling back silently.

**Installed is not enabled — but enabled is the default.** A deploy installs the whole set, and since
08/11 a feature that is installed and verified is also *active* unless the node's policy turns it off.
The distinction still matters, and it is the one a broken install hits: enabled with nothing installed
is `component_missing`, reported, running native.

## The rule

```text
enabled := env override, else policy.json `features.<id>`, else true   (DEFAULT_ENABLED)
active  := "component"  when enabled AND the component is installed with a verified pin
           "native"     otherwise, with the reason
```

| input | wins over | how it is written |
| --- | --- | --- |
| env flag | the policy file | `WA_MEMORY_COMPONENT=1` / `=0` (`1/true/on/yes`, `0/false/off/no`) |
| `policy.json` `features.<id>` | the default | `"memory": false` (the off switch) |
| default | — | **on**, `source: default`, `reason: default_on` |

**Turning one off is the whole of the off switch.** Write `"memory": false` under `features` in the
node's `policy.json` and the next call takes the native path (`source: policy`, `reason: feature_off`);
write `true` again and it goes back. `WA_MEMORY_COMPONENT=0` does the same for one process. Nothing is
cached across a change, so a running node follows the file within `WA_FEATURES_WATCH_MS` (one second),
which is the property `scripts/test-features-gate.lua` proves on the same loaded module.

* **One resolver.** `rust/wa-features` (crate `wa-features`) is the only code that answers. The Lua
  gates reach it through `lua/core/features.lua` → `host.features`, the CLI through `wa features`, and
  a service through `services {"action":"features"}`. Two surfaces cannot disagree about a node.
* **The policy file is read live.** One `stat` per `WA_FEATURES_WATCH_MS` (default 1000), a parse only
  when the file moved. Turning a feature on or off is an edit to a file, never a restart - the gates ask
  per call, not once at load (`scripts/test-features-gate.lua` proves exactly that).
* **A typo is refused, not guessed.** `WA_MEMORY_COMPONENT=y` is `feature_env_invalid`, the component
  does not answer, and the native path runs: an unreadable statement about a component is not permission
  to start one. It does not fall through to the policy either (that would make a typo mean "whatever the
  file says"). `"gateway": "yes"` is `feature_value_invalid`, same answer. A `features` member that is
  not an object, or a policy file that does not parse, is `features_unreadable:<why>` on every feature —
  and, because the default is on, the feature keeps running its component: the file's *rules* still gate
  every sensitive capability, so the safe direction for a half-written file is "the shipped default",
  not "turn the node's features off".
* **A refusal is never a silent fallback.** `enabled: true, active: "native", reason:
  "component_missing"` is the answer for "the operator asked for it and it is not there"; the gate logs
  one line per (operation, reason) the first time it falls back, and `wa features` exits 3.

The file is the grant policy's own file (`WA_GRANT_POLICY`, else `<state>/policy.json`): one place for
"what this node may do" and "what this node routes". `WA_FEATURES_FILE` points the resolver at another
file (a test, or a node that keeps the switches apart).

```json
{
  "version": 1,
  "sensitive_capabilities": [],
  "features": {
    "selfloop": true, "codemode": true, "hooks": true, "memory": true,
    "gateway": true, "mesh_component": true, "agent_core": true, "telemetry_sink": true
  },
  "components": { }
}
```

`policies/default.json` ships the section with every feature `true`, so the file a deploy installs says
what the node routes; a key a node's file lacks is the default (**on**), so an older node reads a newer
policy without failing, and a newer node reads an older policy without inventing a switch. To turn one
feature off, set its key to `false` and leave the rest alone.

The `features` section rides in the same file as the capability rules, and the grant policy that reads
those rules *carries* it: one `policy.json` with rules, `features`, `mesh`, `vault` and `models` in it
parses for every reader, and a section one reader does not know can never make another reader's rules
unreadable (`docs/GRANT-POLICY.md`, "Sections this crate does not read" — the 08/11 incident).

## The features

| id | component | env | native path | gate |
| --- | --- | --- | --- | --- |
| `selfloop` | `selfloop` | `WA_SELFLOOP_COMPONENT` | `lua/core/selfloop.lua` | routes per call (`M.tick`, notes, plan, claim, settle) |
| `codemode` | `codemode` | `WA_CODEMODE_COMPONENT` | `lua/core/codemode.lua` | routes per script |
| `hooks` | `hooks` | `WA_HOOKS_COMPONENT` | `lua/core/hooks.lua` | routes per decision |
| `memory` | `memory` | `WA_MEMORY_COMPONENT` | `lua/core/memory.lua` | routes per operation |
| `gateway` | `model-gateway` | `WA_MODEL_GATEWAY_COMPONENT` | `rust/wa-model-gateway` | **resolved, not yet wired** |
| `mesh_component` | `mesh` | `WA_MESH_COMPONENT` | `rust/wa-mesh` | **resolved, not yet wired** (no `mesh` component is built) |
| `agent_core` | `agent-core` | `WA_AGENT_CORE_COMPONENT` | the node's own core | **resolved, not yet wired** (`WA_AGENT_CORE_WASM` still selects the artifact) |
| `telemetry_sink` | `telemetry-sink` | `WA_TELEMETRY_SINK_COMPONENT` | `rust/wa-telemetry-sink` | **resolved, not yet wired** |

The four Lua seams are the ones that were wired when the resolver landed. The last four are shipped,
pinned and answerable - `wa features` reports them truthfully - but the call path that would use them
still runs natively. **Do not enable one and believe the path changed**: until the gate is wired, `active`
can read `component` while the native code runs. Wiring one is a change to that call path plus its
parity test; the resolver needs no change.

### Enabling a shipped component needs a policy rule

A component's sensitive capabilities are still the grant policy's business (`docs/GRANT-POLICY.md`): with
a policy file present, a sensitive capability with no rule is refused with `no_policy`, so enabling
`gateway` (which dials `api.anthropic.com:443` and friends) or `wa-email` (its `kv.write`) without a rule
gets refusals, not traffic. The deploy already prints the installed components the node's policy file
does not name (`policy_unlisted_components`), and that warning is now about the shipped set. Adding a
rule can only narrow what the manifest declared.

## The surfaces

```
wa features             one line per feature: installed sha, enabled, source, active path, reason
                        plus the mesh's own switch (`mesh: on (default: roster verified)`, docs/MESH.md)
wa features --json      the same as data: {"ok":true,"policy":"…","features":[…],"policy_error":…}
```

`wa features` answers before the interpreter boots (like `wa --capability-digest`), so it works on a node
whose core will not start, and it needs no model, no ledger and no network. **Exit status 3** means at
least one feature is enabled and running natively - a script that turns a feature on can check that it
got the path it asked for. The whole table is also `host.features()`; one feature is
`host.features({"feature":"memory"})` → `{"ok":true,"feature":{…}}`; an unknown name is
`{"ok":false,"error":"unknown_feature:<id>"}`, never a silent `false`.

```
services {"action":"features"}      the same document, for a caller that already has the host
```

## Where the wiring lives

| what | file |
| --- | --- |
| the rule, the pin check, the live file, the JSON | `rust/wa-features/src/lib.rs` (+ `tests.rs`) |
| the Lua door every gate asks | `lua/core/features.lua` |
| the gates | `lua/core/{selfloop,codemode,hooks,memory}.lua` |
| the capability | `rust/wa-capabilities/src/features.rs`, registered in `capabilities.rs`, documented in `HOST.md` |
| `services features` | `rust/wa-kernel-runtime/src/services.rs` |
| `wa features` | `rust/wa-host/src/main.rs` |
| the installed set | `components.lock`, `scripts/lib/deploy-components.sh`, `scripts/deploy.sh` step 3e |

A gate asks like this, at every route, and never caches the answer:

```lua
local features = dofile('lua/core/features.lua')
local active, reason = features.seam('memory')   -- true|false, 'active_component'|'seam_disabled'|'component_missing'|…
if not active then return nil, reason end        -- the caller reports the reason, once per operation
```

`seam_disabled` means "the feature is off": the native path *is* the off state and there is nothing to
report. Anything else is a node that asked for a component and did not get it, and it is logged.

## Tests

| test | proves |
| --- | --- |
| `cargo test -p wa-features` (14 tests) | the rule and every reason, the pin check, the live file, the wire shape, `policies/default.json` naming every feature as `false` |
| `scripts/test-features-gate.lua` (32 checks) | a `policy.json` edit switches the SAME loaded `lua/core/memory.lua` instance to the component and back, within one watch interval, with no restart; `component_missing` with the component removed; the Lua env table agrees with the resolver |
| `scripts/test-deploy-components-shipped.sh` (48 checks) | `components.lock` pins the production set and no fixture; the real set staged+installed+rolled back from a local bundle when this checkout has the artifacts; the fixture lock's install/rollback/refusal mechanics; `scripts/deploy.sh` takes its names from the lock |
| `scripts/test-{memory,selfloop,hooks}-component.lua` | native/component parity with the seam routed by the module's test seam (`M.seam_override`) |
| `scripts/test-features-defaults.lua` (60 checks) | with no policy file and no env: all eight features `enabled`/`source: default`; installed+verified is `active: component`, absent is `component_missing` (item 5); one `false` turns one off and leaves seven on; all eight switch off and back on in one process; the mesh switch is in the same answer |
| `scripts/test-serve-turn-all-on.sh` | one scripted `wa serve` turn end to end with every feature at its default (temp home, no rendezvous/relay, loopback stub model): `wa features` says 8/8 enabled, `/health` 200, the turn streams the stub answer, no panic |

Every one of the tables above is asked with the feature **on by default** since 08/11: the resolver's
own tests assert the whole eight-feature table is `enabled` and `component` with no policy and no env,
`policies/default.json` is asserted to name each of them `true`, and a `features.<id>: false` is asserted
to be the off switch.
