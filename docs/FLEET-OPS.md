# Fleet operations: the harness layers that make an agent careful

This file is the home of five layers that were added together on 10/11 as one piece of work: **operating
habits** in the base instructions, a **`fleetops` skill**, a **`lessons` store**, a one-call **`fleetview`**
capability, and a **shipped default guard** that refuses the two commands that took this fleet offline.
The sixth piece, **router modules** (routing policies as replaceable components), is the model gateway's
own; it is documented in [MODEL-GATEWAY.md](MODEL-GATEWAY.md#router-modules).

Read this before touching the guard, the lessons store or a routing policy. Read `skills/fleetops/SKILL.md`
when the task is *about* the fleet itself.

## Why (the incidents, not a hypothesis)

The laptop agent twice "fixed" fleet control by adding itself to the rendezvous admin list
(`WASM_AGENT_NETWORK_ADMINS` in `/etc/systemd/system/wa-rendezvous.service.d/managed.conf` on `openclaw`)
and restarting `wa-rendezvous`. Nodes pin the admin set they were bound with, so the change **detached
them**: `nextcloud` and `mail` were offline for 18.5 hours on 06/11 and about an hour again on 08/11. The
same agent also rebuilt Rust for ~40 minutes in a 2-core container (capacity never checked) and
backgrounded `cargo` inside one bash call (the effect was then unknown).

Three of those are judgement failures that a *rule* could not prevent, so each incident became a stored
lesson with a symptom, a cause, a fix and a rule (`skills/fleetops/incidents.json`), and the two
destructive commands became a **refusal** at the tool boundary.

## 1. Operating habits — the cache-stable prefix (`lua/core/habits.lua`)

`lua/core/agent.lua` renders the `generic` layer once per session (`identity`, `work`, `habits`, `style`,
`language`, `time`, `memory`), and `lua/core/prompt_cache.lua` freezes those bytes for the session. The
habits therefore arrive **once**, in the cache-stable prefix, in every request of every session, for
every role.

The list: look before changing; know the blast radius; the reversible supported path first; cheapest
check first; back up before editing config; one change at a time; long work via a managed operation;
verify the effect, not the command; check the side effects; distrust misleading results (an empty value, a
refused call that ran); roll back fast; record the lesson and turn a repeated failure into a rule; report
plainly, including your own mistakes.

Two constraints are part of the contract, and a test enforces both:

* **Advice, never a budget.** No turn count, no token budget, no "wrap up" nudge. The hard rule behind
  this file: guards may refuse *specific known-destructive actions*, and nothing may force the model to
  stop working. `scripts/test-fleetops.lua` fails if that vocabulary appears.
* **Stable bytes.** No clock, no node name, no tool-catalogue text: two renders are byte-identical, and
  the test compares them.

## 2. The `fleetops` skill (`skills/fleetops/SKILL.md`)

What the fleet is (nodes, rendezvous, relay, roster/fleet key, pins/operators, sentinel, services, jobs),
how to diagnose a node that went offline (cheapest first: `fleetview` → `nodes`/`operator_of_peer` → the
rendezvous journal → the node's own log → lessons → the operator route), and the **NEVER** list, each
entry with the safe path beside it:

| never | safe path |
| --- | --- |
| edit `WASM_AGENT_NETWORK_ADMINS` or the rendezvous drop-in to gain control | `wa fleet push-roster <node>` |
| restart `wa-rendezvous` to apply it | change the node, not the shared directory |
| hand-edit a production checkout | land it through Git (`change/<name>` → main) |
| deploy from a dirty tree | commit, verify clean, then `wa-sentinel request deploy` |
| stop a node by image name; replace the window | the pid in `serve.pid`; the sentinel / a page reload |
| manufacture settlement for an unknown effect | reconcile and report it as unknown |

It is a skill, not a paragraph in `AGENTS.md`, because the procedure is long and needed rarely, and its
**description carries the trigger** ("Use it before touching the rendezvous, the roster, an admin/operator
list, a production checkout or a deploy"). See [SKILLS.md](SKILLS.md#skills-that-ship-with-the-node).

## 3. Lessons — knowledge, looked up on purpose (`lua/core/lessons.lua`)

A lesson is `{id, at, symptom, cause, fix, rule, tags, source}`. `symptom` and `rule` are required;
`cause`/`fix` may be `unknown`, because a half-understood incident still teaches its rule. The store lives
in the node's own state (key `lessons`), bounded to 200 entries with a visible `dropped` count.

* **On demand only — the hard rule.** Nothing from the store enters a session's instructions, its notes
  or its context. There is no `prompt_block`, no `inject`, no `system_section`: the model asks
  (`lessons {action:"recall", query}`), and the fleetops skill says when. A **fresh agent gets no
  cross-session knowledge at session start** (`scripts/test-fleetops.lua` runs a real two-turn session
  against the fake provider and asserts the prompt carries no lesson text, no notes and no
  `onSessionStart_injection`).
* **Adding is one call**: `lessons {action:"add", symptom, cause, fix, rule, tags}`. Repeating an identical
  symptom+rule replaces the same id instead of accumulating.
* **Seeds ship with the skill** (`skills/fleetops/incidents.json`): this week's four incidents. They are
  loaded once, by id, and never overwrite an entry someone has since corrected.
* **Search is lexical**, so the answer says so: an empty recall means "these words are not in the store",
  not "no such lesson exists".

## 4. `fleetview` — one read-only call for the whole fabric (`lua/core/fleetview.lua`, `rust/wa-fleetview`)

Per node: `online`, `last_seen_ms` (+ `last_seen_age_s`), `role`, `version`, `commit`, `health`, `disk`,
`components` and the `features` they carry, `operations`, `jobs`, and `incidents` (telemetry + lessons).
The local node answers first, then peers by name; lists are bounded and say what they trimmed.

**Unknown is named, never faked.** Every field a node could not answer is absent *and* listed in its
`missing`; `missing_total` counts them. An unread disk is not 0 %, an unread runtime is not "healthy", a
peer with no `last_seen` is not "seen 0 seconds ago". This is the habit "distrust a misleading result"
made structural, and it is what tells a reader "nothing is wrong" from "nothing was read".

The tool has no write path at all — the module it calls cannot act, and the catalogue marks it read-only
(`tool_call` batches may include it). `rust/wa-fleetview` is the same record contract as a leaf crate with
the assembly rules and a three-node fabric test, ready for the `host.fleetview` capability; today the Lua
collector answers, and the two are kept in step by `FIELDS`.

Known limit, stated rather than papered over: a **peer's** health, components and running work need a peer
read that does not exist yet. A peer observation carries the registry's facts (reachability, `last_seen`,
the last resource sample) and names the rest in `missing` with the reason `peer_read_not_performed`.

## 5. The shipped default guard (`lua/core/hooks_defaults.lua`)

A `PreToolUse` refusal, on by default, of exactly two actions:

* editing `WASM_AGENT_NETWORK_ADMINS` (a shell edit of the variable, or a write/edit of the rendezvous
  drop-in `wa-rendezvous.service.d`/`managed.conf`);
* restarting/stopping/reloading `wa-rendezvous` (any service manager).

The refusal is the operator's sentence: **"this detaches nodes that pin the admin set; use mesh (`wa fleet
push-roster`)"**. Neighbouring commands are untouched, including *reading* the same files,
`systemctl status wa-rendezvous`, the journal, and the documented safe path. A guard that blocks diagnosis
gets removed, so the narrow rule is the point.

It is **overridable, visibly**: an operator hook named `guard-destructive` in `hooks.json` replaces it (the
engine's own precedence, not a second rule), and `WASM_AGENT_DEFAULT_GUARD=off` turns it off. `/hooks`
prints which state it is in. It runs before anything configured and before the `wa:hooks` component seam,
so both paths keep it. See [HOOK-EVENTS.md](HOOK-EVENTS.md#shipped-default-guard).

## 6. Router modules — routing policies as components

`wit/model/router.wit` (`wa:model-router`) plus `rust/wa-model-router`: a policy module decides *which*
models a class of work prefers and which skills the caller should load; the gateway keeps the call. The
`default` module reproduces today's `models.routes` routing exactly (asserted against
`wa_model_gateway::plan_chat`), a `fleet-ops` module routes a fleet-ops turn to the strong model and names
the `fleetops` skill, and modules are installed/upgraded/switched like any service component — a swap
changes the next call without a restart, and a call in flight keeps the module it started with. Details:
[MODEL-GATEWAY.md](MODEL-GATEWAY.md#router-modules).

## Tests

| what | how | result (10/11, this checkout) |
| --- | --- | --- |
| habits once, in the prefix, no pressure vocabulary; fresh session injects nothing; skill + lessons + fleetview | `scripts/test-fleetops.lua` | 147 checks, 0 failed |
| guard refuses both actions, allows the neighbours, is visible and overridable | `scripts/test-fleetops-guard.lua` | 61 checks, 0 failed |
| fleet view: every field on a 3-node fabric, unknown named | `cargo test -p wa-fleetview` | 6 tests, 0 failed |
| default router == current routing; a swap changes routing without restart; labels not waived | `cargo test -p wa-model-router` | 8 tests, 0 failed |

Both Lua suites are self-contained and run in the fast path; no node, network or paid call is involved.
