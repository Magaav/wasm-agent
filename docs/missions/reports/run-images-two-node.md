# run-images-two-node: the picture transfer proved on a real pair, on the basis the fleet uses

Branch `change/run-images-two-node`, base `e832e152`. Priority 1, owed before G. Fable's reading of
24/11 split one commit out and moved the row onto the real admission basis; this is the state after it.

| commit | what |
| --- | --- |
| `aed06b82` | the batch form names the single call that carries a picture (`lua/core/tools.lua`, `lua/core/refusal_codes.lua` regenerated, `scripts/test-remote-image.lua`) |
| `544ae50e` | a peer's command draws its change row: the caller asks, and the adopted path answers (`lua/core/tools.lua`, `lua/core/server.lua`, `scripts/test-peer-bash-changes.lua`) |
| `e7a9d264` | the two-node row proves G on the FIRST basis (a rendezvous that knows both nodes); the attested path leaves this branch |
| `b3e704ae`, `5d292c55`, `eea51c3a`, `d1982e9e` | the rows' own fixes and the runner verdict |
| `4cd1166a`, this one | the report |

The attested admission path (`8588fbd8`) is **not here**: it is commit `e11d9194` on
`change/attested-admission-review`, branched from `origin/main` (`4c720beb`), together with the row that
only tests it (`scripts/test-mesh-attest-text.lua`). Not to be landed before the security review: it
switches ON a path that has never carried a real call, and on a managed node it can admit a capability
beyond the managed list. v0.1.2 behaves as v0.1.1 does.

## Item 1 - one real two-node run, on the basis the fleet uses

**The basis.** A peer admits a caller it can verify NOW: `nodeslib.verify_caller(fresh)` - the
rendezvous's own answer that this node id holds this key - and nothing else. No attestation is involved
anywhere in this row.

