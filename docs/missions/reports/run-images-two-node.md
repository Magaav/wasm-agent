# run-images-two-node: the picture transfer proved on a real pair, the batch form answered, and a peer's change card drew

Branch `change/run-images-two-node`, base `e832e152`. Priority 1, owed before G.

Three commits:

| commit | what |
| --- | --- |
| `8588fbd8` | the attestation the host actually hands over (`lua/core/server.lua`) + `scripts/test-two-node-images.lua` + `scripts/test-mesh-attest-text.lua` |
| `aed06b82` | the batch form names the single call that carries a picture (`lua/core/tools.lua`, `lua/core/refusal_codes.lua` regenerated, `scripts/test-remote-image.lua`) |
| `544ae50e` | a peer's command draws its change row: the caller asks, and the adopted path answers (`lua/core/tools.lua`, `lua/core/server.lua`, `scripts/test-peer-bash-changes.lua`) |

## Item 1 - one real two-node run, on a scratch pair

**The bug that stood between the base tree and a real pair.** The mount signs an attestation
(`mesh-allow|<this node>|<ts>|sha256(...)`) after its roster allowed a call, and
`lua/core/server.lua`'s `mesh_caller` accepted that proof **only as a Lua table**. The host hands every
argument to `wa_node_call` over with `lua_pushlstring` (`rust/wa-host-support/src/lua.rs`,
`call_string`), so on a real call the proof arrives as the **JSON text** of it. The second trust basis
of `docs/MESH.md` §9 item 2 therefore never applied; a roster-authorized peer the rendezvous had not
seen fell back to `nodeslib.verify_caller` and was refused `unknown_caller`. The existing row passed
because `scripts/test-mesh-attest.lua` hands over the table it decoded itself.

Measured on the scratch pair, before the fix (`8588fbd8` reverts it): the mesh admitted the call
(`decision=allow reason=hierarchy_allowed transport=direct`) and the peer answered
`{"error":"remote_refused", "reason":"unknown_caller", "layer":"node"}`. After the fix the same call
carried the picture.

**The pair.** Two scratch homes on this machine (`$GATE_ROOT/two-node-pair-*`), two real ed25519
identities, a signed roster (`wa fleet keygen` + `wa fleet sign`), the real mesh transport, the real
`wa serve` of this build as the second node, and this node's own `tools.dispatch("remote")` as the
caller. Stubbed, and only that: `nodes.find` (discovery is the rendezvous's, and a scratch pair runs
none by design - no live fleet is touched) and the model provider (the request is what the row
measures).

**The bytes and the digest at both ends** (row `scripts/test-two-node-images.lua`, 35 checks):

* the peer read the picture from its own home and answered `image_data` under `MAX_BYTES`;
* this node verified the digest, stored the bytes and answered a reference whose file exists here:
  `.../attachments/86/861a2431c3a949745f17e501bdf58b0bc4705c4efeab7d45bdbec46899bb6320.png`;
* the peer's own store holds the SAME content-addressed file: both files are 168 bytes of base64, both
  hash to `861a2431...bb6320`, and decoding either gives the 125 bytes that hash to
  `f35fe76f2e81d4bf...` - the PNG's own sha256 as `sha256sum` reports it;
