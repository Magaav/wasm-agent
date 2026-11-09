---
name: fleetops
description: >-
  How this fleet is wired (nodes, rendezvous, relay, roster pins, sentinel, services) and how to work
  on it without detaching it: diagnosing a node that went offline, reading the fabric with one
  read-only call, and the short list of things that must never be done to regain control. Use it
  before touching the rendezvous, the roster, an admin/operator list, a production checkout or a
  deploy, and whenever a node or a service looks offline or a change must reach other machines.
---

# Fleet operations

This machine is one **node** in a fleet. A node is one running `wa` process with its own identity,
its own state home and its own transcript - not the computer it runs on. Two nodes can share a box.

Read this before any change to fleet control. The incidents that produced it are in
`incidents.json` next to this file, and in the lessons store (`lessons` tool) that grew from them.

## What the pieces are

| piece | what it is | where it lives |
| --- | --- | --- |
| **node** | one `wa serve`: identity (ed25519 key), state home, admission | this machine and the peers |
| **rendezvous** (`wa-rendezvous`) | the directory: who exists, their public key, endpoints, `last_seen`. It carries identity and reachability, not work | `openclaw` (`/etc/systemd/system/wa-rendezvous.service`) |
| **relay** | the fallback transport for a peer that cannot be reached directly | the cloud |
| **roster + fleet key** | the mesh's own statement of which nodes exist and what they may do; a signed roster is what a node decides a call by (`docs/MESH.md`) | `<config>/mesh-roster.json`, `policy.json` `mesh` |
| **pins / operators** | each node *pins* the operator list it was bound with (`WASM_AGENT_NETWORK_ADMINS`) and the fleet key it trusts | that node's own config, not yours |
| **sentinel** (`wa-sentinel`) | the supervisor outside the node: it installs, restarts and deploys when the node is idle | runs beside the node |
| **services** | long-lived WASI components (WhatsApp, email, STT workers) with their own kv and grants | see the `services` tool |
| **jobs / operations** | durable queued work and supervised long runs | `jobs`, `operation` |

`docs/FABRIC.md` has the layers and their real names; `docs/MESH.md` has the roster and the verbs;
`docs/SENTINEL.md` has the deploy path; `docs/SERVICE-COMPONENTS.md` has component upgrade.

## One call: the whole fabric

`fleetview` answers every node at once - online and `last_seen`, version and commit, health, disk,
components and the features they carry, running operations and jobs, and recent incidents from
telemetry and lessons. It is read-only, and it names fields it could not read rather than filling
them with zeros: a `missing` list on a node is the answer, not a failure.

Start there. Then narrow with `nodes` (the registry view), `services {action:"list"}`, `operation`
(running work) and `jobs`.

## Diagnosing a node that is offline

Work from cheapest and least invasive to most, and stop as soon as the evidence explains it:

1. `fleetview` / `nodes` - is it `online:false` with an old `last_seen`, or absent from the registry
   entirely? Absent means it never registered (or was pruned), not that it is down now.
2. `operator_of_peer` on that node: `false` means **this** node will be refused (`unknown_caller`) no
   matter how healthy the peer is - a pinning problem, not an outage.
3. The rendezvous journal and its service log (`journalctl -u wa-rendezvous`): a restart, a crash
   loop, or a rejected registration names itself there. Read it; do not restart it to "see".
4. The node's own log on its own machine (`<install>/node.log`), and the sentinel's log beside it.
5. `lessons {action:"recall", query:"<node or symptom>"}` - an incident like this one has a rule.
6. Only then, the operator route: the relay and the fleet key (`wa fleet show <roster>`).

A node that pins an older admin set or an older fleet key keeps working with what it pins. That is
the design, and it is why "repairing" the control plane detaches nodes that were fine.

## NEVER (each with the safe path)

| never | why | do instead |
| --- | --- | --- |
| **Never edit `WASM_AGENT_NETWORK_ADMINS`** (or a `wa-rendezvous` drop-in such as `managed.conf`) to give a node control | nodes pin the admin set they were bound with. Since the 09/11 patch an **added** operator is reported and tolerated (the attach tick no longer detaches, and admission checks each caller's own vouch), but a **removed** operator is refused at admission and needs a re-bind - and this edit has detached this fleet three times (18.5 h on 06/11, ~1 h on 08/11, ~1 h on 09/11) | `wa fleet push-roster <node>` - the signed roster reaches the node over the transport it already trusts, and the node pins it itself. If the operator decides the set itself must change, the change is still theirs: append with a backup, then re-bind each guest so it pins the new list. Note that a network administrator **cannot be bound** (`binding_administrator_identity_forbidden`), so a master gets no relay address and must be reached directly |
| **Never restart `wa-rendezvous` to apply or "fix" something** | the directory is shared control plane; a restart drops registrations and re-runs admission for every node at once | change the node, not the directory. A rendezvous restart is a human decision with a stated window |
| **Never hand-edit a production checkout** (`orca/projects/wasm-agent`, a deployed tree) | it is someone's verified tree; an uncommitted edit there is invisible to review, to the gate and to the next deploy | land it through Git (`change/<name>` -> main), or make the change in a lane |
| **Never deploy from a dirty tree** | the deploy ships a commit; a dirty tree means the thing you tested is not the thing that ships | commit, verify `git status` is clean, then `wa-sentinel request deploy` with a session continuation |
| **Never stop or restart a node by image name, and never replace the window** | "wa" matches every node on the box, including ones you did not start; the client reloads itself | stop by the pid in `serve.pid`; queue an upgrade through the sentinel (`skills/self-update/SKILL.md`) |
| **Never manufacture settlement** for an operation whose effect is unknown | replaying an unknown effect is how one incident becomes two | reconcile (`operation` / `resources`), report it as unknown |

A guard hook refuses the first two of these commands by default (`docs/HOOK-EVENTS.md`,
"Shipped default guard"). It is a refusal with this table's pointer, not a limit on your work: the
safe path is always available.

## Lessons

`lessons` is a store of incident -> cause -> fix -> **rule**, looked up on purpose and never injected
(`docs/FLEET-OPS.md`). Recall before touching fleet control; add one with a single call when you
learn something that a later session would otherwise relearn:

```
lessons {action:"recall", query:"rendezvous admin list"}
lessons {action:"add", symptom:"...", cause:"...", fix:"...", rule:"...",
         tags:["rendezvous","pinning"]}
```

`cause` and `fix` may be `unknown`; `symptom` and `rule` are refused if empty, because a lesson
without a rule is an anecdote.

## Before you change anything on another machine

- Name the blast radius out loud in the report: which nodes pin what you are about to change.
- Use the reversible path first (a flag, a backup, a switch), and keep one change per step.
- Verify the effect by reading it back (`fleetview`, `nodes`, the peer's own status), never by the
  command's exit code.
- If it went wrong: roll back first, report the rollback, then the attempt.
