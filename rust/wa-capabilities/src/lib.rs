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
pub mod audio;
pub mod capabilities;
pub mod client_bridge;
pub mod core_component;
pub mod file_search;
pub mod graph;
pub mod host;
pub mod http_transport;
pub mod operations;
pub mod plugins;
pub mod quickjs;
pub mod resources;
pub mod ripgrep;
pub mod serve;
pub mod subagents;
