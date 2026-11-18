# Mission change/fleet-wire — SSH access updates itself when a node comes online

Base: origin/main after vault-one lands (rust/wa-vault fleet: enroll/announce/apply/alert exist and are
tested; the call site on mesh attach and `last_seen` were named as gaps in its REPORT.md).
Victor 18/11: "i like automatic". Build/test on this node only. Never push.

## Required behaviour

1. **On mesh attach, automatically.** When a node attaches (or re-attaches after being offline), it
   publishes its SSH endpoint (user, host, port, jump, host-key fingerprint) signed with its mesh
   identity. Every vault holding `ssh/<node>` applies it with the existing decision function: same host
   key + new address → update + audit `ssh_endpoint_changed`; host-key change → refuse + alert; bad
   signature / unknown node → refuse + audit. No operator command in the normal path; `wa vault fleet
   apply` stays as the manual door.
2. **`last_seen`** written on every accepted announce (and on a verified heartbeat, rate-limited).
3. **The endpoint is measured, not configured.** The node reports the address it is actually reachable
   at for SSH (its sshd listen + public/LAN address as the mesh sees it), never the rendezvous URL (see
   harness-fixes item 8).
4. **Neighbour copies.** A node's recovery entry is held by its ring neighbours plus the two admin nodes
   (openclaw, avell). Replication of the private half between vaults: sealed for the receiving vault,
   never in plaintext on the wire or in a call record; a vault that lacks a node's entry it should hold
   says so in `wa vault status`.
5. **Alert reaches the operator.** A refused host-key change shows in `/status` and the operator channel,
   once per (node, fingerprint), not every tick.

## Done when

Proofs with throwaway nodes/sshd (no real node): an IP change on re-attach updates the entry with no
command typed; a host-key change is refused and alerted once; a forged announce changes nothing;
last_seen moves; replication between two scratch vaults never exposes the private key (grep of every
call record/log); `wa vault ssh <node>` works from a neighbour vault after the owner's vault is deleted.
Real-node enrollment is NOT part of this mission (per node, with Victor's go).
