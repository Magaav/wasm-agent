//! Everything the agent can do, and the request/session layer it is served from.
//!
//! - `capabilities`: the registry the Lua core and the component bridge resolve `host.*` against.
//! - `host`: the capability functions themselves (sqlite, http, files, exec, process, console, ...).
//! - `serve`: the node's request loop, its journal and scheduler, and the client bridge's peer.
//! - `subagents`: the child supervisor and its journal.
//! - `operations`, `resources`: the durable operation records and the resource claims behind them.
//! - `graph`: the shim onto the `graph` component's index.
//! - `quickjs`, `plugins`: the checksum-pinned QuickJS sandbox and the plugin registry over it.
//! - `client_bridge`, `http_transport`, `audio`, `core_component`, `file_search`, `ripgrep`: the
//!   transports and device/I/O edges, and the Lua-in-a-component bridge.
//!
//! Moved out of `wa-host` without rewriting logic. `core_component` lands here rather than in
//! `wa-kernel-runtime` because it dispatches into the capability registry and registers the capability
//! functions on the interpreter it boots; inverting that to keep it in the kernel would have been a
//! logic change, not a move.
// The C ABI is a library API now: a capability function answers a Lua call through a raw `*mut LuaState` the
// interpreter owns for the duration of the call (`pub extern "C-unwind" fn ...(l: *mut LuaState)`). Marking
// those `unsafe fn` would only move the `unsafe` to every registration site without making them safer,
// so the lint is allowed once here, with the reason.
#![allow(clippy::not_unsafe_ptr_arg_deref)]
pub mod audio;
pub mod capabilities;
pub mod client_bridge;
// The code-mode seam (`docs/CORE-SPLIT.md`'s second extraction): the `codemode` component over the
// QuickJS sandbox the kernel hosts. Lives here, not in `wa-kernel-runtime`, for the same reason
// `core_component` does — it needs the capability crate's own `quickjs` half on one side of the seam.
pub mod codemode_seam;
pub mod core_bridge;
pub mod core_component;
pub mod core_pool;
/// One root, one `wa clean`, one disk cap (`docs/ONEROOT.md`): the layout inside the node's existing
/// state root, the retention rules, the pins, and the refusal that stops a full disk instead of
/// letting a build die on `os error 112`.
pub mod disk;
pub mod file_search;
/// `host.features` (docs/FEATURES.md): the one door the Lua gates ask "is this feature on, and which
/// path is live" through. The rule lives in `wa-features`; this crate only routes to it.
pub mod features;
pub mod graph;
pub mod host;
pub mod http_transport;
pub mod operations;
pub mod plugins;
pub mod quickjs;
pub mod resources;
pub mod ripgrep;
pub mod serve;
/// `wa vault ...` (`docs/VAULT.md`): the command table entry that belongs to this crate, kept ready for
/// the one line `rust/wa-host/src/main.rs` has to add.
pub mod vault_cli;
// The speech queue's node half, reached from Lua (`stt_node` in `wa-kernel-runtime`): one admitted
// peer call, the operator view, and the pump the worker role borrows for its transport.
pub mod stt;
// The compute fabric's node half, reached from Lua (`fabric_node` in `wa-kernel-runtime`): presence,
// the offer pump and the lease (`docs/FABRIC.md`).
pub mod fabric;
/// The live facts behind a long tool call's row (docs/TOOL-PROGRESS.md): fed by the operation wait
/// loops, read by every renderer.
pub mod tool_progress;
pub mod subagents;
// The explicit WhatsApp send (docs/HOST.md, "WhatsApp explicit sends"): validate the exact JID, ask
// the `whatsapp.send` policy, enqueue on `wa:queue`; the `wa-whatsapp` component sends it.
pub mod whatsapp_query;
pub mod whatsapp_send;
/// The email connector's tools: the send on `email.outbox` and the index on `email.query`
/// (`docs/EMAIL-CONNECTOR.md`).
pub mod email_query;
pub mod email_send;