* the peer's own admission line for that call is in its log: `mesh recv from=<A> to=<B> ... verb=read
  decision=allow reason=hierarchy_allowed transport=direct ok=true status=200`;
* **the model's request on node A carries it**: one `image_url` part whose base64 payload equals the
  peer's picture byte for byte, and the tool text carries no `_images` table. See "what I did not
  verify" for where this check ran.

**The over-1 MB refusal** (same row): a 1,471,213-byte PNG on the peer answers
`remote_image_too_large` with `bytes`, `max_bytes=1000000` and the sentence the model reads:
"The picture (big.png, 1471213 bytes) was not sent from that node: a peer transfer carries at most
1000000 bytes (the signed answer has a 4 MiB ceiling of its own)." Nothing is stored, and no
wrong-machine path is handed on.

## Item 2 - the batch form

It does not carry pictures, and its refusal now names the single call that does (`aed06b82`). The
refusal is `remote_image_batch_unsupported`, with `node`, `path`, `image` and the sentence under
Texts to approve. `scripts/test-remote-image.lua` gains the case (refused by name; the note names the
node and the path; the entry counts as failed; no `_images` reaches the caller). The generated refusal
inventory was regenerated (`lua5.4 scripts/gen-refusal-codes.lua --write`).

Why not carry them: one call carries one picture because the picture rides out with THAT call's own
result - verified against the digest the peer named and stored here - and eight ordered text entries
have no such place. The `remote` tool's description said image results are "refused until the node
protocol has bounded binary transfer", which has been false since `5f95d54a`; it now describes the
transfer (up to 1,000,000 bytes) and says a batch carries text only.

## Item 3 - the row

`scripts/test-two-node-images.lua`: the whole two-node case, narrowed to the picture and the cwd facts,
and registered by discovery - `scripts/fast.sh` runs every `scripts/test-*.lua` that
`scripts/fast-path.exclude` does not name, and this file is not in it. Fails on the base tree: measured
at `a picture from a peer is not refused: {... reason:"unknown_caller" ...}`.

`scripts/test-mesh-attest-text.lua` (19 checks) pins the host's own shape: the JSON text admits a
managed capability by its verb, admits the caller on an unmanaged node, and neither a tampered text
nor an unreadable one nor an absent attestation admits anything. Fails on the base tree at the first
of those.

`scripts/test-peer-bash-changes.lua` (17 checks, was 12) fails on the base tree at "the caller emits
one row per file: 0".

## Item 5 - a peer's command draws its row, in a pty

Measured end to end: two scratch nodes, a **scratch rendezvous** (so discovery is the product's own),
a stub model on loopback, and a real `wa chat` inside `script -qec` (a pty). The model called
`tools.remote({capability:"bash", command:'printf "hello\n" > made.txt'})` on the peer; the peer's
file appeared in its work tree and the calling node drew, in the pty:

    ⏺ Remote <peer id> · Bash
    ⎿ exit 0 · 106ms

                                  changed made.txt on tree

A second dispatch measured at the same time, with the exact event: `{"type":"remote_change",
"capability":"bash","node":"pair-b","path":"probed.txt","added":1,"removed":0,"created":true,
"ok":true}`.

**Two causes, both invisible to a stubbed row** (`544ae50e`):

1. the caller never asked. `record_change` was set for edit and write only, so a peer's bash came back
   without the list its own branch turns into rows;
2. a peer's command is ADOPTED: `nodes.remote_call` always adds `budget_ms` to a bash call, so the
   peer runs it through `adopt_bash` (a supervised operation) and never through the bash branch that
   snapshots a command's changes. `adopt_bash` now takes the caller's own request, snapshots around
   the operation when it asked, and answers the same five names a local command sends - path, added,
   removed, created, deleted, and no text.

A command that outlives the call's hold answers no list: the snapshot belongs to the window this call
observed and nothing is claimed about the rest.

## Item 4 - what whatsapp's media download (item e) needs from this transfer

`whatsapp_download` answers a decrypted **file path on the node that holds the account**, bounded at
524,288 bytes, with mime, filename, bytes and sha256 (`lua/core/whatsapp.lua`, the `download` verb).
Called across the mesh it answers a path that means nothing here - the same wall a picture read hit
before `5f95d54a`. What it needs, in order:

1. **the peer half**: the download handler answers `image_data` (`name`, `mime`, `bytes`, `sha256`,
   `base64`) read from its own decrypted file, under the same `MAX_BYTES`, instead of (or beside) the
   path. Today only the built-in `read` does that (`lua/core/tools.lua`, the `image_bytes` branch).
2. **nothing on the caller side for the store**: `lua/core/tools.lua`'s adopt runs on any result that
   carries `image_data`, whatever the capability (measured: the branch is capability-agnostic), so the
   bytes are verified and stored here with no new code.
3. **one allow-list widened in code mode**: `lua/core/codemode.lua` promotes `_images` to the model
   only for `call.tool == 'remote'` with `params.capability == 'read'`. A picture from
   `whatsapp_download` / `mcp_whatsapp_download` inside a script would otherwise keep a
   wrong-machine path in the script's JSON. The list must name those two capabilities explicitly
   (allow-list, never a shape).
4. **the cap fits**: 524,288 < 1,000,000, so a download the bound allows always fits the transfer.
5. **the mime fits**: `image/png`, `image/jpeg`, `image/webp`, `image/gif` are the four
   `memory.store_image` accepts; WhatsApp photos are jpeg and stickers webp, so both store.
6. **the route**: `whatsapp_download` is graded `write` (an effect), so inside code mode it is NOT a
   capability a script may run on a peer; it travels as its own top-level call. That is the single call
   the picture then rides on - the same shape as a peer `read`.

Nothing of this is done here: it is another brief's code (whatsapp-acceptance item 5, "a 120 KB image
fetched from a peer in ONE call"), and its one-line form is 1+3 above.

## The added check: the SENDING half of a peer call's cwd

Re-measured, and the premise was wrong: the sending half is **not in this base**. `peer_args_with_cwd`
lives on `change/operations-explain-and-survive` only (`5dcd001b`, `git show main:lua/core/tools.lua |
grep -c peer_args_with_cwd` = 0). So on this tree a session's directory does not travel, and the
scratch pair measures exactly that:

* an explicit `cwd` on a peer bash is recorded by the peer as `cwd_source=explicit` with `cwd` equal to
  the path this node named (the receiving half works - `scripts/test-two-node-images.lua`);
* the same call with no `cwd` is recorded as `cwd_source=node` (row output: `two-node: peer cwd_source
  for a call that named no directory: node`).

The sending half cannot be proven on this base because it does not exist here; when
`change/operations-explain-and-survive` lands, the same row's second half flips to `explicit` and the
check becomes a pass. Nothing in this branch fabricates it.

## Texts to approve

1. The batch refusal's `note` (`lua/core/tools.lua`, `aed06b82`), built with this node's name and the
   entry's path:

   > The picture <image> on <node> was not sent: a calls batch carries text only (1-8 reads in one
   > signed round trip). Read it as its own call - tools.remote({node:"<node>",capability:"read",path:
   > "<path>"}) - and the picture arrives with that call result, up to 1000000 bytes.

   and its `fix`:

   > send {"node":"<node>","capability":"read","path":"<path>"} as its own remote call, not as an
   > entry of calls

2. The `remote` tool description (`lua/core/tools.lua`, `aed06b82`), replacing "Text reads work; image
   results are refused until the node protocol has bounded binary transfer.":

   > Text reads work. A read of a picture (png, jpeg, gif, webp) on that node comes back as the picture
   > itself, attached to this call's result, when it is at most 1000000 bytes - a bigger one is refused
   > by name with its size, and the fix is to read it on the node that holds it or copy it here first. A
   > calls batch on one peer carries text only: a picture read inside calls is refused by name, and the
   > refusal names the single call above.

No other model- or operator-facing string changed. The peer's `operation` answers, the row texts in the
CLI and the 1 MB refusal sentence are the ones `5f95d54a` already shipped.

## Proposed FACTORY.md text (propose, never write)

Under the rules about tests:

> **A wire seam proved with a stub is not proved.** A row that judges what crosses between two nodes
> stubs `nodes.remote_call` and is green whatever the wire does with the arguments - two faults of the
> 24/11 round lived exactly there: the caller never sent the field the peer's branch required, and a
> peer's bash is adopted as an operation and never reaches the branch the stub stood in for. A change
> that touches what CROSSES a node boundary carries one row that runs two real processes on one machine
> (two scratch homes, two ports, a signed roster, and a scratch rendezvous when discovery is on the
> path), narrowed to under 60 s; the module seam stays for the branches that cannot cross.

> **A function that is handed the host's arguments must accept the host's shape.** A test that decodes
> the proof itself and hands over a table cannot see that the host pushes bytes
> (`lua_pushlstring`): the attestation's second trust basis was dead on every real call for a month
> with a green row. When a host entry point takes an argument, the row hands it over the way the host
> does, and a second check reads the host's own call site to keep the two in step.

## Proposed HANDOVER.md text (propose, never write)

> **A picture crosses a node boundary** (`5f95d54a`, `8588fbd8`): a `read` of a picture on a peer
> answers the bytes under a 1,000,000-byte cap, the caller verifies the digest the peer named and
> stores it here, and it reaches the model as one image part attached to that call's result. Proved on
> a scratch pair (two real nodes, a signed roster) by `scripts/test-two-node-images.lua`. A `calls`
> batch carries text only and its refusal names the single call (`aed06b82`). Nothing else carries
> pictures yet: `whatsapp_download` still answers a path on the node that holds the account (see
> `docs/missions/reports/run-images-two-node.md`, item 4, for the two pieces it needs).

## What I did not verify

* **The model-request check under the fast path's binary.** It needs the embedded code-mode assets,
  which the fast path builds and my ad-hoc debug binary does not have; the row prints
  `SKIP two-node the picture in the model's request: this node has no embedded code-mode assets`
  outside the fast path and a skip is never a pass. The fast-path verdict for that row is recorded at
  the end of this report.
