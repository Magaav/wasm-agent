//! The pieces every other host crate needs and none of them may define.
//!
//! - `lua`: the vendored Lua 5.4 C ABI and the `Lua` interpreter wrapper. Every capability function
//!   answers on a Lua state, so this is the floor of the graph.
//! - `paths`: the user's home, the node's private directory and the component directory.
//! - `json`: pushing a `serde_json::Value` as a Lua value, the one answer shape shared by the
//!   capability functions in several crates.
//! - `system_resources`: the dependency-free host resource sample.
//!
//! Everything here is a move out of `wa-host` (see `REPORT.md` at the repository root): no logic was
//! rewritten, only relocated, so a change in one crate no longer recompiles the others.
// The C ABI is a library API now, and clippy is right that these take a raw Lua state: they are the
// functions a capability registers with `lua_register`/`register_with_upvalue`, and the state they
// dereference is the live interpreter the caller owns for the duration of the call. Marking them
// `unsafe fn` would only move the `unsafe` to every registration site without making any of them
// safer, so the lint is allowed here, once, with the reason.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

pub mod json;
pub mod lua;
pub mod paths;
pub mod system_resources;
