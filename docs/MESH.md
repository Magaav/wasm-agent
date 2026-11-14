# Mesh: direct node-to-node calls by hierarchy

Peers call each other **directly**. The rendezvous is a directory, not a wire: it tells a node where
another node is, and after that the call goes node to node. Most nodes have no public address, though,
so the **relay stays** — and it carries the *same signed mesh call*, so the roster decides on that
path too. The relay is transport: it moves bytes it cannot read and decides nothing.

Hierarchy decides who may call whom:

> a node may call and control nodes at **its own level or below**. Anything else needs an explicit
> per-peer grant in the operator's `policy.json`.

Level 0 is the top of the fleet. The laptop node is level 0 and controls `wasm_the_first` (level 1)
with no grant at all; `wasm_the_first` may not control the laptop unless the operator writes a grant
that says so.

Status: built and tested (`rust/wa-mesh`, see [What is implemented](#what-is-implemented)): on the
direct path **and** on the relay path the target decides with the same signed roster, and a node that
has no roster yet keeps today's operator pins until an operator installs one
([§7](#7-bootstrapping-an-existing-operator-wa-fleet-push-roster)). Code: `rust/wa-mesh/src/*.rs` (the transport and the operator’s tool) and
`rust/wa-mesh-core/src/*.rs` (the decisions, compiled into the node and the guest).
The fleet's *decisions* are also a component (`wa:mesh`, [§10](#10-the-mesh-as-a-component-wamesh)):
`WA_MESH_COMPONENT=1` routes them through `rust/components/mesh`, and the native default is unchanged.
Related: [FABRIC.md](FABRIC.md) (layers and
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
| `revision` | a **monotonic** revision of the roster (`0` = a legacy document) | a node refuses a lower revision (`roster_rolled_back`) and a same-revision fork (`roster_fork`) |
| `prev_hash` | the chain hash of the roster this one replaces (`0` revision rosters have none) | empty, or one sha256 in hex; a `prev_hash` without a `revision` is a load error |
| `signature` | ed25519 over the canonical bytes below | must verify against the operator's `mesh.roster_key` |

Unknown fields are a load error (a typo must not silently drop a level or an address), and so is a
duplicate `node_id`. The canonical bytes are:

```
mesh-roster-v1|<fleet>|<issued_at>|<expires_at>|{"nodes":[{…}]}
```

where `{"nodes":…}` is `serde_json`'s output for the nodes array, whose field order is the struct's
(`node_id`, `public_key`, `name`, `level`, `addresses`, `revoked_at`). The domain string is in the
signed bytes so a roster signature can never be replayed as a call signature.

From `revision >= 1` the canonical bytes are the v1 bytes with a different domain string and the two new
fields inside the signature:

```
mesh-roster-v2|<fleet>|<issued_at>|<expires_at>|<revision>|<prev_hash>|{"nodes":[{…}]}
```

`revision: 0` writes the v1 bytes above, byte for byte, which is what keeps every roster already pinned on
a node verifying after an upgrade. `prev_hash` is `sha256("mesh-roster-chain-v1|" + canonical + "|" +
signature)`: the signature is in it, so two documents with the same nodes signed by two keys (a fork) have
different chain hashes. `Roster::refuse_if_not_newer` is the whole rule a node applies to a roster it is
handed - a lower revision is `roster_rolled_back`, the same revision with different bytes is
`roster_fork`, and an identical copy is not a change.

**Who signs.** One key per fleet, held by the operator, not by a node: a compromised node must not be
able to promote itself to level 0. The key *is* the trust anchor, so it is pinned by its public key in
`policy.json` (`mesh.roster_key`); a roster signed by any other key is refused `roster_unverified`.
The fleet key may be the operator's own node key (the same ed25519 machinery), which is the same key
nothing new to protect.

**Making the fleet: `wa fleet keygen`, `sign`, `show`.** The operator's side of the roster is three
commands, and none of them runs inside a node's call path — a node verifies rosters, it never signs
one (`rust/wa-mesh/src/fleetkey.rs`):

```bash
wa fleet keygen --out ~/fleet/ohana.key          # create the fleet key, print its public key
wa fleet sign roster.json --key ~/fleet/ohana.key --expires-days 90
wa fleet show roster.signed.json                 # verify it and print the levels
```

* `keygen` writes the private key **only** to the path it was given: `create_new` (never over an
existing key), mode `0600` where the host has POSIX modes (on Windows the answer says so rather than
claiming it), and it refuses a path inside the node's home (`<home>/.wasm-agent`, which this node's
backups, bundles and file grants already reach) or inside a git checkout (a fleet key must not be one
`git add -A` away from a remote). It prints the public key to pin as `mesh.roster_key`.
* `sign` reads the template with the same strict reader every node uses (unknown fields, a duplicate
`node_id`, a `node_id` that is not `sha256(public_key)` and a bad address are refused **before** the
key is touched), sets `issued_at` to now, sets `expires_at` from `--expires-days` when given (`0`, no
expiry, is the template's own default), and writes the signed document to `<name>.signed.json`
(`--out` overrides) — the template is never rewritten, so a re-sign after an edit never destroys the
draft.
* `show` verifies the signature with `--key <hex|key file>`, or with this node's own
`policy.json` `mesh.roster_key` when no key is given, prints the fleet, the fingerprint, the window
and one line per node (name, level, id, addresses, revocation), and **exits 1** when the roster does
not verify — a tampered roster is a failure, not a footnote.

The canonical bytes these commands sign are the ones below; the producer and every consumer share
`rust/wa-mesh-core/src/roster.rs`, so a signature made here is the signature a node checks — in the
node and in the `wa:mesh` guest alike.

**Where the fleet key lives now: the vault.** The fleet key may also be an entry in the operator's vault
(`docs/VAULT.md`): `wa vault import-ed25519 fleet --from <fleet.key> --shred` (the seed is sealed, and the
file is destroyed after the entry verified), then every command below takes `--key vault:fleet`
(`--vault-dir`, else `$WASM_AGENT_VAULT_DIR`). The seed is opened inside the vault for one signature, the
signature is an audited vault operation, and no command ever prints it. `rust/wa-mesh/src/fleetchange.rs`
is that path; a key file (`--key <path>`) works exactly as before, so a fleet mid-migration needs nothing
new.

**A change is a new revision: `wa fleet revoke`, `rotate`, `anchor`.**

```bash
wa fleet revoke wasm_the_first --roster mesh-roster.signed.json --key vault:fleet
#   sets revoked_at, revision+1, prev_hash = the previous chain hash, re-signs, writes *.signed.json
wa fleet rotate --roster mesh-roster.signed.json --key vault:fleet-next
#   re-signs the fleet under the NEW key as the next revision; prints the anchor command
wa fleet anchor mesh-roster.signed.json --key vault:fleet --new <new public key>
#   signs mesh-anchor-v1|<new key>|<fingerprint> with the key a node pins NOW (--replace-key)
```

Neither `revoke` nor `rotate` touches a node: installing the result is `wa fleet push-roster <node>` per
node (`§7`), which is the act that is reviewable and verifiable. The old key is retired with
`wa vault delete <old>` **after** every node confirms the new one - the destroy is the last step, not the
first.

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
authority it needs). `read` is the read-only capability set (`read`, `ls`, `grep`,
`sessions`, `session`, `search_messages`, `recall`, `status`, `health`, `turns`); `control` is
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
    "enabled": true,
    "port": 8891,
    "bind": "127.0.0.1",
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
4. **The relay, with the same signed call.** With no address (or no address that answered) the mesh
   sends the **same envelope** to the relay (`POST /relay/send`), which hands it to the target. The
   target decides with its own roster exactly as on the direct path
   ([§5.1](#51-the-relay-is-transport-not-a-second-authority)), and the answer comes back signed. A
   refusal is **never** a reason to try another carrier: a hierarchy or grant denial would otherwise
   be laundered through a path that used to have weaker rules. Only when the mesh has no relay to
   reach either (`mesh_relay_failed`) does the caller stop; nothing is sent twice, because a second
   carrier could run a capability twice.

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

### 5.1 The relay is transport, not a second authority

A relayed mesh call is the *same bytes* as a direct one:

```
POST /node/call                       (the relay's own route allow-list)
x-wa-mesh: 1
x-wa-mesh-carrier: relay              (the relay drops response headers: the answer is sealed in the body)
x-wa-node / x-wa-pub / x-wa-ts / x-wa-sig   (the mesh-call-v1 signature)
{...the envelope of §5, with the caller's own /node/call request inside...}
```

The target runs the *same* function over it (`rust/wa-mesh/src/admission.rs`): the mesh signature,
the body hash, `to_node_id`, the freshness window and the replay window are checked before anything
else, then the hierarchy and the grants decide, and the audit line says `transport=relay`. There is no
second set of rules for the relay, and the relay cannot read the envelope's meaning:

**Where the relay is, and what its URL may look like.** The relay's address is whatever the operator
wrote down — `WASM_AGENT_RELAY`, or the `state.service` of an accepted binding — and that is a *service
URL*, not a `host:port`. `rust/wa-mesh/src/endpoint.rs` is the one place it becomes a socket operation:

| the operator writes | the mesh dials | the request path |
| --- | --- | --- |
| `https://rendezvous.example.com` | `rendezvous.example.com:443` | `/relay/send` |
| `http://relay.example.net` | `relay.example.net:80` | `/relay/send` |
| `https://gateway.example.com/fleet` | `gateway.example.com:443` | `/fleet/relay/send` |
| `https://[2001:db8::1]` | `[2001:db8::1]:443` | `/relay/send` |
| `127.0.0.1:8890` (a bare `host:port`) | `127.0.0.1:8890` | `/relay/send` |

A URL that names no port uses its scheme's default (`https` → 443, `http` → 80); a path prefix is kept
and prefixed onto the route; an IPv6 literal stays bracketed. A URL the parser cannot carry is refused
by name and audited as unreachable rather than dialled — a query string is where a token lives, and a
silently-dropped query is a credential that stopped being sent with no line to say so. The 07/11
rollout failed in exactly this seam (`resolve_failed:invalid port value`: `https://host` was handed to
`to_socket_addrs` whole). **There is no TLS client**: the scheme is read for its default port and its
shape and nothing else, so `https://…` is dialled on 443 with the mesh's plain-HTTP dialect. That is
right for a relay reached through a loopback tunnel and wrong for a public TLS endpoint, which will
fail the handshake and say so — §9 item 4.

Nothing else about a relayed call changes:

* it cannot redirect a call (`to_node_id` is inside the signed body, and the target refuses
  `wrong_target`),
* it cannot alter a call (`bad_signature`: the hash of the body is inside the signature),
* it cannot answer for the target (the reply is signed by the target's roster key; on the relay the
  signature travels *inside* the body as a `RelayAnswer`, because the relay hands back a status and a
  body and no headers — the signed message is the direct path's, unchanged),
* it cannot replay a call (the target's replay window is per process and shared by every path, so the
  same bytes spent on the direct listener are refused when they arrive by relay and vice versa).

**What the target's status is, before and after the bootstrap.** A node without a *verified* roster
cannot be decided by one, so the envelope is handed back to today's admission: the caller's own
`/node/call` request runs under the operator-pin check of its binding (`binding.lua`
`binding.authorize`), which is byte-for-byte the rule that was there before, and an operator who is
not in those pins is refused `unknown_caller`. That is the state of every node that was bound before
the mesh existed, and it is why §7 exists.

**Why a running node can be enabled without a restart.** `WA_MESH=1` is a process switch and the
environment of a live process cannot be changed, so the operator's own `policy.json` carries the same
statement: `"mesh": {"enabled": true, …}` ([`MeshPolicy::enabled`]). A node is deciding by the roster
when the flag **or** that field is set, *and* the pinned key verifies the roster file. If the roster
does not verify, the node falls back to the pins — never to something weaker.

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

## 7. Bootstrapping an existing operator: `wa fleet push-roster`

A node that was bound before the mesh existed pins the operator list it was bound with, and no mesh
call can change that from the outside. The fleet is therefore installed **on** it, by a node it
already accepts:

```
wa fleet push-roster nextcloud
wa fleet push-roster nextcloud --replace-key <hex>     # re-anchor a node that pins another key
```

The caller must already be one of the target's operators *under today's binding* — the push is an
ordinary `/node/call` with `capability: "roster"`, over the transport the target already serves (the
relay), admitted by `binding.authorize` and nothing else. The reasoning is the point: the roster
cannot authorize the call that brings the roster into being.

What travels: the signed roster, the fleet **public** key, and the caller's own signature. The fleet
private key never leaves the operator's node — there is no code path that reads, accepts or forwards
one.

What lands on the target, in this order, each step reversible from the previous one:

| step | file | what |
| --- | --- | --- |
| 1 | `policy.prev.json` | the previous `policy.json`, byte for byte |
| 2 | `policy.json` | a `mesh` section **merged** in (`roster_key`, `enabled: true`, `roster`, and `port` when the roster gives this node an address); every other key and every existing rule untouched — the additions-only shape the deploy's policy merge uses for a node with no recorded base |
| 3 | `mesh-roster.json` | the signed roster, written atomically |
| 4 | `env` | `WA_MESH=1` appended when the file says nothing about it, so the next start keeps the feature on |

The target then answers with what it wrote, and the caller **verifies by a mesh call**: a `status`
read the target must now decide with the roster (`transport` and `decision` in the answer). A push
that installed the files but failed that call reports `verified: false` — a failure, not a success
with a footnote.

**The port is what makes it live.** A running node cannot change its environment, so `enabled` alone
would only reach the paths that are decided per call (the relay hop, `host.mesh_call`). The merged
section therefore also carries the listener's `port`, taken from **the roster's own address for the
target** — the only "where this node answers" a relayed push travels with — and the answer says which
port was written and that the listener mounts on the node's next poll. A target the roster gives no
address keeps whatever its own `mesh.port` says (including "no listener"), and nothing is guessed.
The node's live mount (`rust/wa-mesh/src/host_call.rs`, `spawn_supervisor`) reads the section every
second: it mounts the listener when the node is on with a port, moves it when the address changes,
and **unmounts** — closing the socket and freeing the port — when the section turns it off. No
restart, and the roster is read per call, so the very next call decides by it.

Refusals, each before a single file is written:

| code | when |
| --- | --- |
| `unknown_caller` | the caller is not one of the target's pinned operators, or its binding is not accepted |
| `bad_signature`, `stale_request`, `replayed_request`, `wrong_target` | the call itself is not a fresh, correctly signed call for this node |
| `roster_unverified:*` | the roster does not verify against the key being pinned (checked on the *caller* too, so an unverified roster is never even sent) |
| `roster_missing_target` | the roster does not contain the node it is being installed on |
| `roster_pins_different_key` | the target already pins a **different** fleet key: no silent re-anchoring |
| `roster_replace_key_unverified` | `--replace-key` was given but the signature is not the pinned key's over `mesh-anchor-v1|<new key>|<roster fingerprint>` |
| `policy_unreadable` | `policy.json` is not a JSON object, or its `mesh` is not: nothing is overwritten |

The re-anchoring signature can only be produced by whoever holds the fleet key the target pins *now*,
which is what makes `--replace-key` an operator's act and not a peer's. Producing it is deliberately
outside this command (it needs the old private key); the message it must sign is the one above.

## 8. What is implemented

| piece | where | state |
| --- | --- | --- |
| roster parse/verify, levels, revocation, the revision chain | `rust/wa-mesh-core/src/roster.rs` | done, tested |
| **the operator makes the fleet key and signs the roster** (`wa fleet keygen`, `sign`, `show`) | `fleetkey.rs`, `rust/wa-host` (`wa fleet`) | done, tested (round trip, a tampered roster refused, keygen's path refusals) |
| **every gate asks one resolver** (environment, then `policy.json` `mesh.enabled`, then off; read per call, cached by a `policy.json` mtime that has settled) | `gate.rs`, `host_call.rs` (`{gate: true}`, `enabled_at_runtime`, `Settings`), `lua/core/nodes.lua` (`M.mesh_enabled`) | done, tested (`every_gate_answers_from_the_same_resolver`, `scripts/test-mesh-gate.lua`) |
| **a service URL is resolved to `host:port`** (scheme-default ports, a path prefix, IPv6 literals, bare `host:port`) | `endpoint.rs`, `relay.rs` | done, tested (each URL shape, and a send over a real socket at `http://127.0.0.1:<port>/fleet`) |
| `authorize(caller, target, verb)` | `hierarchy.rs` | done, tested |
| grants from `policy.json` `"mesh"` | `policy.rs` | done, tested |
| the persisted settings: `mesh.enabled`, `mesh.port`, `mesh.bind`, `mesh.roster` | `policy.rs`, `host_call.rs` (`Settings`) | done, tested (environment, then setting, then off) |
| peer cache + rendezvous merge | `cache.rs` | done, tested |
| direct transport client (attempt order, mutual auth, replay-safe) | `client.rs` | done, tested |
| direct transport server (`/mesh/health`, `/mesh/call`) | `server.rs` | done, tested |
| audit lines | `audit.rs` | done, tested |
| `wa call` tries mesh first, falls back on transport failure only | `lua/core/nodes.lua` (`M.mesh_attempt`), `host.mesh_call` | done, tested (`scripts/test-mesh-gate.lua`); every gate asks one resolver — see "The gate" |
| **the relay carries the same signed call** (`/node/call` + envelope, sealed answer) | `relay.rs`, `client.rs` | done, tested |
| **one admission for every path** (signature, body hash, `to_node_id`, replay window, hierarchy, grants, audit) | `admission.rs` | done, tested |
| the target decides on the relay path too | `serve.rs` (`/node/call`), `lua/core/binding.lua` (`M.tick`) | done, tested |
| a roster-authorized caller reaches the capability without the operator pins | `serve.rs` (`/node/admitted` + one-shot ticket), `binding.lua` (`wa_mesh_admit`) | done, tested |
| **existing operators bootstrap it** (`wa fleet push-roster`, host call) | `fleet.rs`, `lua/core/fleet.lua`, `binding.lua` (`roster` capability) | done, tested |
| **the listener mounts, moves and unmounts while the node runs** | `host_call.rs` (`spawn_supervisor`), `serve.rs` | done, tested (three live enable/disable cycles on one `wa serve`, one port, one pid) |
| execution of a capability on the target | `lua/core/server.lua` (`verify_peer`, `mesh_caller`, `wa_node_call`) over the node's own `/node/admitted` | done on both of `serve.rs`'s paths — see §9 item 2 |
| **admission by the mesh's verb**, for a call the mount attested | `lua/core/server.lua` (`mesh_verb`, `mesh_caller`, `wa_node_call`), `attest.rs` (the signature), `serve.rs` (the sixth argument) | done and tested on both of `serve.rs`'s paths (`scripts/test-mesh-attest.lua`, `scripts/test-mesh-trust.lua`: the Rust signer's attestation, admitted by the real `wa_node_call`; legacy list unchanged; every forgery refused) — the Lua relay runtime still passes five arguments, §9 item 1 |
| hole punching / STUN / QUIC | — | not started |

The wire and the caller's JSON contract (`host.mesh_call`) are documented in
[HOST.md](HOST.md#direct-peer-calls-by-hierarchy-hostmesh_call), because that is where an operator
looks for a capability and where the drift test keeps it honest. `host.mesh_call` also answers the
modes this feature adds — `{admit: …}` (decide an inbound envelope), `{seal: …}` (sign the answer for
a carrier that drops headers), `{attest: …}` (the node-signed proof a managed node admits a call by
verb), `{verify_roster: …}`, `{roster_plan: …}` and `{install_roster: …}` (the bootstrap). They are
modes of the capability that already existed, so the catalogue does not grow for a feature only a
fleet member ever uses.

Tests: `cargo test -p wa-mesh` (the unit tests per module, the three-node end-to-end file, and
`tests_relay.rs` — four nodes A/B/T/R where T pins `[B]` like `nextcloud`: refused before the push,
installed by `B`, allowed after it, denied upward, tampered body refused, replay refused, a different
fleet key refused; plus the 07/11 pair as one test,
`a_caller_enabled_only_by_its_policy_reaches_the_roster_through_a_service_url`: a caller whose only
statement is its own `policy.json`, a relay reached at a URL with a scheme and a path, T's pins
excluding that caller — refused before the push, admitted by the roster after it, and a caller whose
policy says nothing still `mesh_disabled` with the legacy route unchanged), `bash scripts/test-mesh.sh`
for the same run plus clippy and the four Lua tests (three admission, one gate —
`scripts/test-mesh-gate.lua` runs *without* `WA_MESH`, because the point of it is that the policy
alone turns the mesh on), and `bash scripts/test-mesh-live.sh` for the keygen/sign/show round trip and
the live mount on a real `wa serve`.

**The gate: one resolver, for every path.** "Is the mesh on for this node right now" has exactly one
answer, in `rust/wa-mesh/src/gate.rs`, and every gate asks it — `host.mesh_call`'s call path, the relay
hop (`mesh_peer_call` in `/node/call`), the mount's settings, and the CLI's remote-call path in
`lua/core/nodes.lua`, which asks `host.mesh_call({"gate": true})` before it decides whether to try the
mesh first. The order is **environment, then the operator's file, then the default** — and since 08/11
the default is *on when a roster verifies against the pinned key*, the legacy path otherwise:

| # | statement | answer |
| --- | --- | --- |
| 1 | `WA_MESH`, else `WASM_AGENT_MESH` (`1`/`true`/`on`/`yes`, or `0`/`false`/`off`/`no`) | that, `from: "environment WA_MESH"` |
| 2 | `policy.json`'s `mesh.enabled` (`true` or `false`) | that, `from: "policy.json mesh.enabled"` |
| 3 | neither, and a roster verifies against the pinned `mesh.roster_key` | **on**, `from: "default: roster verified"` |
| 4 | neither, and no roster verifies (no key, no file, bad signature, expired) | off — the legacy path, `from: "default off"` |

**On by default, off without a roster.** Victor, 08/11: "every new feature on by default, each with a
live per-feature off switch". A node whose `policy.json` pins a fleet key *and* whose roster verifies
against it is a node an operator deliberately put in a fleet, so it decides by the roster without a
second statement. Everything else keeps the old answer, and the ways to get there are all ordinary:
no `mesh.roster_key`, no roster file (`<config>/mesh-roster.json` or `mesh.roster`), a roster signed by
another fleet, an expired one — all of them are the legacy path. The switch is live: `"mesh.enabled":
false` (or `WA_MESH=0`) turns a running node off on the next call, and `"mesh.enabled": true` turns one
on; `wa features` and `host.features()` print the answer with its source (`mesh: on (default: roster
verified)`), so an operator never has to guess which of the four rows they got.

The verification is not re-run per call for free: the gate caches the answer by the policy file's
mtime/size and the roster's mtime/size, and re-verifies at most once a minute, because a roster has an
expiry and a cached "verified" must not keep an expired fleet alive (`gate::roster_verified`).

An **explicit `WA_MESH=0` wins over a policy that says `enabled: true`**: an operator who writes it into
a node's env file means off, and the file must not overrule the person who started the process. An
unset or empty variable is not a statement. `WASM_AGENT_MESH_PORT`, `WASM_AGENT_MESH_BIND` and
`WASM_AGENT_MESH_ROSTER` override `mesh.port`, `mesh.bind` and `mesh.roster` the same way.

Why one resolver, and why per call. `WA_MESH=1` is a process switch and a live process's environment
cannot change, so the operator's own `"mesh": {"enabled": true, …}` in `policy.json` is the statement a
*running* node can be given — which is what §7's push writes. On 07/11 the gates disagreed: the host
had learned to read the file, and `wa call` had not, so `wa call nextcloud bash …` on a laptop node
whose policy said `enabled: true` went down the legacy path and was refused `not a pinned operator`.
The answer is therefore read **per call** and cached only by the policy file's mtime and size, so an
edited or pushed policy is in force on the next call and not on the next restart (`gate::cached`).
Nothing is cached in the Lua interpreter: `nodes.lua` asks the host each time, which is one cheap host
call.

A port is never picked by the node itself, so a flag alone cannot open a port nobody meant to open; a
node that is on with no port decides peer calls by the roster (the relay hop and `host.mesh_call`) and
says so in one line instead of listening.

The mount re-reads that section about once a second (`WASM_AGENT_MESH_POLL_MS` overrides the
interval). Enabling mounts the listener, changing the port or bind moves it, disabling unmounts it and
frees the port; a policy that cannot be read leaves the mount as it is and puts the reason on stderr
once — a partial read must not silently open or close a port. A gate that cannot read the policy
answers **off** (with the reason), never a guess.

A minimal deployment (the roster installed by `wa fleet push-roster`, §7, or by hand):

```bash
export WA_MESH=1
export WASM_AGENT_MESH_PORT=8891        # not 8799/8800/8890
export WASM_AGENT_MESH_BIND=0.0.0.0     # a LAN-visible fleet; 127.0.0.1 for one machine
export WASM_AGENT_MESH_ROSTER=$HOME/.wasm-agent/mesh-roster.json
wa serve --port 8799
```

or, with nothing in the environment (the node's own file is the whole statement, and it takes effect
on the next poll instead of the next start):

```json
{"version": 1, "components": {}, "mesh": {"version": 1, "roster_key": "…",
 "roster": "mesh-roster.json", "enabled": true, "port": 8891, "bind": "127.0.0.1"}}
```

## 9. What is open

1. **The attested admission is wired on `serve.rs`'s two paths, not yet on the Lua relay runtime.**
   A managed node's legacy capability list is unchanged; a call the mesh's mount authorized is
   admitted by the **verb** the roster and the grants decided on (`read`, `control` or `call`), and
   only with an attestation signed by the node's own key over
   `mesh-allow|<this node id>|<ts>|<sha256(caller|verb|capability|<caller signature>)>`
   (`rust/wa-mesh-core/src/attest.rs`; the node signs it in `rust/wa-mesh/src/attestation.rs`). The mount
   signs it after `authorize()` returned allow, and
   `serve.rs` passes it as the sixth argument to `wa_node_call` — on the relay hop it decides
   (`mesh_peer_call`) and on the direct listener's one-shot-ticket hop (`mesh_admitted`). A missing,
   stale, forged, tampered or differently-bound attestation falls back to the legacy name list, which
   is unchanged, so nothing widens without one.

   What is *not* wired is `lua/core/binding.lua`'s relayed-call runtime (`M.tick`): it calls
   `wa_node_call` with five arguments, so on a node whose relay is served from Lua a relayed mesh call
   is admitted by the legacy list only. That is the fail-closed direction (nothing widens), and the
   fix is two lines in `binding.lua` — carry the host's attestation through `wa_mesh_admit` and pass
   it as the sixth argument — which this change's file allow-list does not include. It is also, for the
   same reason, the one path where item 2's execution basis is unavailable: a relayed call served from
   that poller is admitted by the legacy pins and so still refuses `unknown_caller` there. Measured:
   `scripts/test-mesh-attest.lua` (the Rust signer's attestation, the real `wa_node_call`, 17 checks)
   and `scripts/test-mesh-verb-admission.lua` (the receiving rule on its own, a stubbed enrollment).
2. **The roster is the execution trust basis on `serve.rs`'s two paths** (closed 08/22; this was the
   08/11 live failure: `work` at level 0 called `nextcloud` at level 2, the roster allowed it, and the
   target still answered `layer=node reason=unknown_caller transport=relay`). The last step used to be
   `nodeslib.verify_caller` and nothing else: a *fresh* rendezvous lookup, the node's enrollment, or
   the operator pins a binding froze at bind time — so with the pins naming other operators (or the
   directory unreachable) a call the roster had already authorized died at the node's own admission.

   `wa_node_call` now has a second trust basis, and uses it only when the mount proved *this* call
   (`lua/core/server.lua`, `mesh_caller`):

   | required, all of it | why |
   | --- | --- |
   | the attestation is signed with *this* node's key over `mesh-allow|<this node id>|<ts>|<sha256(caller\|verb\|capability\|<caller signature>)>` | only the node's own mount can mint one (`attest.rs`, `admit_inbound`, `LoopbackHandler`); a caller holds its own key, and the message names this node |
   | it names the caller of the request, the verb this capability is graded with (`mesh_verb`), and the capability | it cannot be moved to another caller, verb or capability |
   | it is bound to the caller's own `x-wa-sig` | it cannot be moved to another request |
   | `\|now − ts\| ≤ attest::TTL_SECONDS` (60 s, shorter than the 120 s request window) | expired proves nothing, and the window is smaller than a request's |
   | its signature has not been spent (`mesh-allow|<sig>` in the node's replay ledger) | single use |
   | the admission this node's own mount set for this call (`wa_mesh_admit`) names the same caller, key and capability | the loopback hop is executing *that* call, not one an attestation was left over from |

   With all of it, `verify_peer` takes the attested caller — `role = "master"`, the name and level
   the roster gave it, `mesh = "roster"` — and skips `nodeslib.verify_caller`. Everything else runs
   exactly as before: the caller's own signature over its body, the 120 s freshness window, the replay
   guard and `to_node_id`. When any part is missing, forged, stale, replayed, or bound elsewhere,
   nothing widens and today's path decides (`unknown_caller`, or the pins' answer). The ledger entry is
   written *before* the request replay guard, so a replayed attestation is `unknown_caller` — the same
   answer it got before this change — and never a `replayed_request` that would suggest it was once
   valid for *this* request.

   Measured: `cargo test -p wa-mesh` (`the_target_executes_on_the_mounts_attestation_not_on_its_
   operators_pins`: four local nodes over a real loopback relay, caller level 0 / target level 2, the
   target's pins excluding the caller — allowed and executed with the attestation bound to the caller,
   the verb, the capability and the caller's request signature; level 2 → level 0 denied; a replayed
   request refused; a forged or expired attestation proves nothing; with no roster the pins still say
   `unknown_caller`) and `scripts/test-mesh-trust.lua` (the real `lua/core/server.lua` and
   `lua/core/binding.lua`, an unmanaged unpinned node, the **Rust** signer's attestation: the caller is
   `unknown_caller` without it and executes with it, a control capability runs by its control verb,
   and an expired, forged, replayed, differently-bound, wrong-verb, wrong-caller or wrong-capability
   attestation, a cleared admission and a stale request are all refused as before). The remaining
   hole-punching, TLS and QUIC work is item 4.

   What is *still* not wired is the same hop when `lua/core/binding.lua`'s relay runtime (`M.tick`) is
   the poller: it calls `wa_node_call` with five arguments, so a relayed call served from there is
   admitted by the legacy rules only (fail-closed). `mesh_relayed_call` already *receives* the
   attestation in the admission (`decoded.attestation`); passing it as the sixth argument is the
   whole fix, and `binding.lua` is outside this change's file allow-list — see item 1.
3. **`policy.json` cannot carry `mesh` for the grant policy yet.** `PolicySet` refuses unknown fields;
   one line in `rust/wa-grant-policy/src/policy.rs` (skip a top-level `mesh`) is the fix, plus its
   test. Until then a node that needs mesh grants must not also rely on the grant policy loading.
4. **No hole punching, no TLS, no QUIC.** Plain HTTP on loopback/LAN. A public address in a roster is
   a public plain-HTTP endpoint: acceptable for identity-signed calls between the operator's own
   nodes only because nothing confidential is in the envelope, and not acceptable as it stands for
   anything wider. [FABRIC.md](FABRIC.md) names QUIC + ICE as the target.
5. **Revocation is roster-wide, not per peer.** A revoked node is refused as caller and as target;
   there is no "revoked for this caller only" — that is what a `deny` grant is for.
6. **Rate limiting is not here.** The grant policy's buckets are for capabilities; the mesh has no
   per-peer budget yet. A hostile roster member can call as fast as the network allows (read verbs
   are the ones that get there), which the §5 rules bound in *authority*, not in volume.
7. **The peer cache is per node, not per fleet**, so a node that has never called a peer and has no
   rendezvous has no address for it. That is correct (discovery has to come from somewhere) and worth
   saying: the cache survives the directory dying, it does not replace it the first time.
8. **Which operations the guest owns by default.** The measurement in §10 says `decide` and the signature
   checks are worth a guest call and that the audit line's formatting is not, but the default
   (`WA_MESH_COMPONENT_OPS` unset = all) is chosen for swappability and parity, not for speed. Making
   `render_audit` and `addresses` permanently native is a one-line change in `wa_mesh::seam`, and the
   reason to do it is a fleet whose audit volume matters more than its rule swappability.
9. **`verify_roster` re-parses a document the node already parsed.** The seam passes the roster as text
   because that is what the signature covers, so the guest parses what the node had a moment ago
   (83 µs native against 410 µs through the seam). A `verify-roster(parsed)` shape — the typed record
   plus the canonical bytes to sign — would remove that, and needs the canonical-bytes question answered
   once in `wa-mesh-core`, where it already is (`Roster::canonical`).
10. **The attested admission on the Lua relay runtime** (item 1) is unchanged by this: the guest answers
    the same check, but `lua/core/binding.lua` still passes five arguments to `wa_node_call`.

## 10. The mesh as a component (`wa:mesh`)

The mesh has two halves that fail differently. **What it decides** — is this roster the operator's, may
this node command that one, what does the audit line say, is this attestation about *this* call — is a
rule over a document and two node ids. **What it touches** — the listener, the relay, the rendezvous, the
peer cache file, the node's identity — is transport, and a component must not own a socket or a key.

The first half is `wit/mesh/mesh.wit` + `rust/components/mesh`, and it imports **nothing**: not SQL (the
mesh stores no rows), not a socket, not a clock (`now` is an argument), not a key. So an installed
`mesh.wasm` grants nothing, and there is no scope for a manifest mistake to widen. `WA_MESH_COMPONENT=1`
routes `wa-mesh`'s decisions there (`wa_mesh::seam` → `wa_kernel_runtime::mesh_host`); without it — and
whenever the component cannot answer — the native rule runs, with one log line per (operation, reason), so
a broken or missing component is visible instead of looking like a working fleet.

| routed | the seam answers | native |
| --- | --- | --- |
| `wa_mesh::seam::decide` | `decide(grants, caller, target, verb)` | `wa_mesh_core::hierarchy::authorize` |
| `verify_roster` | `verify-roster(document, key, now) -> levels` | `Roster::verify` |
| `verb_of` | `verb(capability)` | `Verb::from_capability` |
| `render_audit` | `render-audit(event) -> string` | `Event::render` |
| `addresses` | `addresses(target, learned) -> list<string>` | `PeerCache::addresses` |
| `attest_message` | `attest-message(...) -> string` | `attest::message` |
| `verify_attestation` | `verify-ticket(ticket, ...) -> ticket-facts` | `attest::verify` |

What stays native, by design: the listener, the relay, the rendezvous client, the HTTP dialect, the peer
cache *file*, the policy *file*, the replay window, the one-shot loopback tickets, and the node's
identity. The guest composes an attestation's bytes and **verifies** one; it never signs, because a
component that could sign would be a second identity for the node (§9, item 1).

The logic is one crate, `rust/wa-mesh-core`, compiled twice: the node supplies ring's ed25519, the guest
supplies `ed25519-dalek` (a component cannot link ring's C and assembly). Both are ed25519 as specified,
and the canonical bytes are asserted in one place, so a signature either verifies on both sides or on
neither.

**Evidence.** `scripts/test-mesh-component.sh` runs the whole mesh suite twice — native, then with
everything routed — requires the same number of tests on both (62 today), and requires the component run
to print **no** `decided natively` line, which is what a missing or failed guest logs. It then drives
`host.mesh` from `scripts/test-mesh-component.lua` through the real interpreter. The field-for-field
comparison is `rust/wa-mesh/src/tests_component.rs`: every caller/target/verb pair, a tampered roster's
refusal sentence (`roster_unverified:bad_signature`), every audit-line shape, the dial order, the
attested bytes and every ticket refusal.

A **tampered roster is refused by the guest** for the same reason it is refused natively: the operator's
key did not sign those bytes. That case is asserted on both paths and the sentences are compared.

One instantiation detail worth recording, because it was a measurement and not a preference: the instance
is **per thread**, not per process. A single store behind one lock, shared by a listener's handler
threads, the relay hop and the node's own thread, hung the four-node relay test (`tests_relay.rs`: one
process, four nodes, several listener threads) about half the time; a store belongs to the thread that
made it, and this seam holds no state two threads would want to share.

### Cost (measured)

`bash scripts/bench-mesh.sh` on this machine (Windows, release build, one process per path; p50/p95 of the
routed call, i.e. the JSON request, the guest call and the answer, over 2,000 samples):

| scenario | native p50 / p95 | component p50 / p95 |
| --- | --- | --- |
| `decide` (down, control) | 0.2 / 0.3 µs | 169 / 295 µs |
| `decide` (up, denied) | 0.2 / 0.3 µs | 155 / 297 µs |
| `verify_roster` (4 nodes, parse + verify) | 83 / 83 µs | 410 / 410 µs |
| `verify_roster` (signature only) | 55 / 72 µs | 304 / 460 µs |
| `render_audit` | 1.1 / 1.5 µs | 153 / 302 µs |
| `addresses` | 0.4 / 0.5 µs | 155 / 300 µs |
| `attest_message` | 2.4 / 2.9 µs | 170 / 299 µs |
| `verify_ticket` | 45 / 80 µs | 310 / 425 µs |
| first call (compile + instance) | — | 1.7 ms |
| peak RSS | 5,196 KB | 8,184 KB |

Read it as: **a routed decision costs about 0.2 ms and about 3 MB.** Unlike the self-loop seam, the native
path here is *microseconds*, so the seam multiplies the decision's own cost by ~500; on a real peer call (a
loopback connection, a signed envelope, a `/node/admitted` hop) it is a few per cent of the wall clock, and
a node that makes no peer calls never pays it at all.

The rows that matter for a default are `render_audit` and `addresses`: they are *formatting*, not policy,
and they pay the same guest price as a decision. So the route is per operation —
`WA_MESH_COMPONENT_OPS=decide,verify_roster,verify_ticket,attest_message` leaves the audit line and the
dial order native, and the same bench then reports 1.7 µs and 2.4 µs for them (7,980 KB RSS) while the
decisions stay in the guest. Which default an operator wants is a question about *swappability*, not
speed: a fleet that expects its hierarchy rules to change wants `decide` in the guest, and no audit line's
format is worth 0.15 ms an attempt.

Two honest limits: (1) the measurement is a single-threaded, socket-free, node-free loop — a real peer
call's clock is dominated by the network, and this measures the part the seam adds *to the decision*; (2)
the guest's ed25519 is dalek's pure-Rust implementation, ~100 µs slower per verification than ring's here
even with its `fast` backend, which is the price of checking a signature without the node's key. A repeat
run of the same script moved `decide` between 151 and 169 µs p50 (~280–300 µs p95) and the peak RSS by a
few hundred KB, so read the table as ±10% between runs on an idle machine, and do not read the last
digit.
