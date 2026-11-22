# whatsapp-finds-owner — a WhatsApp call on a node without the account reaches the node that has it

Branch `change/whatsapp-finds-owner`, base `c9904f6e`. Committed locally, **not pushed**, as this
mission's brief says. Commits: `1f71e522` (owner lookup + routing), `535ac807` (nodes() budget and the two
new rows), `2baae138` (the timeout branch kept beside the pending one), `db874a50` (a gate check that was
red for the wrong reason — see "One check that was red for the wrong reason"), then the review round of
23/11: `d7378fdc` (the three MUSTs of that review in the routing + the row section for MUST 1),
`daedfeb6` (the row section for MUST 2), `88403d90` (the row section for MUST 3, and the attachment of
`discarded_job` moved to the answer the caller actually sees).

**The three MUSTs share one code commit (`d7378fdc`), and that is a process mistake of this round**: they
were written in one pass before the first commit, so `git show d7378fdc` contains all three. Each one's
test was proved to fail WITHOUT its own fix by reverting exactly that fix in a throwaway worktree of
`HEAD` — the three measurements are quoted under "The review round" below — but the code itself is not
split into three commits, and a reader of the history should know that before `git log -S`.

## The cause, in one paragraph, before anything was changed

Re-measured on avell first (23/11). `mcp_whatsapp_contacts {q:"Laura"}` answered **202
`whatsapp_contacts_slow`, `state:"queued"`, id 1**, in 2.13 s, with the note "no node in this fleet says it
runs wa-whatsapp" — while `tools.remote({node:"openclaw", capability:"federation", args:{action:"catalog"}})`
answered in **1.04 s** with a connector row `{"id":"whatsapp","whatsapp_account":true,...}`. So the fleet
*did* say who holds the account, and the router never saw it: `federation.refresh`
(`lua/core/federation.lua:444-452`, before this branch) stored each peer's `tools` and **dropped
`answer.connectors`**, the one field `whatsapp.owner` reads (`peer.connectors[*].whatsapp_account`,
`lua/core/whatsapp.lua:447`). The cache is the only fleet fact the router has, so `owner()` returned nil
on every node whose cache came from a refresh, `route()` answered "ask locally", the local capability
queued a job nothing can settle, and the model read that id — the exact 13/11 defect the file's own
comment says was fixed, reopened through a missing assignment. `M.remember` (the `/mcp` control path)
always kept `connectors`; the refresh was the other half and never had them. The previous routing test
(`scripts/test-whatsapp-route.lua`) passed because it injects `ctx.owner_catalog` and never touched
`refresh` — a parity gap, now covered by `scripts/test-whatsapp-finds-owner.lua`.

The 20 s of `tools.nodes()` is a **separate defect**, measured again (20.46 s, 20.36 s, 0.25 s for three
calls in a row): the `nodes` tool called `nodes.list()` with no options, which starts one `wa nodes probe`
child per peer and waits out `PROBE_DEADLINE_S = 20` (`lua/core/nodes.lua:320`), and then **cancels** the
child that has not answered and publishes `probe_timeout` (`nodes.lua:641-645`). It is fixed here (item 3
of the brief) rather than written up separately, because it is one of the two things the measured turn
paid for; what it does *not* prove is in "What I did not verify" below.

## What changed, claim by claim