**The pair.** Three processes on this machine, all started by the row through the node's own operation
host: a scratch **rendezvous** seeded with this node as its admin (so the registry promotes it, as the
fleet's registry does), a `wa serve` on this node's own scratch home that registers this node's key, and
the peer's `wa serve` with its own home, policy and signed roster for the transport. What is stubbed:
the model provider and the five provider environment names it reads. Nothing else.

**The bytes and the digest at both ends** (`scripts/test-two-node-images.lua`, 51 checks, 0 skips):

* the rendezvous knows both node ids, and `verify_caller(fresh)` answers this node **as a master** -
  the row's first check, and the fact everything else rests on;
* `nodes.find` resolves the peer from the rendezvous (no stub);
* the peer read the picture from its own home and answered the bytes under the cap;
* this node verified the digest the peer named, stored the bytes, and answered a reference whose file
  exists here; the **peer's own store holds the same content-addressed file** - 168 bytes of base64 on
  both sides, the same sha256 (`861a2431...bb6320`), decoding to the 125 bytes that hash to
  `f35fe76f...` (the PNG's own sha256, as `sha256sum` reports it);
* the peer's own log carries its admission of the call: `mesh recv from=<A> to=<B> ... verb=read
  decision=allow reason=hierarchy_allowed transport=direct ok=true status=200`;
* the **model's request** on this node carries one `image_url` part whose base64 equals the peer's
  picture byte for byte, and the tool text carries no `_images` table.

**The over-1 MB refusal:** a 1,471,213-byte PNG on the peer answers `remote_image_too_large` with
`bytes`, `max_bytes=1000000` and the sentence the model reads ("The picture (big.png, 1471213 bytes) was
not sent from that node: a peer transfer carries at most 1000000 bytes ..."). Nothing is stored, and no
wrong-machine path is handed on.

**WHAT THIS MEANS FOR G, and it is the finding of the round:** the picture half of this row **passes on
the base tree too** (`e832e152`), because the transfer itself shipped in `5f95d54a`. A picture from a
peer therefore already reaches the model on any pair the rendezvous knows - no attested admission is
needed, and the path Fable held back was not carrying G's picture requirement at all.

## Item 2 - the batch form

It does not carry pictures, and its refusal names the single call that does (`aed06b82`):
`remote_image_batch_unsupported`, with `node`, `path`, `image` and the approved sentence (Texts to
approve, 1). An entry carrying raw bytes is refused the same way and the field is dropped - a batch
never asks for bytes, and adopting one into an entry with no image message would put a megabyte of
base64 in the script's JSON.

`scripts/test-remote-image.lua` (47 checks) pins all three shapes a peer can answer a batch entry with.

## Item 3 - the rows

`scripts/test-two-node-images.lua` is registered by discovery (`scripts/fast.sh` runs every
`scripts/test-*.lua` that `scripts/fast-path.exclude` does not name). It fails on the base tree at
`and this node draws exactly one row for the one file it changed: []` - the change-card half, which is
`544ae50e`; the picture half, as said above, passes on the base too.

`scripts/test-peer-bash-changes.lua` (17 checks, was 12) fails on the base at `the caller emits one row
per file: 0`.

`scripts/test-mesh-attest-text.lua` (19 checks) moved to `change/attested-admission-review`: everything
it tests is the attested path.

## Item 5 - a peer's command draws its row, in a pty

Measured end to end: two scratch nodes, a **scratch rendezvous** (discovery is the product's own), a
stub model on loopback, and a real `wa chat` inside `script -qec` (a pty). The model called
`tools.remote({capability:"bash", command:'printf "hello\n" > made.txt'})` on the peer; the file
appeared in the peer's work tree and the calling node drew, in the pty:

    ⏺ Remote <peer id> · Bash
    ⎿ exit 0 · 106ms

                                  changed made.txt on tree

The same dispatch measured directly emits the exact event: `{"type":"remote_change",
"capability":"bash","node":"pair-b","path":"probed.txt","added":1,"removed":0,"created":true,
"ok":true}` - and that event is now a check in the two-node row.

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
2. **nothing on the caller side for the store**: the adopt in `lua/core/tools.lua` runs on any result
   that carries `image_data`, whatever the capability (measured: the branch is capability-agnostic),
   so the bytes are verified and stored here with no new code.
3. **one allow-list widened in code mode**: `lua/core/codemode.lua` promotes `_images` to the model
   only for `call.tool == 'remote'` with `params.capability == 'read'`; a picture from
   `whatsapp_download` / `mcp_whatsapp_download` inside a script would otherwise keep a wrong-machine
   path in the script's JSON. The list must name those two capabilities explicitly.
4. **the cap fits**: 524,288 < 1,000,000, so a download the bound allows always fits the transfer.
5. **the mime fits**: png, jpeg, webp and gif are the four `memory.store_image` accepts; WhatsApp
   photos are jpeg and stickers webp, so both store.
6. **the route**: the download is graded `write`, so inside code mode it is not a capability a script
   may run on a peer; it travels as its own top-level call - the single call the picture then rides on.

Nothing of this is done here: it is another brief's code (whatsapp-acceptance item 5, "a 120 KB image
fetched from a peer in ONE call").

## The added check: the SENDING half of a peer call's cwd

Re-measured, and the premise was wrong: the sending half is **not in this base**. `peer_args_with_cwd`
lives on `change/operations-explain-and-survive` only (`5dcd001b`; `git show main:lua/core/tools.lua |
grep -c peer_args_with_cwd` = 0). So on this tree a session's directory does not travel, and the scratch
pair measures exactly that:

* an explicit `cwd` on a peer bash is recorded by the peer as `cwd_source=explicit` with `cwd` equal to
  the path this node named (the receiving half - a check in the two-node row);
* the same call with no `cwd` is recorded as `cwd_source=node` (row output: `two-node: peer cwd_source
  for a call that named no directory: node`).

Nothing here fabricates the sending half; when that branch lands, the row's second half flips to
`explicit` and the check becomes a pass.

## Texts to approve

1. The batch refusal's `note` (`lua/core/tools.lua`, `aed06b82`), built with this node's name and the
   entry's path:

   > The picture <image> on <node> was not sent: a calls batch carries text only (1-8 reads in one
   > signed round trip). Read it as its own call - tools.remote({node:"<node>",capability:"read",path:
   > "<path>"}) - and the picture arrives with that call result, up to 1000000 bytes.

   and its `fix`:

   > send {"node":"<node>","capability":"read","path":"<path>"} as its own remote call, not as an
   > entry of calls

2. The `remote` tool description, cut to Fable's exact words:

   > Text reads work. A picture read (png, jpeg, gif, webp, up to 1000000 bytes) returns the picture
   > with this call's result; not inside a calls batch.

   `scripts/sync-prompt-docs.sh` is current with it (4 blocks), and no golden or snapshot under
   `fixtures/` carries the old sentence.

No other model- or operator-facing string changed on this branch. The peer's operation answers, the CLI
row texts and the 1 MB refusal sentence are the ones `5f95d54a` shipped.

## Proposed FACTORY.md text (propose, never write)

> **A wire seam proved with a stub is not proved.** A row that judges what crosses between two nodes
> stubs `nodes.remote_call` and is green whatever the wire does with the arguments - two faults of the
> 24/11 round lived exactly there: the caller never sent the field the peer's branch required, and a
> peer's bash is adopted as an operation and never reaches the branch the stub stood in for. A change
> that touches what CROSSES a node boundary carries one row that runs real processes on one machine
> (own homes, real ports, a signed roster, and a scratch rendezvous when the admission basis needs one),
> narrowed to under 60 s; the module seam stays for the branches that cannot cross.

> **A row must be green on the basis the fleet runs, not on the special path it happens to exercise.**
> The 24/11 picture round first proved itself on an attested admission that was not approved for the
> release, on a pair whose rendezvous did not know the caller; on the fleet's own basis (a registry that
> knows both nodes, `verify_caller(fresh)`) the same transfer needed nothing new at all. A row about two
> nodes states WHICH admission basis it stands on, and a basis nobody runs yet is named as a review item
> rather than wired into a release's proof.

## Proposed HANDOVER.md text (propose, never write)

> **A picture crosses a node boundary** (`5f95d54a`, `e7a9d264`): a `read` of a picture on a peer answers
> the bytes under a 1,000,000-byte cap, the caller verifies the digest the peer named and stores it here,
> and it reaches the model as one image part attached to that call's result. Proved on a scratch pair on
> the fleet's own admission basis (a rendezvous that knows both nodes) by
> `scripts/test-two-node-images.lua`. A `calls` batch carries text only and its refusal names the single
> call (`aed06b82`). A peer's command draws one row per file it changed (`544ae50e`). Nothing else
> carries pictures yet: `whatsapp_download` still answers a path on the node that holds the account (see
> item 4 above). The mount's attested admission path is NOT wired for v0.1.2 - it is
> `change/attested-admission-review`, awaiting a security review.

## The narrowed runner run, on the final tip

At `20fde764`, `scripts/fast.sh` narrowed to this branch's five rows (plus the never-dropped core rows
and every contract check):

    fast: lua 34/34 passed
    fast result FAILED (132 checks, 1 failed, 0 skipped)
    fast path FAILED (1 of 132 checks, 0 skipped, 621s)

The one red is `esc-stops-pty` (pre-existing, measured above). `install-guards` passed in this run after
failing in two earlier ones with the same 6-of-72 in this tree and in the base worktree: it is
load-dependent, not this branch's, and it is reported as flaky rather than green.

Each row was ALSO run alone with this tree's release binary (which the runner builds):
`test-two-node-images.lua` 51 checks / 0 skips, `test-peer-bash-changes.lua` 17, `test-remote-image.lua`
47 - and on a worktree of the base commit (`git worktree add /tmp/base-two-node e832e152`), where the
two-node row fails at the change-row check and `test-peer-bash-changes` at `the caller emits one row per
file: 0`, and `test-remote-image` at `expected remote_image_batch_unsupported`.

## The land gate: red once, and why

The first preflight of this branch was red on `land-quick` with `key_path_in_git_checkout`: the landing's
dry run puts its scratch root INSIDE the land worktree (`.wa-scratch`, a git checkout), and
`wa fleet keygen` refuses a key path there by its own guard - a key must never be something `git add`
reaches. The row now picks the pair's tree from the first candidate git says is NOT a repository
(`TMPDIR`, then `/tmp`, then `GATE_ROOT`), prints which it chose, and skips with a named reason if every
candidate is a checkout. The home the runner hands the row stays where the scratch-home guard requires
it; only the pair's own tree moves. No assertion was deleted, no row dropped, no timeout raised.

Measured after the fix, in the preflight's own shape (`GATE_ROOT` and `TMPDIR` both inside this
worktree): 51 checks, 0 skips. And the preflight itself:

    preflight green (quick, no gate): change/run-images-two-node on main b9ec52280260 in 8s
    land-quick: change/run-images-two-node merged onto main b9ec5228 -> 8584ce36 (9 files)

The narrowed runner run on the same tip (`d1be28a0`): `lua 34/34 passed`, `132 checks, 1 failed` -
`esc-stops-pty`, the pre-existing red below.

## Pre-existing failures, measured on the base tree

Both are outside this branch's files and fail with the same words and counts in this tree and in a
worktree of the base commit:

* `esc-stops-pty` (`scripts/test-esc-stops-pty.mjs`): `17 ok, 1 failed`, `FAIL - bash: Esc ends the run at
  once, by the node clock ...`;
* `install-guards` (`scripts/test-install-guards.sh`): `72 checks, 6 failed`.

`scripts/test-mesh-live.sh` also fails on this node before any call (it copies the signed roster to
`$HOME_OP/.wasm-agent/mesh-roster.json` and the call answers `roster_unreadable: ... No such file or
 directory`); outside this branch, same on the base.

## How the stores were read (the 24/11 rule)

Every check reads what the product itself wrote: the two homes are the nodes' own (`WASM_AGENT_HOME`),
both stores are the files `memory.store_image` wrote under `paths.data()/attachments`, the peer's
operation record is its own `operations/<id>/state.json`, the mesh verdict is the peer's own audit line,
and the admission is the scratch rendezvous's own answer through `nodeslib.verify_caller`. No product
table was created by hand and no host capability was stood in for.
