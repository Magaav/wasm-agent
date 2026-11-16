# The mesh-control queue

The ordered work to get from "the fabric works" to "the fabric is ours, and the fleet does the work".

State, 16/11 end of day: five nodes up (`work`, `openclaw`, `avell`, `nextcloud`, `mail`), `work`,
`openclaw` and `avell` masters, every pair calling every other in all three directions, the operator
set admitting a new master through a signed `POST /operators` instead of an edit on the always-on host,
and `avell` having promoted and demoted `nextcloud` by itself. One defect is open and parked
(`bad_signature` on a relayed roster call, evidence in [MESH-MODULE.md](MESH-MODULE.md)).

This file is the queue: one block per item, in the order we intend to do them. A worker takes a block,
does it, and reports against its **done-when**. The orchestrator (pi) reads this file and nothing else
to decide what to hand out.

## Rules for every item

- One writer per branch. Two agents never touch the same branch at once.
- A deploy is announced, staged one node at a time, and has a rollback pin ready before it starts.
- Nothing is "done" without the command that proves it, run against the live fleet.
- If an item needs the operator (a guarded file, a vault, a human consent), it stops at that line and
  says so — it does not find a way around the guard.

---

## 0. A node that can run a turn — id: `queue-model-node` (blocks the rest)

**State, measured 16/11.** The CodeAct work is **landed**: `land54` (codemode index, tools in use first),
`land55` (`abjoin2` + `components.lock` `wa-whatsapp` LID↔PN join, bundle `components-033542eb9a37`
published) and `land56` (`WASM_AGENT_RAW_CODE=first`) are all on `main`, and this branch sits on top of
them. Nothing is missing from the code.

What is missing is a node able to **start** a turn: `openclaw` is *declared* model-less on purpose
([MODEL-LESS.md](MODEL-LESS.md): its provider answered 401 and produced three empty turns in seven days,
which look handled), and `avell` has no provider configured at all (`0` `WASM_AGENT_LLM_*` keys).
A session started on `openclaw` ends in two messages: the prompt and
`node_model_less`. So CodeAct cannot be exercised by anyone today.

**Done when.** One node declares a model that answers — `wa chat --once "list the entries of / and say
CODEXACT_OK"` produces an observation whose action was **code**, not tool JSON, and `wa services list`
shows that node's model state. Then the two checks that were queued in the session that built this:
the index lists tools in use first, and the `wa-whatsapp` alias join resolves a chat saved as a name
("Laura <3" style) to its LID.

**Needs the operator.** Which provider, on which node, and with whose key. The laptop already runs a
provider proxy (`wa-vault`, `127.0.0.1:8810`); making it reachable from `avell` over the LAN, or giving
`avell` its own key, is a credential decision — not something a worker item can decide for itself.

---

## 1. `wa network operator add <node-id>` — id: `queue-operator-verb`

**Goal.** The signed `POST /operators` request, built by hand on 16/11 (`wa node sign` + `curl`), becomes
one command any operator runs from any node.

**Done when.** On a master, `wa network operator add <id>` adds the operator and `wa network operator
list` shows it; a guest gets a named refusal (`administrator_required`); removing an environment-named
operator refuses with `operator_from_environment`; one test covers all three.

**Size.** ~30 lines of Lua plus a test. No deploy risk: a CLI verb.

---

## 2. `scripts/fleet-add-master.sh` — id: `queue-add-master`

**Goal.** Adding a master becomes one command: signed operator add → per-peer re-consent (`unbind`,
`bind permanent`, `accept` from an operator) → registry role re-check → roster revision signed with the
fleet key and pushed → verification matrix printed.

**Done when.** Against the live fleet, one invocation adds a node (or re-adds one) and prints a matrix
where every direction answers; the script backs up `binding.json` on every peer it touches and refuses to
continue if any peer ends without `relation: same` after its next registration.

**Depends on.** 1.

**Size.** An afternoon. This is the item that makes "switch a master" a single action.

---

## 3. A fleet update channel that carries our signature — id: `queue-signed-fleet-release`

**Goal.** Today the fleet runs ad-hoc builds: `avell` and `openclaw` compiled the same commit with
different toolchains, and the only signer the installer trusts (`release-signing`) lives in a vault we
cannot reach. Introduce a **fleet channel**: a manifest of artifact digests signed by a `fleet-release`
key in the operator's vault, verified offline by every node with the same pattern the roster uses
(pinned public key, monotonic revision, `prev_hash`, named refusals).

**Done when.** A node installs an artifact from the fleet channel, refuses an unsigned one, refuses a
rolled-back revision and a same-revision fork by name, and `wa update <node> --binary` can consume it.

**Size.** 1–2 days. This is the item that makes "update a node" trustworthy instead of hopeful.

---

## 4. Rollback, rehearsed — id: `queue-rollback-drill`

**Goal.** `wa update --rollback` and the sentinel's `.prev` exist and were never used. One drill: install
a new build on `avell`, break it deliberately (a bad flag), roll back with the tool, and prove `/health`,
the version and one cross-node call come back.

**Done when.** The drill is written into the runbook with the exact commands and the observed timings,
and a second person could repeat it from the page alone.

**Size.** Hours. Do it before anything else is deployed to the cloud nodes.

---

## 5. No per-peer re-consent — id: `queue-drop-reconsent`

**Goal.** A new master currently costs N re-consents and a ~60 s window where the re-bound node is
`guest` in the registry. Remove that cost, two ways measured against each other:
(a) finish the attestation path (`bad_signature`) so the roster alone decides — the design's own answer;
(b) an explicit policy option that authorizes against the registry's *current* operator list instead of
frozen pins — cheaper, weaker (any operator the registry vouches for may drive that node).

**Done when.** A new node reaches the full matrix with **zero** peer re-consents, or with one documented
flag per peer, and the chosen trade-off is written down where an operator will read it.

**Depends on.** Nothing, but (a) needs the fixture test first — [MESH-MODULE.md](MESH-MODULE.md) says
which one and why.

---

## 6. The WIT/WASI move — id: `queue-mesh-component`

**Goal.** The migration the design page already sets: signed component pins → `wa:mesh` release #1
carrying the relay hop and the admission → signature-pinned Lua tree. Until the last step lands, every
policy change is a fleet-wide binary rollout, which is exactly what 16/11 cost.

**Done when.** A policy-only change (the `lowered`/`header_pairs` class) reaches every node with no
binary rebuild, and a component update is refused by name when its pin is older, forked or unsigned.

**Size.** Multi-day. Do not start before 3 and 4.

---

## 7. The two single points — id: `queue-two-paths`

**Goal.** Every cross-node call is relayed through one host and the registry runs on that host. Give each
node a second way to be reached (a DNS name or an overlay address in the roster — the roster resolves
names, so an ISP rotating an IPv4 costs nothing) and decide, in writing, what the fleet does when the
registry's host is down: today everything already attached keeps working on the relay it holds, and
nothing new can join.

**Done when.** With the registry host's relay unavailable, two nodes that have each other's address still
complete a call; and the runbook names the failure mode and the recovery.

**Size.** Infrastructure, half a day plus the port/overlay decision — which is the operator's.

---

## Out of scope here

- The Conversas & Cia / CDA queue. Different lane, different repo.
- Anything that edits `/docker/*` on beequeen by hand, or touches another team's service.
- Building the overlay ourselves: the fleet uses the one it already has.
