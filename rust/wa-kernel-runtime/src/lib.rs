//! The wasm runtime half of the microkernel: what runs the modules, and nothing about the agent.
//!
//! - `components`: the engine, the pin check, grants, and one-shot component calls (MCP, agent-core).
//! - `services`: the supervisor - install, start, stop, health and logs of long-lived services.
//! - `service_components` / `service_components_v2`: the two runners, WASI 0.2 (polling) and WASI 0.3
//!   (`wa:kernel@0.2`, native async with `future`/`stream`), served side by side.
//! - `registrations`: the ledger of everything a component registers, revocable per instance
//!   (`docs/KERNEL.md`, "Revocable registrations").
//! - `imports` / `supervisor`: what an artifact imports and whether it is served, and the
//!   start-by-imports reconcile (`docs/KERNEL.md`, lesson 3).
//! - `install`: the transactional install/upgrade - stage, verify, start beside, health, switch, stop.
//! - `profiles` / `limits`: the layered effective configuration (lesson 4) and the per-component CPU
//!   and memory limits the runners enforce.
//! - `dev`: the dev-loop hot swap (`wa dev`): a new instance beside the old one, health first, then
//!   the old one stops. Not a registry - it lives in the caller's slot, beside the supervisor.
//! - `service_io`: the host side of the socket, http and kv a service imports.
//! - `guest_kv`: the `__wa/` guard both `wa:kernel/kv` runners put in front of a component's own
//!   store, so a component can neither see nor write the host's meta keys (`docs/STATE.md`).
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
pub mod dev;
// The kernel half of a drained hot swap (`wa:kernel/drain`): wait for the work in flight instead of
// stopping the instance and retrying its job (docs/SERVICE-COMPONENTS.md).
pub mod drain;
pub mod guest_kv;
pub mod imports;
pub mod install;
pub mod limits;
// The memory seam served to the core: the `memory` component over a scoped `wa:kernel/sql` grant.
pub mod memory_host;
pub mod profiles;
pub mod registrations;
pub mod queue_host;
pub mod service_components;
// The self-loop seam served to the core: the `selfloop` component over its own scoped
// `wa:kernel/sql` grant (docs/CORE-SPLIT.md).
pub mod selfloop_host;
pub mod service_components_v2;
pub mod service_io;
pub mod services;
// The node half of queue phase 2 for speech: the `stt.requests` queue, the relay handler a remote
// worker calls, and the `stt_worker` role (docs/QUEUE.md, docs/WHATSAPP-TRANSCRIPTION.md).
pub mod stt_node;
pub mod state_host;
// `wa:kernel/sql`: the scoped database grant the memory component stands on (docs/KERNEL.md).
pub mod sql_host;
pub mod supervisor;
// Which WASI interfaces a `wa:kernel@0.2` component gets and with what scope (docs/WASI-INTERFACES.md).
pub mod wasi_ext_host;
pub mod vault_host;
pub mod wasi_grants;
#[cfg(test)]
pub(crate) mod test_wasm;