| item | change | commit |
|---|---|---|
| 1 | `federation.refresh` keeps `answer.connectors` for every peer that answered | `1f71e522` (`git show 1f71e522 -- lua/core/federation.lua`) |
| 1 | `whatsapp.route` returns the owner from evidence taken BEFORE any local call: the deploy's `WASM_AGENT_WHATSAPP_OWNER`, then a peer whose connector says `whatsapp_account = true`, then the single peer that lists `mcp_whatsapp_*` (connector tools, or its roster capabilities) | `1f71e522` (`lua/core/whatsapp.lua` `M.owner_evidence`, `M.route`) |
| 1 | a send on a node without the component is asked of the owner (same chat+text+reply_to = the same job), never queued here; the local job it did write is named `discarded_job` | `1f71e522` (`M.send`) |
| 2 | two owners = `whatsapp_account_ambiguous` with `candidates` and `ask_with`; nobody known + two that can answer = `whatsapp_component_absent` with the same two fields; the sentence "no node in this fleet says it runs wa-whatsapp" is emitted only when the fleet lists nobody | `1f71e522` (`M.routing_refusal`) |
| 2 | the refusal never queues anything: with two candidates the decision is taken *before* this node's own capability is asked | `1f71e522` (`M.call`, `M.send`) |
| 3 | `nodes.list` takes `wait_s` (how long THIS call waits) and `keep_running` (a child that has not answered is left running, never cancelled, no negative published), and reports `capabilities_at` / `capabilities_age_s` per peer | `535ac807` (`lua/core/nodes.lua` `probe_peers`, `M.list`) |
| 3 | the `nodes` tool asks for a 0.5 s wait with `keep_running`, and its note explains the age fields and `probe_pending` | `535ac807` (`lua/core/tools.lua`) |
| 3 | `nodes.known_capabilities()`: what this node already knows about its peers and how old it is, from the probe lease and the in-process cache — no probe, no wait, no network | `535ac807` |
| 4 | no tool schema and no prompt text changed: `git show 1f71e522 535ac807 --stat` lists `lua/core/{federation,whatsapp,nodes,tools,refusal,refusal_codes}.lua` and two rows (`scripts/test-whatsapp-finds-owner.lua`, `scripts/test-nodes-answers-now.lua`) plus one assertion in `scripts/test-whatsapp-one.lua`; `M.schemas()` and the `nodes` schema (`schema("nodes", "List this node and every peer known to the rendezvous.", {})`) are untouched, so the prefix hash does not move | `1f71e522`, `535ac807` |

`lua/core/refusal_codes.lua` was regenerated with `lua5.4 scripts/gen-refusal-codes.lua --write` (one new
code), and `scripts/test-refusal-contract.lua` passes (17 004 checks).

## One assertion changed in an existing row, and why it is stricter

`scripts/test-whatsapp-one.lua:239` asserted that *both* "nobody names an owner" and "two nodes claim the
account" answer `whatsapp_component_absent`. Item 2 of the brief separates those two facts, so the row now
pins each case to its own word (`whatsapp_component_absent` / `whatsapp_account_ambiguous`); every other
assertion in that block is unchanged and still holds (`owner == nil`, `effect == "none"`, `id == nil`,
`hops == 0`, the note names `WASM_AGENT_WHATSAPP_OWNER`). On the base, the ambiguous case answered the
false sentence "no node in this fleet says it runs wa-whatsapp" while two nodes said they held it — the
verbatim output is in the transcript of the base run below.

## Tests

New: `scripts/test-whatsapp-finds-owner.lua` (37 checks) and `scripts/test-nodes-answers-now.lua`
(15 checks). Both are hermetic (scratch `WASM_AGENT_HOME`, refused when it is the operator's — 
`scripts/lib/scratch-home.lua`), both stub the fleet and the host, neither calls a live node.

Wired: the fast path discovers every `scripts/test-*.lua` that is not in `scripts/fast-path.exclude`
(`scripts/fast.sh`, header item 1) — both new files are picked up there with no edit, and the parity runner
(`scripts/test-core-parity.sh`, invoked from `scripts/test.sh:1567`) runs the same set once natively and
once inside the guest core. Neither file is excluded and neither is added to `scripts/test.sh`'s own
explicit list, which is the same treatment every other `scripts/test-*.lua` row gets.

**They fail on the base, measured** (a worktree of `c9904f6e`, the new and changed rows copied in, run the
same way):

```
--- scripts/test-whatsapp-finds-owner.lua rc=1
lua error: ...:26: the refresh KEEPS the peer connectors (the field whatsapp.owner reads):
  {"at":1700000000,"name":"openclaw","node_id":"peer-1","tools":[{"description":"email_read",...}]}
--- scripts/test-nodes-answers-now.lua rc=1
lua error: ...:28: the nodes tool asks the list for a roster: null
--- scripts/test-whatsapp-one.lua rc=1
lua error: ...:244: with no single owner a send refuses (two):
  {"error":"whatsapp_component_absent","note":"this node runs no wa-whatsapp component; no node in this
   fleet says it runs wa-whatsapp (set WASM_AGENT_WHATSAPP_OWNER on this node, ...)",...}
```

The timing row measures REAL time: its host stub sleeps the `wait_ms` the caller asks for, through the real
`host.sleep`, so an unbounded wait costs ~20 s in that row and the assertion (`elapsed <= 1`, and
`waited_ms <= 1000`) fails there — it is not an assertion about an argument.

