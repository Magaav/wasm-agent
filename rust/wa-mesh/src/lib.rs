//! Direct node-to-node calls by hierarchy. Design: `docs/MESH.md`.
//!
//! The rendezvous is discovery only: it says where a peer is, and after that a call goes node to
//! node. The rule of the fleet is one sentence — a node may call and control nodes at its own level
//! or below; anything else needs an operator's per-peer grant in `policy.json`. Both ends of a call
//! run the same [`hierarchy::authorize`] against the same signed roster, and the target's verdict is
//! the one that executes anything.
//!
//! Reading order, which is also the order a call takes:
//!
//! * [`roster`] — the signed fleet document: who is in the fleet, at what level, reachable where;
//! * [`fleetkey`] — the operator's side of it: `wa fleet keygen`, `sign`, `show` (nothing in a node's
//!   call path ever signs a roster);
//! * [`attest`] — the one sentence a node signs after it admitted a call, which is how a *managed*
//!   node's admission widens to the mesh's verb (`docs/MESH.md` §9);
//! * [`policy`] — the `"mesh"` section of `policy.json`: the fleet key and the grants;
//! * [`hierarchy`] — `authorize(caller, target, verb)`, the whole access rule in one function;
//! * [`cache`] — the peer cache that keeps calls working when the rendezvous is down;
//! * [`wire`] — the two envelopes and the exact bytes that are signed;
//! * [`client`] — the attempt order, and the difference between "denied" and "unreachable";
//! * [`relay`] — the relay as transport only: the same signed call, carried where it cannot be dialled;
//! * [`server`] — authentication, authorization, replay protection and the signed reply;
//! * [`admission`] — the one decision, shared by the direct listener, the relay hop and the node's own
//!   admission in Lua, so the roster decides on every path;
//! * [`fleet`] — `wa fleet push-roster`: install the roster on a node that already accepts the caller;
//! * [`audit`] — one line per attempt, with no message text in it;
//! * [`host_call`] — the node wiring behind `WA_MESH=1` (`host.mesh_call`, the mount, the handler).
//!
//! Three properties this crate is built to keep:
//!
//! 1. **A denial is not a transport failure.** Only `Outcome::Unreachable` carries `fallback: relay`;
//!    a refusal from the hierarchy or a grant is an answer and the caller must not launder it through
//!    the relay.
//! 2. **Nothing is believed because a peer said it.** A reply counts only when it is signed by the
//!    key the roster has for that node id; a refusal before authentication is a diagnosis, never a
//!    result. The relay is transport: it changes where the bytes went, never who decides.
//! 3. **No roster, no change.** A node that has no *verified* roster decides exactly as it did before
//!    the mesh existed (the operator pins of its binding), so installing the fleet is an act an
//!    operator performs, not something a peer can do to a node by calling it.
// The C ABI is a library API now: `host.mesh_call` answers a Lua call through a raw `*mut LuaState`
// the interpreter owns for the duration of the call. Marking it `unsafe fn` would only move the
// `unsafe` to the registration site without making anything safer, which is the same call
// `wa-rendezvous` makes for its own host functions.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod admission;
pub mod attest;
pub mod audit;
pub mod cache;
pub mod client;
pub mod fleet;
pub mod fleetkey;
pub mod hierarchy;
pub mod host_call;
pub mod http;
pub mod identity;
pub mod policy;
pub mod relay;
pub mod roster;
pub mod server;
pub mod wire;

#[cfg(test)]
pub mod testkit;
#[cfg(test)]
mod tests_e2e;
#[cfg(test)]
mod tests_relay;

pub use admission::{Admission, Admitter, Inbound, Transport};
pub use attest::ATTEST_DOMAIN;
pub use audit::{Event, FileSink, MemorySink, Sink, StderrSink, Tee};
pub use cache::PeerCache;
pub use client::{Attempt, Client, ClientConfig, Inner, Outcome};
pub use hierarchy::{authorize, Verb, Verdict};
pub use identity::Identity;
pub use policy::{Effect, Grant, MeshPolicy};
pub use relay::{RelayAnswer, RelayClient, RelayOutcome};
pub use roster::{Roster, RosterNode};
pub use server::{Call, Handler, Reply, Server, ServerConfig};
