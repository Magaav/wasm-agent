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
pub mod email_outbox_component;
pub mod outbox_component;
pub mod tz_component;
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
/// The disk subsystem (docs/ONEROOT.md) is a crate of its own now, shared with the operations
/// supervisor so both enforce one cap. Re-exported here so every caller keeps the same path.
pub use wa_disk as disk;
/// The operations runner as this node speaks to it: a wire client to `wa-operations-supervisor`
/// (`ready-operations-slice-2.md`, stage B). Same functions, same JSON, the runner itself is not here.
pub mod operations;
/// `wa:process@0.1.0` served by this node: a component spawns and waits on a child through the SAME
/// manager the `bash` tool uses. See wit/process/process.wit.
pub mod file_search;
/// `host.features` (docs/FEATURES.md): the one door the Lua gates ask "is this feature on, and which
/// path is live" through. The rule lives in `wa-features`; this crate only routes to it.
pub mod features;
pub mod graph;
pub mod host;
/// The console's transcript handle: the same calls in process (default) or across the wire to the
/// terminal program, over `wa-term-proto`: the wire is the only path.
pub mod screen;
pub mod http_transport;
pub mod limits;
// The runner itself, from its own crate (`ready-operations-slice-2.md`): the host no longer carries it.
pub mod plugins;
pub mod quickjs;
/// The build-time scan behind the capability registry (`src/capability_rows/`): which files declare
/// rows. `build.rs` writes the aggregate from it, and `tests/capability_row_discovery.rs` runs the same
/// function on a directory it makes itself, so a new row file is collected without editing anything.
pub mod registry_scan;
pub mod resources;
pub mod ripgrep;
pub mod serve;
/// The door's static tier (slice 1 of `ready-serve-own-program.md`): the UI file bytes served by their own
/// program named by `<home>/.wasm-agent/serve-static.json` (a file, never an environment variable), and
/// the guard that travels with them.
pub mod serve_static;
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
/// The node's own tty: the funnel every screen byte goes through, the launch animation's hold and raw
/// mode (moved out of `wa-term` in its last slice: it is I/O, not display).
/// The tool-progress rows are the runner's now (it waits on the child); the node reads the same store
/// through `wa_tool_progress`, which both processes link.
pub mod links;
pub mod screen_guard;
pub mod selection;
pub mod tty;
pub mod subagents;
// The explicit WhatsApp send (docs/HOST.md, "WhatsApp explicit sends"): validate the exact JID, ask
// the `whatsapp.send` policy, enqueue on `wa:queue`; the `wa-whatsapp` component sends it.
pub mod whatsapp_archive;
pub mod whatsapp_query;
pub mod whatsapp_send;
// The operator's approval of outgoing WhatsApp drafts (13/11, docs/APPROVE.md): the policy, the queue
// of drafts and the decision. `whatsapp_send` asks it before it queues anything, which is what makes
// one gate cover a send from any node.
pub mod whatsapp_approve;
/// The email connector's tools: the send on `email.outbox` and the index on `email.query`
/// (`docs/EMAIL-CONNECTOR.md`).
pub mod email_query;
pub mod email_send;
