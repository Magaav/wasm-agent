# Feature switches: which path a node runs, and why

A **feature** is one part of the node that has two implementations: a WASI component and the native
path that was there before it. A feature is *off* by default and *on* only when an operator says so, in
one place, for one node.

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

**Installed is not enabled.** A deploy installs the whole set; nothing in it runs until the node's
policy says so.

## The rule

```text
enabled := env override, else policy.json `features.<id>`, else false
active  := "component"  when enabled AND the component is installed with a verified pin
           "native"     otherwise, with the reason
```

| input | wins over | how it is written |
| --- | --- | --- |
| env flag | the policy file | `WA_MEMORY_COMPONENT=1` / `=0` (`1/true/on/yes`, `0/false/off/no`) |
| `policy.json` `features.<id>` | the default | `"memory": true` |
| default | — | off, and it says `source: default` |

* **One resolver.** `rust/wa-features` (crate `wa-features`) is the only code that answers. The Lua
  gates reach it through `lua/core/features.lua` → `host.features`, the CLI through `wa features`, and
  a service through `services {"action":"features"}`. Two surfaces cannot disagree about a node.
* **The policy file is read live.** One `stat` per `WA_FEATURES_WATCH_MS` (default 1000), a parse only
  when the file moved. Turning a feature on or off is an edit to a file, never a restart - the gates ask
  per call, not once at load (`scripts/test-features-gate.lua` proves exactly that).
* **A typo is refused, not guessed.** `WA_MEMORY_COMPONENT=y` is `feature_env_invalid` and stays off;
  it does not fall through to the policy (that would make a typo mean "whatever the file says").
  `"gateway": "yes"` is `feature_value_invalid`. A `features` member that is not an object, or a policy
  file that does not parse, is `features_unreadable:<why>` on every feature.
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
    "selfloop": false, "codemode": false, "hooks": true, "memory": true,
    "gateway": false, "mesh_component": false, "agent_core": false, "telemetry_sink": false
  },
  "components": { }
}
```

`policies/default.json` ships the section with every feature `false`; a key a node's file lacks is the
default (off), so an older node reads a newer policy without failing, and a newer node reads an older
policy without inventing a switch.

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
