//! Node identity and the transport a node registers with.
//!
//! - `node`: the node's key, its id, `sign`/`verify` and the enrollment file.
//! - `binding_runtime`: whether this process is serving, and through what.
//! - `rendezvous`: the server nodes register with (with its `bindings` submodule).
//! - `relay_client`: the client half of the relay, and the jobs it hands to the serve loop.
//!
//! Moved out of `wa-host` without rewriting logic. The host answers `node_identity`/`sign`/`verify`
//! through it and the serve loop drains `relay_client`; neither edge points back down, so it is its own
//! crate (docs/KERNEL.md asks for exactly this seam).
// The C ABI is a library API now: a identity capability answers a Lua call through a raw `*mut LuaState` the
// interpreter owns for the duration of the call (`pub extern "C-unwind" fn ...(l: *mut LuaState)`). Marking
// those `unsafe fn` would only move the `unsafe` to every registration site without making them safer,
// so the lint is allowed once here, with the reason.
#![allow(clippy::not_unsafe_ptr_arg_deref)]
pub mod binding_runtime;
pub mod node;
pub mod relay_client;
pub mod rendezvous;
