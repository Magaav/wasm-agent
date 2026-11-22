# whatsapp-finds-owner — a WhatsApp call on a node without the account reaches the node that has it

Branch `change/whatsapp-finds-owner`, base `c9904f6e`. Committed locally, **not pushed**, as this
mission's brief says. Four commits: `1f71e522` (owner lookup + routing), `535ac807` (nodes() budget and
the two new rows), `2baae138` (the timeout branch kept beside the pending one), `db874a50` (a gate check
that was red for the wrong reason — see "One check that was red for the wrong reason").

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

## What was run, and the one red row

`flock -o ~/Work/missions/.suite.lock bash scripts/fast.sh` in this worktree at `db874a50` (715 s):

- `lua 310/310 passed (58 excluded)` — both new rows are among the 310;
- `rust - no crate touched` (no Rust file is in the diff);
- `discrimination ok` — the gate's own check that runs the rows this branch adds or changes against the
  base with only the non-test changes reverted;
- `whatsapp-go-retired ok` (the row that was red in the run before `db874a50`);
- every other contract check ok, **one red**: `install-guards` (`test-install-guards: 72 checks, 6 failed`).

That red is the turn guard, not this branch. `scripts/upgrade.sh` refuses with "upgrade: refused inside a
turn running on the node it would replace" (`scripts/upgrade.sh:42`, `turn_owner` in
`scripts/lib/turn-guard.sh` walks `/proc` for an ancestor `wa serve`), so the six cases that expect
`refused(candidate_commit_unknown)` and the override path never run. Measured: the same command run
reparented outside the node's turn, `setsid --fork bash -c '… bash scripts/test-install-guards.sh'`,
answers **`test-install-guards: 72 checks, 0 failed`**. No file this row reads is in this branch's diff
(`git show --stat db874a50 2baae138 535ac807 1f71e522`). A suite started from inside a node turn cannot
pass that row, which is the guard doing its job.

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