## One check that was red for the wrong reason (`db874a50`)

`scripts/test-whatsapp-go-retired.sh` failed in this worktree and nowhere else: "FAIL no Go WhatsApp source
file and no go.mod naming the connector". The cause is the checkout's PATH, not the tree:
`source_findings` grepped the ABSOLUTE path for "whatsapp", so in
`/home/victor/Work/missions/whatsapp-finds-owner/wt` every `.go` file matched — measured, the two
legitimate `benchmarks/service-component-spike/guest/*.go` fixtures, on a tree where the same check passes
from `/tmp/wt-base` (same commit, path without the word). Two changes, both in that one file: the match is
now on the path INSIDE the tree (which is what the script's own header describes, "a `*whatsapp*.go`
file"), and `runs()` collects the finder's output instead of piping it into `grep -q` (a finder that
writes after the reader exits died on SIGPIPE, which `set -o pipefail` reports as the finder failing —
measured as exit 141 on the fixture). The 18 checks, including the four planted-path proofs, pass in this
tree and in the base worktree with the same file.

## Texts to approve (model- or operator-facing, verbatim)

1. `whatsapp_account_ambiguous` (new refusal code, `lua/core/refusal.lua`): "two nodes say they hold the
   WhatsApp account, so this node will not pick one (`{origin}`)." — fix: "read `candidates` for both
   nodes, then ask one of them with the `ask_with` call it carries; or set WASM_AGENT_WHATSAPP_OWNER on
   this node to name the one that must answer. Nothing was queued here."
2. Ambiguous answer note (`M.routing_refusal`): "2 nodes say they hold the WhatsApp account (openclaw,
   work), so this node will not guess which one answers: ask one of them directly with
   tools.remote({node="openclaw", capability="mcp_whatsapp_read", args={"chat":"Laura"}}), or set
   WASM_AGENT_WHATSAPP_OWNER here to name the one that must answer. Nothing was queued here."
3. "Surface but no account" answer note (`M.routing_refusal`, the case where the fleet lists nodes that can
   answer but none that says it holds the account): "this node runs no wa-whatsapp component and no node in
   this fleet says it holds the account; openclaw, work can answer, or can name the node that does: ask it
   with tools.remote({node="openclaw", capability="mcp_whatsapp_read", args={"chat":"Laura"}}). Nothing
   was queued here."
4. The refusal's two new fields: `candidates` (`[{name, why, tool, says, at, age_s, call}]`) and
   `ask_with` (the exact `tools.remote({...})` string).
5. Send on a node that queued locally with nowhere to route it: "… this node runs no wa-whatsapp component,
   so nothing here sends that job: the fleet names openclaw - ask it with tools.remote({node="openclaw",
   capability="mcp_whatsapp_send", ...})" (or, with no candidate at all, "…: set WASM_AGENT_WHATSAPP_OWNER
   here, or enable the component where the account is"). `effect` stays `unknown`; the local job keeps its
   id.
6. `nodes` tool note, appended: "capabilities_age_s: how old the peer's capabilities answer is
   (capabilities_at is when it was produced); capabilities_reason probe_pending means a probe is running and
   had not answered when this list was drawn - ask again in a second and it is there."
7. New per-peer field `capabilities_reason = "probe_pending"` (named, instead of a cancelled
   `probe_timeout`), beside the existing `not_asked` / `remote_unreachable` / `probe_capacity`.
8. `whatsapp_no_owner_on_this_node` (new refusal code, `lua/core/refusal.lua`): "this call arrived from
   another node, and this node neither holds the WhatsApp account nor knows which node does
   (`{origin}`)." — fix: "read `arrived_from` and `candidates`: the call is answered or refused here and
   never forwarded again, so start the component on this node (`wa services start wa-whatsapp`) or set
   WASM_AGENT_WHATSAPP_OWNER here to name the account node. Nothing was queued here."
9. Arrival refusal note (`M.arrival_refusal`): "this call arrived from peer-a; this node runs no
   wa-whatsapp component and does not know which node holds the account, so it is answered or refused here
   - a call is never forwarded back to the node it came from (that is how two nodes without the component
   bounce one call between them for ever). Start the component here (wa services start wa-whatsapp), or set
   WASM_AGENT_WHATSAPP_OWNER on this node to name the account node." — fields: `arrived_from`, and
   `candidates` / `ask_with` for any OTHER node it knows.
