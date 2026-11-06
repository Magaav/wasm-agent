//! The wasm runtime half of the microkernel: what runs the modules, and nothing about the agent.
//!
//! - `components`: the engine, the pin check, grants, and one-shot component calls (MCP, agent-core).
//! - `services`: the supervisor - install, start, stop, health and logs of long-lived services.
//! - `service_components` / `service_components_v2`: the two runners, WASI 0.2 (polling) and WASI 0.3
//!   (`wa:kernel@0.2`, native async with `future`/`stream`), served side by side.
//! - `service_io`: the host side of the socket, http and kv a service imports.
//! - `service_components::service_stt` (declared there with `#[path]`, as it was before the split): the
//!   speech bridge both runners share. It is deliberately NOT a module of this crate root - declaring
//!   the same file twice compiles it twice, which would double its tests.
//! - `queue_host` / `bus_host` / `state_host`: `wa:queue`, `wa:bus` and `wa:state` served to components
//!   (docs/QUEUE.md, docs/BUS.md, docs/STATE.md), with the kv namespace wa-kv provides behind them.
//!
//! Moved out of `wa-host` without rewriting logic. This is the crate whose rebuild the split is meant
//! to contain: it is the only one that monomorphizes wasmtime.
// The C ABI is a library API now: a kernel entry point answers a Lua call through a raw `*mut LuaState` the
// interpreter owns for the duration of the call (`pub extern "C-unwind" fn ...(l: *mut LuaState)`). Marking
// those `unsafe fn` would only move the `unsafe` to every registration site without making them safer,
// so the lint is allowed once here, with the reason.
#![allow(clippy::not_unsafe_ptr_arg_deref)]
pub mod bus_host;
pub mod components;
pub mod queue_host;
pub mod service_components;
pub mod service_components_v2;
pub mod service_io;
pub mod services;
pub mod state_host;
