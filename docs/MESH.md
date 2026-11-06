# Mesh: direct node-to-node calls by hierarchy

Peers call each other **directly**. The rendezvous is a directory, not a wire: it tells a node where
another node is, and after that the call goes node to node. The relay stays as the fallback for a
peer that cannot be reached directly, exactly as it is today.

Hierarchy decides who may call whom:

> a node may call and control nodes at **its own level or below**. Anything else needs an explicit
> per-peer grant in the operator's `policy.json`.

Level 0 is the top of the fleet. The laptop node is level 0 and controls `wasm_the_first` (level 1)
with no grant at all; `wasm_the_first` may not control the laptop unless the operator writes a grant
that says so.

Status: library built and tested (`rust/wa-mesh`, see [What is implemented](#what-is-implemented)),
wired behind `WA_MESH=1`. Code: `rust/wa-mesh/src/*.rs`. Related: [FABRIC.md](FABRIC.md) (layers and
transport direction), [RENDEZVOUS.md](RENDEZVOUS.md) (the directory and the relay),
[GRANT-POLICY.md](GRANT-POLICY.md) (the file whose `mesh` section holds the grants), [BINDING.md](BINDING.md)
(what a guest is).

## 1. The signed fleet roster

The roster is one JSON document, signed with one ed25519 key — the **fleet key** — and kept on every
node at `<home>/.wasm-agent/mesh-roster.json` (override: `WASM_AGENT_MESH_ROSTER`, or `mesh.roster` in
`policy.json`).

```json
{
  "version": 1,
  "fleet": "ohana",
  "issued_at": 1762000000,
  "expires_at": 1793536000,
  "nodes": [
    { "node_id": "3f2a…", "public_key": "a1b2…", "name": "laptop", "level": 0,
      "addresses": ["192.168.1.10:8891", "laptop.example.net:8891"], "revoked_at": 0 },
    { "node_id": "8c11…", "public_key": "77d0…", "name": "wasm_the_first", "level": 1,
      "addresses": ["147.15.64.233:8891"], "revoked_at": 0 }
  ],
  "signature": "9ab3…"
}
```

What each field means, and what is checked:

| field | meaning | check |
| --- | --- | --- |
| `version` | roster schema | must be `1`, anything else is a load error |
| `fleet` | a name for the operator's own bookkeeping | non-empty, no control characters |
| `issued_at` | unix seconds the operator signed it | more than 300 s in the future is refused (`roster_not_yet_valid`) |
| `expires_at` | unix seconds after which the roster is dead; `0` = never | `0`, or in the future, else `roster_expired` |
| `nodes[].node_id` | the node's identity: first 32 hex of `sha256(public_key)` | **must equal** that derivation, else `node_id_mismatch` |
| `nodes[].public_key` | ed25519 public key, hex (same key as `node.key`) | 64 hex characters |
| `nodes[].name` | what a person calls it; used for the operator's reading only | non-empty, ≤ 64 bytes, no control characters |
| `nodes[].level` | where it sits in the hierarchy; 0 is the top | `0..=9`, else `level_out_of_range` |
| `nodes[].addresses` | `host:port` the mesh listener answers on, in preference order | `host:port` shape, ≤ 253 bytes each, at most 8 per node |
| `nodes[].revoked_at` | unix seconds the operator removed the node; `0` = valid | a revoked node is refused as caller *and* as target |
| `signature` | ed25519 over the canonical bytes below | must verify against the operator's `mesh.roster_key` |

Unknown fields are a load error (a typo must not silently drop a level or an address), and so is a
duplicate `node_id`. The canonical bytes are:

```
mesh-roster-v1|<fleet>|<issued_at>|<expires_at>|{"nodes":[{…}]}
```

where `{"nodes":…}` is `serde_json`'s output for the nodes array, whose field order is the struct's
(`node_id`, `public_key`, `name`, `level`, `addresses`, `revoked_at`). The domain string is in the
signed bytes so a roster signature can never be replayed as a call signature.

**Who signs.** One key per fleet, held by the operator, not by a node: a compromised node must not be
able to promote itself to level 0. The key *is* the trust anchor, so it is pinned by its public key in
`policy.json` (`mesh.roster_key`); a roster signed by any other key is refused `roster_unverified`.
The fleet key may be the operator's own node key (`wa mesh roster` accepts `--key <path>`), which is
the same ed25519 machinery as the node identity — nothing new to protect.

**How levels are assigned.** By hand, in the roster, by the operator. There is no self-declaration
anywhere in this design: a node cannot register its own level at the rendezvous, and the rendezvous is
never asked. A machine Victor uses directly is 0; the always-on node it commands is 1; a guest or a
throwaway belongs at 2 or below. A level is only ever compared inside one roster, so the numbers mean
what the operator meant them to mean.

## 2. Hierarchy and grants

`authorize(caller, target, verb)` runs on **both** ends — the caller decides whether to try, the
target decides whether to run, and the target's answer is the one that counts. Order of evaluation,
the same order the reason words below report:

| # | rule | answer |
| --- | --- | --- |
| 1 | caller or target revoked in a verified roster | `deny: revoked` |
| 2 | `caller == target` | `deny: self_call` (a node's own path is local, not mesh) |
| 3 | a `deny` grant matches `(caller, target, verb)` | `deny: grant_denied` — **deny is evaluated first** |
| 4 | an `allow` grant matches `(caller, target, verb)` | `allow: grant_allowed` |
| 5 | `target.level >= caller.level` (same level or below) | `allow: hierarchy_allowed` |
| 6 | otherwise (calling upward) | `deny: hierarchy_denied` |

Verbs are three, and they are coarse on purpose (a capability is what runs; the verb is how much
authority it needs). `read` is the read-only capability set (`read`, `read_many`, `ls`, `grep`,
`sessions`, `session`, `search_messages`, `recall`, `status`, `health`); `control` is
`bash`, `write`, `edit`, `shell`, `chat`, `client`, `set_role`, `set_model`, `set_provider`,
`subagent`, `spell_save`, `spell_run`, `access`; everything else is `call`, and a capability nobody
listed is treated as **`control`** — an unknown name must need the strongest grant, not the weakest.

Grants live in the operator's existing policy file, section `"mesh"`:

```json
{
  "version": 1,
  "components": { "…": {} },
  "mesh": {
    "version": 1,
    "roster_key": "<hex public key of the fleet key>",
    "roster": "mesh-roster.json",
    "grants": [
      { "caller": "8c11…", "target": "3f2a…", "verb": "read", "effect": "allow",
        "note": "the oracle node may read the laptop's logs" },
      { "caller": "*", "target": "3f2a…", "verb": "control", "effect": "deny",
        "note": "nobody gets to drive the laptop from below" }
    ]
  }
}
```

The merge rules are the grant policy's, deliberately and in the same words: `deny` rules are
evaluated **before** `allow` rules, so a target that matches both is refused; being absent from every
list means refused (default deny — this is the hierarchy itself); an empty pattern is a load error
(write `*` to mean any); patterns are `Pattern`s from `rust/wa-grant-policy` (exact, `prefix*` or a
glob with `*` — never a regex); unknown fields are a load error. A `deny` rule matching
`caller:"*", target:"*", verb:"*"` is the whole-fleet cutoff, the equivalent of the grant policy's
`effect: "deny"`.

**On ids, never names.** `caller` and `target` match node **ids** (or `*`). A name is whatever a node
declared; an id is the hash of the key it signs with. Same rule as `WASM_AGENT_TRUSTED_MASTERS` in
[BINDING.md](BINDING.md), for the same reason.

**Both ends carry the grant, and the target's copy is the one that executes.** A grant is a statement
about *this* node written in *this* node's `policy.json`, so an upward call needs it in two files: the
caller's copy refuses a call it knows is not allowed before dialling, and the target's copy is the
authority at the moment of execution. A fleet whose two copies disagree fails closed — the target
answers `mesh_denied`, and a test asserts exactly that (`an_upward_call_works_when_both_ends_carry_the_operator_grant`).
One file would be simpler and wrong: a node that can authorize a call against *its own* fleets would
authorize itself.

`policy.json` is parsed by `rust/wa-grant-policy` with `deny_unknown_fields`, so **today a `mesh`
section makes the grant-policy loader refuse the file**. `wa-mesh` reads the section out of the same
file itself (it parses only `mesh`), and [GRANT-POLICY.md](GRANT-POLICY.md) keeps its own schema
until `PolicySet` learns to ignore the key — see [What is open](#what-is-open). Do not put a `mesh`
section in a node's policy file until that line is done, or the grant policy will refuse to load and
every sensitive capability will be denied `no_policy`.

## 3. Order of connection attempts

For one call, in order:

1. **Roster addresses, cheap first.** The target's `addresses` are sorted by reachability class: a
   private or link-local address (`127.`, `10.`, `192.168.`, `172.16–31.`, `fc00::/7`, `fe80::/10`)
   before a public one, and the operator's own order inside a class. A LAN address that works costs
   one round trip at LAN latency.
2. **Learned addresses** — anything the peer cache picked up from the rendezvous or from a previous
   successful call (`mesh/peers.json`), after the roster's list.
3. **Hole punch — not implemented.** The seam exists and nothing more: there is no STUN, no ICE, no
   datagram probe. A NAT-to-NAT pair that cannot be reached directly takes step 4 today. It is a step
   in the design so a caller's report names where it stopped, not a capability claim.
4. **The relay, as today.** `host.mesh_call` answers `mesh_unreachable` (never a denial) and the
   caller's existing path — direct endpoint, then relay — takes over. A refusal is **not** a reason
   to fall back: a hierarchy or grant denial would otherwise be laundered through the relay, which
   enforces the old rules and would allow it.

Each attempt is bounded (connect 3 s, whole call 60 s by default, `timeout_seconds` in the call),
audited as one line, and the address that worked is remembered so the next call starts there.

## 4. The peer cache (calls without a rendezvous)

`<home>/.wasm-agent/mesh/peers.json` (override `WASM_AGENT_MESH_CACHE`):

```json
{ "schema": 1, "saved_at_ms": 1762000000,
  "peers": { "8c11…": { "node_id": "8c11…", "name": "wasm_the_first", "level": 1,
                        "public_key": "77d0…", "addresses": ["147.15.64.233:8891"],
                        "source": "rendezvous", "last_ok_ms": 1762000000, "last_error": "" } } }
```

- **What it is for.** The rendezvous answers "where is this node now". After one answer, the address
  is cached, so the next call needs no directory at all. Kill the rendezvous and calls keep working —
  that is the test in §6.
- **The roster wins.** Level and public key come from the verified roster; the cache never changes
  either. It only ever adds addresses (marked `rendezvous` or `learned`), and the roster's addresses
  keep their place at the front. A cache that disagrees with the roster about a key is overwritten,
  not trusted.
- **No cache, no trust.** An address in the cache is a hint about *where*; who a peer is comes from
  the roster and from the signature on its reply. A poisoned cache redirects a call at worst — a peer
  that cannot sign as that node id answers nothing the caller accepts.
- **Written atomically** (temp file + rename), 0600 in a private directory, and a corrupt file is
  reported on stderr and ignored (fail visible, fail open to the roster).

## 5. Identity, authentication and replay

The mesh uses the **existing node keys** — `node.key`, the same ed25519 key and the same `node_id`
derivation (`sha256(public_key)[..32]`) as the rendezvous, `/node/call` and binding. There is no
second identity to rotate.

A call is `POST /mesh/call` over plain HTTP (loopback or LAN today; TLS/QUIC is
[FABRIC.md](FABRIC.md)'s transport direction, not this change):

```
x-wa-mesh: 1
x-wa-node: <caller node id>      x-wa-pub: <caller public key>
x-wa-ts:   <unix seconds>        x-wa-sig: <hex>
content-type: application/json
{"schema":1,"request_id":"…","from_node_id":"…","to_node_id":"…",
 "capability":"read","args":{…},"inner_body":"…","inner_headers":[["X-WA-Node","…"]]}
```

- **Signed bytes:** `mesh-call-v1|<from_node_id>|<ts>|<sha256(body)>`. The body hash is in the
  signature, so the capability and its arguments cannot be swapped on the path; the `to_node_id` is
  inside the hashed body, so a call that is valid for one node cannot be redirected to another
  (`wrong_target`). The domain string is versioned: an old receiver refuses a new sender's signature
  and vice versa, and neither ever falls back to an unsigned form.
- **Mutual authentication.** The caller must be a node in the verified roster *holding that key*
  (`unknown_caller` otherwise) — the roster is the authority, not the rendezvous, which is the point
  of the cache in §4. The reply is signed by the target:
  `mesh-reply-v1|<target node id>|<caller node id>|<ts>|<sha256(body)>`, verified against the roster
  key for the target. An unsigned reply is never a result: refusals issued *before* the caller is
  authenticated (`bad_request`, `bad_signature`, `stale_request`, `unknown_caller`,
  `replayed_request`, `wrong_target`, `too_large`) carry a allow-listed code only and the caller
  reports them as a diagnosis, `verified:false`.
- **Replay protection.** The pair `(from_node_id, ts, signature)` is recorded after every check has
  passed and refused for `replayed_request` inside a 120 s window (twice the freshness window) — the
  same rule and the same window as `/node/call`. Recorded only after authentication, so a forgery
  cannot burn a real request's id. The guard is in memory: a restarted listener forgets its window,
  and the freshness bound is what still refuses an old replay (documented, not hidden).
- **Freshness.** `|now − ts| ≤ 120 s`, otherwise `stale_request` — the same tolerance as the node's
  own peer calls, because it fails for the same reason (a clock that is wrong by minutes).
- **Authorization, twice.** The caller authorizes before it dials; the target authorizes again from
  the same roster and the same `policy.json` section. The target's verdict is the only one that
  executes anything, and a target without its own roster refuses every call rather than trusting the
  caller's copy.

## 6. Audit lines

Every attempt writes one line, on stderr and (when the host supplies a sink) to
`<state>/audit/mesh.jsonl`. No message text, no capability arguments, no secrets — ids, levels,
verbs, verdicts, the reason, the address class and the duration:

```
mesh call from=8c11f0a2 to=3f2a91cd verb=control decision=allow reason=hierarchy_allowed transport=direct:lan addr_class=private ok=true status=200 ms=41 attempt=1
mesh call from=8c11f0a2 to=3f2a91cd verb=control decision=deny reason=hierarchy_denied ok=false attempt=0
mesh recv from=8c11f0a2 to=local verb=read decision=allow reason=grant_allowed ok=true status=200 ms=2
```

`decision` is `allow` or `deny`; `reason` is one of the words in §2 plus the transport reasons
(`unreachable`, `bad_signature`, `stale_request`, `replayed_request`, `wrong_target`,
`roster_unverified`, `handler_unavailable`). A denial is audited even when it costs no network call.

## 7. What is implemented

| piece | where | state |
| --- | --- | --- |
| roster parse/verify, levels, revocation | `rust/wa-mesh/src/roster.rs` | done, tested |
| `authorize(caller, target, verb)` | `hierarchy.rs` | done, tested |
| grants from `policy.json` `"mesh"` | `policy.rs` | done, tested |
| peer cache + rendezvous merge | `cache.rs` | done, tested |
| direct transport client (attempt order, mutual auth, replay-safe) | `client.rs` | done, tested |
| direct transport server (`/mesh/health`, `/mesh/call`) | `server.rs` | done, tested |
| audit lines | `audit.rs` | done, tested |
| `wa call` tries mesh first, falls back on transport failure only | `lua/core/nodes.lua` (`M.mesh_attempt`), `host.mesh_call` | behind `WA_MESH=1` |
| listener mounted by the node | `rust/wa-capabilities/src/serve.rs` | behind `WA_MESH=1` + `WASM_AGENT_MESH_PORT` |
| execution of a capability on the target | forwards to the node's own `/node/call` | **partial** — see §8 |
| hole punching / STUN / QUIC | — | not started |

The wire and the caller's JSON contract (`host.mesh_call`) are documented in
[HOST.md](HOST.md#direct-peer-calls-by-hierarchy-hostmesh_call), because that is where an operator
looks for a capability and where the drift test keeps it honest. Tests: `cargo test -p wa-mesh`
(37 tests: the unit tests per module plus the three-node end-to-end file), or
`bash scripts/test-mesh.sh` for the same run, `cargo clippy -p wa-mesh`
clean.

**The flag.** `WA_MESH=1` (the same value also read as `WASM_AGENT_MESH`) turns the whole feature on:
`host.mesh_call` stops answering `mesh_disabled`, `wa call` tries the mesh path first, and the node
mounts its listener when `WASM_AGENT_MESH_PORT` names a port (it never picks one by itself, so a flag
alone cannot open a port nobody meant to open; without the port the node logs one line and does not
listen). `WASM_AGENT_MESH_BIND` decides the address (`127.0.0.1` by default, `0.0.0.0` inside a
container whose port is published to the host's loopback). With the flag unset, `wa call` runs exactly
the code it runs today — two `host.getenv` reads on the first call (cached for the process) and
nothing else, and `host.mesh_call` answers
`mesh_disabled` without touching the network or the disk.

A minimal deployment, once `policy.json` can carry the section (§8.2) and the roster is signed:

```bash
export WA_MESH=1
export WASM_AGENT_MESH_PORT=8891        # not 8799/8800/8890
export WASM_AGENT_MESH_BIND=0.0.0.0     # a LAN-visible fleet; 127.0.0.1 for one machine
export WASM_AGENT_MESH_ROSTER=$HOME/.wasm-agent/mesh-roster.json
wa serve --port 8799
```

## 8. What is open

1. **The target executes through today's trust basis.** The mounted listener authorizes the caller
   against the roster and hierarchy, then forwards the call, with the caller's own inner request and
   headers, to the node's loopback `/node/call`. That path verifies the caller the way it does today:
   a *fresh* rendezvous lookup. So with the rendezvous down a real node still refuses
   `unknown_caller` at the last step, even though discovery and the mesh verdict needed no directory.
   Making the roster the execution trust basis is a change in `lua/core/server.lua`'s
   `verify_peer`/`verify_caller` (a mesh-verified caller basis carried only on the loopback hop), which
   this change deliberately does not make — it is a security boundary, and the crate tests prove the
   mesh verdict without it.
2. **`policy.json` cannot carry `mesh` for the grant policy yet.** `PolicySet` refuses unknown fields;
   one line in `rust/wa-grant-policy/src/policy.rs` (skip a top-level `mesh`) is the fix, plus its
   test. Until then a node that needs mesh grants must not also rely on the grant policy loading.
3. **No hole punching, no TLS, no QUIC.** Plain HTTP on loopback/LAN. A public address in a roster is
   a public plain-HTTP endpoint: acceptable for identity-signed calls between the operator's own
   nodes only because nothing confidential is in the envelope, and not acceptable as it stands for
   anything wider. [FABRIC.md](FABRIC.md) names QUIC + ICE as the target.
4. **Revocation is roster-wide, not per peer.** A revoked node is refused as caller and as target;
   there is no "revoked for this caller only" — that is what a `deny` grant is for.
5. **Rate limiting is not here.** The grant policy's buckets are for capabilities; the mesh has no
   per-peer budget yet. A hostile roster member can call as fast as the network allows (read verbs
   are the ones that get there), which the §5 rules bound in *authority*, not in volume.
6. **The peer cache is per node, not per fleet**, so a node that has never called a peer and has no
   rendezvous has no address for it. That is correct (discovery has to come from somewhere) and worth
   saying: the cache survives the directory dying, it does not replace it the first time.