10. Send refused on weak evidence: the note listed as item 3 ("this node runs no wa-whatsapp component and
   no node in this fleet says it holds the account; openclaw can answer, or can name the node that does:
   ask it with tools.remote({…, capability="mcp_whatsapp_send", …}). Nothing was queued here."), now also
   emitted for a SEND whose fleet only shows nodes that can answer.
11. Cancel did not answer (fields `discard_failed` and this sentence appended to the owner's answer):
   "this node had queued the same message as job 9 and the cancel did not answer
   (whatsapp_send_not_cancellable): if wa-whatsapp is started on this node that job may still be sent -
   cancel it with mcp_whatsapp_send({cancel=9})".
12. Read job left behind (field `left_job`, replacing what the read path used to call `discarded_job`):
   "this node queued the same read as job 42; nothing here settles it, and the account node answers the
   same call".

## The review round, 23/11: three MUSTs about sends and hops

**MUST 1 — a send never hops on weak evidence** (`d7378fdc`). `M.route(ctx, strict)` takes the strictness
from its caller: `M.send` passes it, `M.call` does not. A message is forwarded only to the node
`WASM_AGENT_WHATSAPP_OWNER` declares, or to the one whose own connector answers
`whatsapp_account = true`; a single weak candidate — a peer that merely admits the nine verbs — routes a
read and never a send. With any evidence and no strong owner the send refuses *before* this node's own
capability is asked, so nothing can be queued either: `whatsapp_component_absent`, `effect = "none"`,
`candidates` + `ask_with`. Measured on the tip `be9e67ef`: the same call answered
`{"served_by":"openclaw","asked_owner":"openclaw","state":"done","id":5,"ok":true}` — it took the hop.

**MUST 2 — no ping-pong** (`d7378fdc`). A peer call arrives through one seam (`server.wa_peer_dispatch`,
`lua/core/server.lua:1525-1550`) carrying `peer_call = true` and `session_id = "peer:<caller>"`;
`M.arrived_from(ctx)` reads exactly that. An arrived call is `strict` whatever the caller asked, the node
it came from is never a routing target, and when no owner is left the answer is
`whatsapp_no_owner_on_this_node` (`M.arrival_refusal`) with `arrived_from` and any other candidates — it
is answered or refused here, and nothing is queued on either side. Measured with the guard reverted (a
worktree of `HEAD` with `M.arrived_from` returning `nil`): B forwarded the call back to `avell`, the node
that had just asked it — `{"error":"whatsapp_account_unreachable","account_lives_on":"avell",
"served_by":"openclaw"}`. That is the loop.

**MUST 3 — `discarded_job` must be true** (`d7378fdc`, with the attachment fixed in `88403d90`). A send
that this node queued and then routed leaves a job in THIS queue; naming it discarded without cancelling it
is a claim, and if `wa-whatsapp` is started here later the same message leaves a second time.
`M.discard_local(id)` sends the queue's own cancel (`{id, cancel = true}`, the request
`rust/wa-capabilities/src/whatsapp_send.rs:246-262` answers with `cancelled = true` or
`whatsapp_send_not_cancellable`), and `discarded_job` is set ONLY when that answer said `cancelled = true`;
otherwise the answer carries `discard_failed = {id, error, note, state}` and a sentence saying the job may
still go out with the call that stops it. Two things this round found and fixed on the way: the fields were
attached to the *queueing* answer, which `M.settle` then replaced (so a caller never saw them) — they are
now attached by `with_discard` to the answer that is actually returned; and a READ job cannot be cancelled
at all (the cancel is the outbox's: any other queue answers `whatsapp_send_unknown_id`), so a read names
`left_job`, never `discarded_job`. Measured with the cancel reverted (`M.discard_local` returning the id
without asking): the row's cancel assertion saw no cancel request — `[]`.

Each of the three was verified to fail without its own fix; all three are in one row,
`scripts/test-whatsapp-finds-owner.lua` (59 checks), which the fast path and the parity runner pick up
like every other `scripts/test-*.lua`.

## What was run, and the one red row

`flock -o ~/Work/missions/.suite.lock bash scripts/fast.sh` in this worktree at `88403d90` plus the
report commit (452 s, nothing else running on the box):

```
fast: lua 310/310 passed (58 excluded: scripts/fast-path.exclude)
fast: rust - no crate touched
fast: discrimination ok (2529ms)
fast: install-guards ok (1804ms)
fast: whatsapp-go-retired ok (244ms)
fast result ok (385 checks, 0 failed, 0 skipped)
fast path ok (385 checks, 0 skipped, 452s)
```

Both new rows are among the 310; `discrimination ok` is the gate's own check that runs the rows this
branch adds or changes against the base with only the non-test changes reverted.

Two rows were red in earlier runs of this session and are named here because a reader will find them in
those runs' logs — neither is this branch, and both pass in the clean run above:

- `install-guards` (`test-install-guards: 72 checks, 6 failed`): the turn guard. `scripts/upgrade.sh`
  refuses with "upgrade: refused inside a turn running on the node it would replace"
  (`scripts/upgrade.sh:42`; `turn_owner`, `scripts/lib/turn-guard.sh`, walks `/proc` for an ancestor
  `wa serve`), so the six cases expecting `refused(candidate_commit_unknown)` and the override path never
  ran. Measured twice: reparented outside the node's turn (`setsid --fork bash -c '… bash
  scripts/test-install-guards.sh'`) it answers `72 checks, 0 failed`, and it answered `ok` inside the
  later suite run. No file that row reads is in this branch's diff.
- `scripts/test-start-instant.lua` (`start-instant: 1 FAIL`): a timing row — "the model call starts in
  under 1 s (`gap_ms < 1000`)" — that failed once inside a loaded suite and passed twice standalone
  immediately after (`start-instant ok`), and inside the clean run above.

## What I did not verify, and what I did not do

- **I did not run Victor's test** ("read my last 3 WhatsApp messages from Laura" in a new `wa chat` on
  avell, 3-4 model rounds instead of 9). That needs the branch built and installed on avell, which this
  mission's rules forbid (never deploy, never build on another node, never push). What is verified is that
  the mechanism which failed now answers: the owner is found in the cache the refresh writes and the call
  takes one hop (rows above), and `nodes()` is bounded.
- **The 20 s itself is bounded, not explained away.** I measured the tool at 20.46/20.36/0.25 s and bounded
  it to 0.5 s of waiting; I did **not** establish why a `wa nodes probe openclaw` child needed more than 20 s
  in that session (the same peer answered a `federation` catalog in 1.04 s). That is a separate question,
  written up in the brief below and left open.
- The `probe_pending` answer is honest but not free: the first `nodes()` call in a window where no child
  has settled returns `capabilities = nil` for that peer; the answer arrives on the next call, when the
  child has published on the lease. No test proves the child actually publishes inside that window against
  a real peer — the row proves the child is started, not cancelled, and joined.
- **The MUST 3 path is narrow, and the row says so.** With MUST 1's strict route, a send reaches
  `M.discard_local` only when the fleet names no owner at routing time AND the capability's own answer
  names one (`decoded.owner`, the field `component_absent` sends when the deploy declared an owner) while
  a job exists — a queued answer carries no `owner` of its own, so the two facts meet only when the fleet
  changed between the two reads or the capability answered both. The cancel is implemented and tested for
  that shape; I did not find a live traffic path that produces it, and I did not invent one in `rust/`.
- I did not verify Victor's test on avell for this round either (no build, no install, no push here), and I
  did not re-run the two-node `A → B` case against two REAL `wa` processes: the arrived side is driven
  through the real `wa_peer_dispatch` seam, but both nodes live in one interpreter in that row.
- I did not change `rust/`: the queue job on a non-serving process comes from
  `whatsapp_query::component_missing` returning `None` when `serve::serving()` is false
  (`rust/wa-capabilities/src/whatsapp_query.rs:145-155`). Routing in Lua now prevents that call from being
  made at all when the fleet names an owner; the case where the fleet names nobody still queues, and the
  answer says so.

## A brief for what is left (item 3's residue)

**why-probe-takes-20s** — one `wa nodes probe <peer>` child against a peer that answers a signed
`federation` call in ~1 s took the whole `PROBE_DEADLINE_S` in the 22/11 session on avell. Measure, inside
one turn: the child's own output, its process state, whether `host.operation read` sees a partial answer,
and whether the hold is the relay attach (`nodes.reachable`) rather than the peer. Until that is known,
`nodes()` is bounded but its capability columns are late by one call in a cold window.
