# The mesh as an opt-in component: boundary, pins, and the order we get there

Status: proposal, 16/11. Nothing here is implemented; this page is the thing to argue with
before code moves.

## Why the mesh should stop living inside the core

Measured on 16/11, on this fleet: adding **twelve lines** to `lua/core/tools.lua` (the client-side
pins gate) cost a `cargo build` on two machines — 15m06s on the two-core ARM host — plus a
hand-carried binary to every node, because the Lua core is embedded in the `wa` binary. The same day,
the one thing the fleet actually needed (a caller at roster level 0 driving a peer that pins other
operators) turned out to be missing on the **relay** path, and shipping that fix would again mean a
core rebuild everywhere.

Two facts follow, and they are the reason for this page:

* the mesh changes often (roster semantics, admission, endpoints, transport); the core does not;
* a customer of the commercial agent may want **no fabric at all**, and today the mesh is not
  something you can leave out.

## The boundary: the component talks, the core decides

The mesh is the authority decision path. If a version-independent, loadable component could answer
"admit this caller", the plugin boundary would become the weakest link: an older or malicious
component could widen admission and the core would never notice. So the split is not "everything
mesh-ish moves out":

| stays in the core (`wa-host` + embedded Lua) | moves into the `wa:mesh` component |
| --- | --- |
| node identity (the key, `node_id`) | direct/learned/relay **ordering** and retries |
| ed25519 verify of calls, replies and announcements | endpoint **announcement** and the peer cache (`mesh/peers.json`) |
| roster **parse + verify**: `revision`, `prev_hash`, expiry, `node_id` derivation | transport policy: cooldowns, class preference, timeouts |
| `binding.authorize` + grants + hierarchy → the final allow/deny | hole punch / overlay plumbing, when it exists |
| `mesh.enabled`, the one resolver for every path | telemetry and the audit line's transport fields |

The contract is one sentence: **the component proposes an envelope and a route; the core decides
with a roster it verified itself.** A component that lies can pick a bad route. It cannot admit
anyone, and it cannot widen a grant.

This is the same rule `docs/MESH.md` §5.1 already states for the relay — *transport is not a second
authority* — one layer out.

## Pins: signed, monotonic, verified offline

The dangerous half of "no core rebuild" is that the thing being updated is the thing we trust. A
component whose digest is trusted only because it arrived with a signed binary release is fine while
components ship *with* the core, and stops being fine the moment they ship without it. So the pins
become a document of their own:

```json
{
  "version": 1,
  "components": [
    { "name": "mesh", "path": "modules/mesh.wasm",
      "sha256": "…", "api": "wa:mesh@1", "min_core": "0.1.0" }
  ],
  "revision": 7,
  "prev_hash": "…",
  "signature": "…"
}
```

* signed by **`release-signing`**, which lives in the vault and never leaves it;
* verified at **load time, offline**, against the public key the node already pins — no vault, no
  network, no relay in the path;
* refusals by name, the same monotonic rules the roster uses: `component_pin_rollback` (lower
  `revision`), `component_pin_fork` (same revision, different bytes), `component_signature_invalid`,
  `component_digest_mismatch` (the file on disk is not the one pinned), `component_api_unsupported`
  (`api` newer than the core can drive);
* a component that fails any of these is **not loaded**, and the mesh paths answer
  `mesh_unavailable` — never a silent fallback to an unpinned one.

### Why the vault is not asked at call time

Two keys, two jobs, one direction only:

| job | key | when |
| --- | --- | --- |
| sign a component artifact and its pins | `release-signing` (vault) | publish time |
| sign the roster (who may drive whom) | `fleet` (vault — moved there on 16/11, file shredded) | when the mesh changes |
| rotate either key | the old key signs the new one (`wa fleet anchor` / `rotate`) | deliberately, no flag day |
| verify all of the above | **public** keys, pinned on the node | every load and every call, offline |

`release-signing` must not be able to re-sign the mesh and `fleet` must not be able to sign a
component: different blast radius, different ceremony, and the vault's audit log names which was used
when. But no mesh decision ever travels to the vault at runtime — that would make the vault an
availability dependency, a latency tax on every cross-node call, and the single thing whose
compromise hands over the fabric. The vault signs; nodes verify.

## Opting in and out

`mesh.enabled` (env `WA_MESH` / `WASM_AGENT_MESH`, then `policy.json`) already exists and already has
"one resolver, for every path" semantics. It stays in the core, because whether a customer gets a
fabric is a commercial decision, not a plugin's.

* **off** — the component is not loaded; no listener, no relay attachment; every mesh path answers
  `mesh_unavailable` by name. Nothing hangs, nothing half-works.
* **on** — the pinned component loads; `wa nodes`, `wa call` and the roster semantics behave as today.

The commercial agent can therefore ship with the fabric as a module a customer never enables, and the
defaults stay deny: absent component means no mesh, not an open one.

## The order we get there

1. **Signed component pins + load-time verification** (the document above). Small, testable, and the
   precondition for everything else: without it, the first bad pin is a fabric takeover with no
   ceremony.
2. **`wa:mesh` component, release #1 = the missing attestation.** The relay path today hands the call
   to `binding.authorize`, so a level-0 node is still refused by a peer that pins other operators —
   measured 16/11 with both ends on the new build (`layer=node, reason=unknown_caller,
   transport=relay`). It is transport-side, small, and immediately valuable: the pilot proves
   publish → pin → load on a real need instead of on a refactor.
3. **Move addressing and transport** into the component (endpoint announcement — every node reports
   `endpoints: []` today; class ordering; peer cache; cooldowns).
4. **Signature-pinned Lua tree**, so a policy change stops being a binary. Until this lands, "no core
   rebuild" is only half true: the node accepts a tree from disk only when its digest matches the
   *binary's* pin ("installed tree ignored (capability digest differs from this binary)").

Ponytail check at every step: with the component absent, stale, or refusing to load, the core must
still refuse every mesh path and say why. One resolver per decision, and the old path is **removed**
as each decision moves — never left in place as a fallback. Two resolvers drift; this repository has
already been bitten by exactly that.

## What this page deliberately does not do

* **No NAT traversal written in-house.** Hole punching is a product (STUN/ICE, rekeying, MTU, DoS).
  The fleet already has an overlay; if home nodes need direct paths, point the roster at overlay
  addresses (`100.x`), not at whatever the ISP handed out this week. A DNS name in `addresses` is the
  other honest answer, because the roster resolves names and never needs re-signing for an IP change.
* **No address allocation inside the mesh** for now. It is a legitimate design (deterministic from
  `node_id`, signed table, registry republishes only reachability), and it still needs the same NAT
  traversal to be useful for home nodes.
* **No second authority.** Not the relay, not the vault, not the component.

## Open questions

* Does the component get the audit line, or does the core write it from the component's return?
  (Today the audit is one line per attempt, and it names the transport that worked.)
* `min_core` is a version string — is that enough, or does the component contract need a capability
  hash like the Lua tree's "capability digest"?
* If `mesh.enabled` is off and a customer later enables it, whose pin document wins: the signed one
  shipped in the release, or the newest one the node fetched while disabled?