* **The batch refusal on a real pair.** The batch never sends `image_bytes`, so no peer was driven for
  it; the refusal is measured through the real dispatcher with the wire stubbed
  (`scripts/test-remote-image.lua`), which is the same seam the change is in.
* **A picture ON a peer that was placed there by a `write`.** The row copies the fixture into the
  peer's own home; a peer-side `write` of a binary file is not part of this change.
* **The pty card's counts.** The chat run drew `changed made.txt on tree` without `(added 1 line)`; a
  second dispatch from the same pair emitted `created=true, added=1` for the same kind of command, so
  the counts are in the event - the chat's own row lost them, most likely to the command creating a
  file the earlier probe had already created in that tree (reported, not explained).

## Pre-existing failure measured, not mine

`scripts/test-mesh-live.sh` on this node fails before any call: it copies the signed roster to
`$HOME_OP/.wasm-agent/mesh-roster.json` and the call answers
`roster_unreadable: ... No such file or directory`. It is outside this branch's files and it fails the
same way on the base tree's script; recorded here so the next reader does not attribute it to this
round.

## How the stores were read (the 24/11 rule)

Every check reads what the product itself wrote: the two homes are the nodes' own (`WASM_AGENT_HOME`),
the store files are the ones `memory.store_image` wrote under `paths.data()/attachments`, the peer's
operation record is its own `operations/<id>/state.json`, and the mesh verdict is the peer's own audit
line. Nothing was created by hand, and no host capability was stood in for.
