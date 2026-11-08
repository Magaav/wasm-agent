//! The mesh's decisions, with nothing to hold: pure logic for the node and for the `wa:mesh` guest.
//!
//! `docs/MESH.md` is the design and `docs/CORE-SPLIT.md` is why this crate exists. The rule of the
//! fleet is one sentence — a node may call and control nodes at its own level or below, and anything
//! else needs an operator's per-peer grant — and everything that answers it, checks it or writes it
//! down is here:
//!
//! * [`roster`] — the signed fleet document: who is in the fleet, at what level, reachable where. The
//!   canonical bytes, the shape checks and the verify order are here because both ends of a call and
//!   both builds must agree on them to the character;
//! * [`policy`] — the `"mesh"` section of `policy.json`: the fleet key and the grants, with the grant
//!   policy's own `Pattern` and deny-before-allow order;
//! * [`hierarchy`] — `authorize(caller, target, verb)`, the whole access rule in one function;
//! * [`attest`] — the one sentence a node signs after it admitted a call, its exact bytes and the check
//!   of one (`docs/MESH.md` §9);
//! * [`audit`] — one line per attempt, with no message text in it;
//! * [`cache`] — the peer cache's *rule* (roster wins on who; cheapest address first), not its file;
//! * [`crypto`] — hex, sha256 and the ed25519 verifier a build supplies ([`crypto::Crypto`]).
//!
//! What is deliberately absent, because it is the node's and not a decision: the sockets, the relay, the
//! HTTP dialect, the listener, the mount, the peer cache file, the policy file, the clock, the process
//! switch and the node's key. A build that has none of those (the `wa:mesh` guest) can still verify a
//! roster, decide a call, render an audit line and check an attestation.
//!
//! Three properties this crate is built to keep, unchanged from `wa-mesh`:
//!
//! 1. **A denial is not a transport failure.** Only `Outcome::Unreachable` carries `fallback: relay`;
//!    a refusal from the hierarchy or a grant is an answer the caller must not launder through a relay.
//! 2. **Nothing is believed because a peer said it.** A roster counts only when the operator's key
//!    signed it; a reply counts only when it is signed by the key the roster has for that node id.
//! 3. **No roster, no change.** A node with no *verified* roster decides exactly as it did before the
//!    mesh existed, so installing a fleet is an operator's act and not something a peer can do by
//!    calling.
pub mod attest;
pub mod audit;
pub mod cache;
pub mod crypto;
pub mod hierarchy;
pub mod policy;
pub mod roster;

#[cfg(test)]
mod testkit;

pub use attest::{ATTEST_DOMAIN, ATTEST_MAX_AGE_SECONDS};
pub use audit::Event;
pub use cache::PeerCache;
pub use crypto::{Crypto, Signer};
pub use hierarchy::{authorize, Verb, Verdict};
pub use policy::{Effect, Grant, MeshPolicy};
// The operator's grant patterns are the capability policy's own (`*`, one trailing `*`, never a
// regular expression), so they are re-exported rather than described twice: a second dialect of
// "which peer" would be a second rule.
pub use wa_grant_policy::Pattern;
pub use roster::{Roster, RosterNode};
