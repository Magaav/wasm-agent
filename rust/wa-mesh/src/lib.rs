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
//! * [`policy`] — the `"mesh"` section of `policy.json`: the fleet key and the grants;
//! * [`hierarchy`] — `authorize(caller, target, verb)`, the whole access rule in one function;
//! * [`cache`] — the peer cache that keeps calls working when the rendezvous is down;
//! * [`wire`] — the two envelopes and the exact bytes that are signed;
//! * [`client`] — the attempt order, and the difference between "denied" and "unreachable";
//! * [`server`] — authentication, authorization, replay protection and the signed reply;
//! * [`audit`] — one line per attempt, with no message text in it;
//! * [`host_call`] — the node wiring behind `WA_MESH=1` (`host.mesh_call`, the mount, the handler).
//!
//! Two properties this crate is built to keep:
//!
//! 1. **A denial is not a transport failure.** Only `Outcome::Unreachable` carries `fallback: relay`;
//!    a refusal from the hierarchy or a grant is an answer and the caller must not launder it through
//!    the relay.
//! 2. **Nothing is believed because a peer said it.** A reply counts only when it is signed by the
//!    key the roster has for that node id; a refusal before authentication is a diagnosis, never a
//!    result.
// The C ABI is a library API now: `host.mesh_call` answers a Lua call through a raw `*mut LuaState`
// the interpreter owns for the duration of the call. Marking it `unsafe fn` would only move the
// `unsafe` to the registration site without making anything safer, which is the same call
// `wa-rendezvous` makes for its own host functions.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod audit;
pub mod cache;
pub mod client;
pub mod hierarchy;
pub mod host_call;
pub mod http;
pub mod identity;
pub mod policy;
pub mod roster;
pub mod server;
pub mod wire;

#[cfg(test)]
pub mod testkit;
#[cfg(test)]
mod tests_e2e;

pub use audit::{Event, FileSink, MemorySink, Sink, StderrSink, Tee};
pub use cache::PeerCache;
pub use client::{Attempt, Client, ClientConfig, Inner, Outcome};
pub use hierarchy::{authorize, Verb, Verdict};
pub use identity::Identity;
pub use policy::{Effect, Grant, MeshPolicy};
pub use roster::{Roster, RosterNode};
pub use server::{Call, Handler, Reply, Server, ServerConfig};
