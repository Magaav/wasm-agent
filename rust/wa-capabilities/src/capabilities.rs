//! The node's capability inventory: the *one* list of `host.*` functions.
//!
//! Before this module the only way to learn what a node can do was to grep `rust/` for
//! `lua.register` calls and read `docs/HOST.md` beside them, in two languages, and hope the two
//! agreed. They did not have a way to disagree loudly: a registered capability nobody documented
//! and a documented capability nobody registered were both silent.
//!
//! So registration and inventory are the same act here. [REGISTRY] is the list the interpreter is
//! booted from ([`register`] walks it), which makes it the live registry rather than a second
//! hand-written copy. Everything that answers "what can this node do" reads it:
//!
//! - `wa capabilities --json` (CLI, through `host.capability_inventory`),
//! - the `capabilities` field of `/health` (names + a digest, never the descriptions),
//! - `capabilities()` and `describe(name)` inside the codemode sandbox,
//! - and the drift test in this module's `tests`, which fails when `docs/HOST.md` and this list
//!   disagree in either direction.
//!
//! Adding a capability is one edit: a new entry here. Nothing else has to be kept in sync by hand
//! except the documented row the drift test insists on.
use wa_host_support::lua::HostFn;
use ring::digest::{digest as ring_digest, SHA256};
use serde_json::{json, Value};
use std::ffi::{c_int, c_void};

/// What a capability can do to the world outside the process, in the five classes the inventory
/// promises. It is the *direct* effect of the host function: `quickjs` runs a sandboxed VM whose
/// nested tool calls are checked by their own capabilities, and an effect a caller cannot cause
/// through this function does not belong to it.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Effect {
    ReadOnly,
    WritesFiles,
    RunsProcess,
    Network,
    Device,
}

impl Effect {
    /// The wire spelling. Stable: it is compared verbatim by the drift test and read by callers.
    pub fn as_str(self) -> &'static str {
        match self {
            Effect::ReadOnly => "read-only",
            Effect::WritesFiles => "writes files",
            Effect::RunsProcess => "runs a process",
            Effect::Network => "network",
            Effect::Device => "device",
        }
    }

    /// Reads a documented effect class back. Test-only: the wire spelling is written by
    /// [`Effect::as_str`], and only the drift test needs the inverse, so the shipped binary does
    /// not carry a parser nothing calls.
    #[cfg(test)]
    pub fn parse(text: &str) -> Option<Effect> {
        match text {
            "read-only" => Some(Effect::ReadOnly),
            "writes files" => Some(Effect::WritesFiles),
            "runs a process" => Some(Effect::RunsProcess),
            "network" => Some(Effect::Network),
            "device" => Some(Effect::Device),
            _ => None,
        }
    }
}

/// How a capability is bound into the `host` table. A capability that needs the `Host` pointer (or
/// the shared plugin/bridge state) says so here, so the table below stays the only place a
/// registration can happen.
#[derive(Clone, Copy)]
pub enum Bind {
    Plain(HostFn),
    /// Bound with `lua.register_with_upvalue` and the interpreter's `host_ptr`.
    Upvalue(HostFn),
}

pub struct Capability {
    pub name: &'static str,
    /// One line, no trailing period: the same text the CLI, the sandbox and `/health` callers read.
    pub description: &'static str,
    pub effect: Effect,
    pub bind: Bind,
}

macro_rules! plain {
    ($name:literal, $effect:ident, $f:path, $description:literal) => {
        Capability {
            name: $name,
            description: $description,
            effect: Effect::$effect,
            bind: Bind::Plain($f),
        }
    };
}

macro_rules! upvalue {
    ($name:literal, $effect:ident, $f:path, $description:literal) => {
        Capability {
            name: $name,
            description: $description,
            effect: Effect::$effect,
            bind: Bind::Upvalue($f),
        }
    };
}

/// The live registry. `main.rs` boots the interpreter from this list, so an entry that is not here
/// is not a capability the Lua side can call, and a capability the Lua side can call is here.
pub const REGISTRY: &[Capability] = &[
    // ---- storage and the ledger -------------------------------------------------------------
    upvalue!("sql_exec", WritesFiles, crate::host::sql_exec, "Run one statement against this interpreter's own SQLite connection; returns the changes/row count"),
    upvalue!("sql_query", ReadOnly, crate::host::sql_query, "Run one read query against this interpreter's own SQLite connection; returns rows"),
    plain!("db_ready", ReadOnly, crate::host::db_ready, "Whether the ledger schema migration has run in this process"),
    plain!("mark_db_ready", WritesFiles, crate::host::mark_db_ready, "Record that the ledger schema migration has run"),
    // ---- paths, environment and the process --------------------------------------------------
    plain!("getenv", ReadOnly, crate::host::getenv, "Read one environment value as the host resolved it (config file first, then the process)"),
    plain!("paths", ReadOnly, crate::host::paths, "The resolved home/config/data/cache/temp directories; never build a path by hand"),
    plain!("canonical_path", ReadOnly, crate::host::canonical_path, "Canonicalise a path without requiring it to exist"),
    plain!("platform", ReadOnly, crate::host::platform, "This node's platform, architecture and executable family"),
    plain!("now", ReadOnly, crate::host::now, "Wall-clock time"),
    plain!("monotonic_ms", ReadOnly, crate::host::monotonic_ms, "A monotonic millisecond counter for measuring elapsed time"),
    plain!("sleep", ReadOnly, crate::host::sleep, "Block this interpreter for a bounded number of milliseconds"),
    plain!("uuid", ReadOnly, crate::host::uuid, "A fresh random UUID"),
    plain!("sha256", ReadOnly, crate::host::sha256, "SHA-256 of a string, as hex"),
    plain!("runtime_info", ReadOnly, crate::host::runtime_info, "Build and runtime identity of this binary"),
    plain!("system_resources", ReadOnly, crate::host::system_resources, "CPU, memory and disk facts for this machine"),
    plain!("node_identity", ReadOnly, crate::host::node_identity, "This node's identity and network role"),
    plain!("mesh_call", Network, wa_mesh::host_call::mesh_call, "Call a peer directly by hierarchy, when WA_MESH=1; the roster, grants and direct transport of docs/MESH.md"),
    plain!("run_cancelled", ReadOnly, crate::host::run_cancelled, "Whether the current run has been cancelled, for cooperative loops"),
    plain!("log", Device, crate::host::log, "Print one redacted line to this process's standard error"),
    // ---- files -------------------------------------------------------------------------------
    plain!("read_file", ReadOnly, crate::host::read_file, "Read a UTF-8 text file; nil when missing or not text"),
    plain!("read_image_base64", ReadOnly, crate::host::read_image_base64, "Read a bounded PNG/JPEG/WebP/GIF as base64 with its MIME type"),
    plain!("write_file", WritesFiles, crate::host::write_file, "Create or overwrite a text file"),
    plain!("path_kind", ReadOnly, crate::host::path_kind, "Classify a path as file/dir/missing/other without reading it"),
    plain!("list_dir", ReadOnly, crate::host::list_dir, "List one directory's entries"),
    plain!("grep", ReadOnly, crate::host::grep, "Literal substring search over a directory or file with bounded, counted results"),
    // ---- the code graph ----------------------------------------------------------------------
    plain!("graph_index", WritesFiles, crate::graph::graph_index, "Build or refresh the content-hashed code graph, reparsing only changed files"),
    plain!("graph_query", ReadOnly, crate::graph::graph_query, "Run one structured query against the code graph"),
    plain!("graph_search", ReadOnly, crate::graph::graph_search, "Find symbols by concept or identifier in the code graph"),
    plain!("graph_source", ReadOnly, crate::graph::graph_source, "Exact source of one graph symbol, with continuation"),
    plain!("graph_sources", ReadOnly, crate::graph::graph_sources, "Exact source of several graph symbols in one call"),
    plain!("graph_notify", ReadOnly, crate::graph::graph_notify, "Report an explicit indexing failure so later queries refuse instead of returning stale results"),
    plain!("graph_explain", ReadOnly, crate::graph::graph_explain, "Explain what the graph knows about one symbol"),
    plain!("graph_path", ReadOnly, crate::graph::graph_path, "Shortest path between two graph symbols"),
    plain!("graph_caps", ReadOnly, crate::graph::graph_caps, "Which code calls which capability"),
    plain!("graph_stats", ReadOnly, crate::graph::graph_stats, "Index size and freshness counters"),
    plain!("graph_overview", ReadOnly, crate::graph::graph_overview, "A bounded structural overview of the indexed tree"),
    plain!("graph_impact", ReadOnly, crate::graph::graph_impact, "Resolved callers/dependencies of a symbol at a given depth"),
    plain!("graph_status", ReadOnly, crate::graph::graph_status, "Whether the graph index is present, current and complete"),
    plain!("graph_patch_audit", ReadOnly, crate::graph::graph_patch_audit, "Which symbols a changeset reaches, from the patch itself"),
    // ---- processes, operations and automation ------------------------------------------------
    plain!("exec", RunsProcess, crate::host::exec, "Run one foreground command as a supervised operation and return a bounded view of its output"),
    plain!("exec_timeout", ReadOnly, crate::host::exec_timeout, "The effective foreground deadline an exec would be given"),
    plain!("operation", RunsProcess, crate::host::operation, "Launch, observe, read, wait for or cancel a supervised external operation"),
    plain!("jobs", WritesFiles, crate::host::jobs, "Manage local automation definitions and their enabled state; jobs never execute here"),
    plain!("enqueue_completion", WritesFiles, crate::host::enqueue_completion, "Internal scheduler enqueue for a finished background completion"),
    plain!("subagent", RunsProcess, crate::host::subagent, "Start, inspect, wait for, message or cancel an owned child agent on its own thread"),
    plain!("resource", WritesFiles, crate::host::resource, "Supervised host resources: leases, receipts and their settlement"),
    // ---- the codemode sandbox ----------------------------------------------------------------
    plain!("quickjs", RunsProcess, crate::quickjs::capability, "The checksum-pinned QuickJS sandbox in wasmtime: fuel-metered, deadline-bounded, owner-checked, 4 sessions; effects only through nested tool calls"),
    // The code-mode seam (docs/CORE-SPLIT.md, "code mode"): the `codemode` component owns the guest's
    // protocol — the fence, its tool table, searchTools/describeTool, the admit/deliver order and the
    // script's report — and imports `wa:kernel/quickjs` for the sandbox it is not allowed to contain.
    // `WA_CODEMODE_COMPONENT=1` is what routes `lua/core/codemode.lua` here; without it the native path
    // runs, so this capability is inert on a node that never opts in.
    plain!("codemode", RunsProcess, crate::codemode_seam::capability, "One wa:codemode step against the installed codemode component: open a script, advance it past one tool call, or finish it and read what it did"),
    // ---- identity, signing and the network binding -------------------------------------------
    plain!("sign", ReadOnly, crate::host::sign, "Sign a message with this node's identity key"),
    plain!("verify", ReadOnly, crate::host::verify, "Verify a signature against a node's public key"),
    plain!("binding_state", ReadOnly, crate::host::binding_state, "This node's binding to its peers and services"),
    plain!("binding_transport", ReadOnly, crate::host::binding_transport, "Transport state for the binding (rendezvous, relay, direct)"),
    plain!("beat", ReadOnly, crate::host::beat, "Report progress on the current run so /health can tell a stuck node from an idle one"),
    plain!("relay", Network, crate::host::relay, "POST to a peer and forward its SSE reply lines to the UI unchanged"),
    // ---- HTTP --------------------------------------------------------------------------------
    plain!("http", Network, crate::host::http, "One bounded HTTP request; returns status, headers and body"),
    plain!("http_stream", Network, crate::host::http_stream, "A streaming HTTP request, delivering body chunks to Lua"),
    plain!("http_sse", Network, crate::host::http_sse, "A streaming HTTP request that hands over server-sent event lines"),
    // ---- plugins -----------------------------------------------------------------------------
    upvalue!("plugins", ReadOnly, crate::host::plugins, "List the registered WASM plugins and their declared parameters"),
    upvalue!("invoke", RunsProcess, crate::host::invoke, "Invoke one registered WASM plugin with JSON arguments"),
    // ---- WASI components ---------------------------------------------------------------------
    plain!("components", ReadOnly, wa_kernel_runtime::components::components, "List installed WASI components: pin state and declared capabilities"),
    plain!("service", RunsProcess, wa_kernel_runtime::services::service, "Supervise long-lived WASI service components (docs/SERVICE-COMPONENTS.md): start, stop, status, logs, the transactional upgrade, the effective configuration profile and the start-by-imports reconcile"),
    plain!("component_mcp", RunsProcess, wa_kernel_runtime::components::component_mcp, "One MCP request (probe or call) against a pinned WASI component, with exactly the granted env/file/network capabilities"),
    plain!("state", WritesFiles, wa_kernel_runtime::state_host::capability, "Component state: status, dry run, export, import and verify of a component's versioned kv namespace, its migration journal and its snapshots"),
    // The memory seam (docs/MEMORY.md, docs/KERNEL.md "Memory as a component"): the `memory` component
    // answers recall/remember/forget/list/search_messages/sessions over a scoped `wa:kernel/sql`
    // grant. `WA_MEMORY_COMPONENT=1` is what routes `lua/core/memory.lua` here; without it the native
    // path is used, so this capability is inert on a node that never opts in.
    plain!("memory", WritesFiles, wa_kernel_runtime::memory_host::capability, "One wa:memory call against the installed memory component: remember, recall, forget, list, search_messages, sessions or the retention decision, over a scoped wa:kernel/sql grant"),
    // The self-loop seam (docs/CORE-SPLIT.md, docs/KERNEL.md "The self-loop as a component"): the
    // `selfloop` component answers the wake/notes/probe state machine over its own scoped
    // `wa:kernel/sql` grant. `WA_SELFLOOP_COMPONENT=1` is what routes `lua/core/selfloop.lua` here;
    // without it the native path runs, so this capability is inert on a node that never opts in.
    plain!("selfloop", WritesFiles, wa_kernel_runtime::selfloop_host::capability, "One wa:selfloop call against the installed selfloop component: the wake/notes/probe state machine (schedule, list, cancel, summary, notes, publish, plan, claim, settle, finish, turn) over a scoped wa:kernel/sql grant"),
    // The hooks/mods seam (docs/CORE-SPLIT.md, docs/HOOK-EVENTS.md): the `hooks` component answers
    // "what is configured for this event", "which entries run, in which order", "what does this answer
    // mean" and "what does the footer say". `WA_HOOKS_COMPONENT=1` is what routes
    // `lua/core/hooks.lua` here; without it the native engine runs, so this capability is inert on a
    // node that never opts in. The component holds no capability: the node reads the config files and
    // runs the hooks, and this call never runs a process.
    plain!("hooks", ReadOnly, wa_kernel_runtime::hooks_host::capability, "One wa:hooks call against the installed hooks component: the catalogue, the merged config view, the entries an event runs in order, one hook's answer interpreted into the decision, or the footer segment"),
    // ---- WhatsApp (docs/SERVICE-COMPONENTS.md, docs/GRANT-POLICY.md) ---------------------------
    // One capability per effect: `whatsapp_send` asks the node's `whatsapp.send` policy and enqueues
    // a job on `wa:queue`; `whatsapp_send_status` reads the job back. Neither carries message text
    // out in its answer.
    plain!("whatsapp_send", Network, crate::whatsapp_send::capability, "Send one WhatsApp message to an exact chat JID through the durable whatsapp.outbox queue, after the whatsapp.send policy check; returns the job id"),
    plain!("whatsapp_send_status", ReadOnly, crate::whatsapp_send::status_capability, "State of one queued WhatsApp send: queued, sending, done with its message id, or failed with a reason"),
    // The message index the component keeps: one capability per question, all of them a job on
    // `whatsapp.query` (read-only, so no policy rule and no rate limit of their own).
    plain!("whatsapp_search", ReadOnly, crate::whatsapp_query::search, "Search indexed WhatsApp messages by text (accent-folded), chat, kind, sender or time window; returns matching records with snippets"),
    plain!("whatsapp_read", ReadOnly, crate::whatsapp_query::read, "Read one WhatsApp chat newest-first, with reactions folded onto the messages they answer"),
    plain!("whatsapp_reactions", ReadOnly, crate::whatsapp_query::reactions, "Who reacted to one WhatsApp message, with which emoji"),
    plain!("whatsapp_media", ReadOnly, crate::whatsapp_query::media, "The media metadata of one WhatsApp message: mime, filename, size, sha256, duration, pages"),
    plain!("whatsapp_download", WritesFiles, crate::whatsapp_query::download, "Decrypt one WhatsApp message's media into this node's bounded download folder and return the path"),
    // The one query that asks the phone: it enqueues on the same `whatsapp.query` queue, and the
    // component's answer is the history request it made (ids and counts), never a message.
    plain!("whatsapp_backfill", Network, crate::whatsapp_query::backfill, "Ask the primary phone for WhatsApp messages older than the index holds, so a search can reach the account's past"),
    // ---- Email (docs/EMAIL-CONNECTOR.md) -------------------------------------------------------
    // The same two shapes as the WhatsApp tools: an effect (`email_send`) is a job on `email.outbox`
    // after the node's `email.send` policy check, a question (`email_search`/`email_read`) is a job on
    // `email.query`, and `email_send_status` reads the send back. Recipients are audited as a digest,
    // never as an address.
    plain!("email_send", Network, crate::email_send::capability, "Send one email through the durable email.outbox queue, after the email.send policy check; returns the job id, never the delivery"),
    plain!("email_send_status", ReadOnly, crate::email_send::status_capability, "State of one queued email send: queued, sending, done with its message id, or failed with a reason"),
    plain!("email_search", ReadOnly, crate::email_query::search, "Search every indexed email by text (accent-folded), sender, subject, mailbox or time window; returns matching messages with snippets"),
    plain!("email_read", ReadOnly, crate::email_query::read, "Read one mailbox newest first, or one message by uid: envelope, subject, text and attachments"),
    plain!("email_media", ReadOnly, crate::email_query::media, "The attachment metadata of one indexed email, with the media handle a download can name"),
    // ---- node governance (docs/GRANT-POLICY.md, docs/TELEMETRY.md) ----------------------------
    plain!("policy_status", ReadOnly, wa_governance::node_policy::capability, "The grant policy's state as JSON: file and load error, decision counters, recent refusals without target text, and the audit trail's health"),
    plain!("telemetry", ReadOnly, wa_governance::node_telemetry::capability, "This node's telemetry as Prometheus text or JSON: component and host-call latency, service health, sampled spans, rollups and the bounded stores' usage"),
    // ---- the speech queue (docs/QUEUE.md "Phase 2", docs/WHATSAPP-TRANSCRIPTION.md) -------------
    // One capability per thing the Lua side does: the producing node answers a peer's call, an
    // operator submits or reads the queue, and the worker role borrows the two halves of a pump.
    plain!("stt_call", WritesFiles, crate::stt::call, "One admitted stt.requests call from a peer node (take/audio/beat/seg/done/fail): the producing node's queue, its lease rule and its audio"),
    plain!("stt_submit", WritesFiles, crate::stt::submit, "Enqueue one note on stt.requests with its chat/message ids and send time; the freshness window starts at the send time"),
    plain!("stt_admin", WritesFiles, crate::stt::admin, "The speech queue's operator surface: configure the node's producer/worker role, status (attached workers, latency, local vs remote counts), one job's state, a sweep"),
    plain!("stt_pending", ReadOnly, crate::stt::pending, "The next signed stt.requests call the worker thread wants sent (null when idle), for the node's Lua pump"),
    plain!("stt_deliver", ReadOnly, crate::stt::deliver, "Deliver one peer answer to the waiting worker thread and return the next pending call"),
    // ---- audio -------------------------------------------------------------------------------
    // The contract is one entry because it is one capability with two calls: `capture` (the ear)
    // and `play` (the mouth). Voice itself is the `voice` WASM plugin; this is only the transport.
    plain!("audio", Device, crate::audio::capability, "The file-backed ear and mouth: capture PCM chunks from a WAV source, or play PCM into a WAV sink, both confined to the declared audio root"),
    // ---- the user's machine and the desktop client -------------------------------------------
    upvalue!("client", Device, crate::host::client, "Act on the user's machine through the outbound client bridge: screenshot, input, shell, browser/CDP"),
    upvalue!("client_status", ReadOnly, crate::host::client_status, "Whether the desktop client is connected, and what it is doing"),
    // ---- the console -------------------------------------------------------------------------
    plain!("isatty", Device, crate::host::stream_is_terminal, "Whether standard input/output/error is a terminal"),
    plain!("terminal_size", Device, crate::host::terminal_size, "The console's own width and height"),
    plain!("terminal_write", Device, crate::host::terminal_write, "Write to the real console, serialized with the editor and the ticker"),
    plain!("ticker", Device, crate::host::ticker, "Start or stop the CLI status line, which keeps drawing while the interpreter is blocked"),
    plain!("input_start", Device, crate::host::input_start, "Start the one off-thread console line reader"),
    plain!("input_editor", Device, crate::host::input_editor, "Repaint the live editor's input row"),
    plain!("panel", Device, crate::host::panel, "Open, replace or close the CLI's bottom panel and wait for the reader's choice"),
    plain!("transcript_write", Device, crate::host::transcript_write, "Append text to the CLI transcript's current block"),
    plain!("transcript_block", Device, crate::host::transcript_block, "Start a CLI transcript block (a collapsible topic or plain text)"),
    plain!("status_snapshot", Device, crate::host::status_snapshot, "Store the /status panel the CLI shows by itself while a run is in flight"),
    plain!("transcript_hold", Device, crate::host::transcript_hold, "Keep CLI transcript writes undrawn until released, then draw once"),
    plain!("editor_status", Device, crate::host::editor_status, "Show or hide the CLI's status line row (shown while a run is in flight)"),
    plain!("editor_footer", Device, crate::host::editor_footer, "Set the hint row under the CLI's input box"),
    plain!("input_commands", Device, crate::host::input_commands, "Set the commands the CLI's slash menu offers"),
    plain!("input_held", Device, crate::host::input_held, "List lines the CLI took but holds as still queued above its status line"),
    plain!("input_take", Device, crate::host::input_take, "Take lines the reader buffered while a run was in flight"),
    plain!("input_stop", Device, crate::host::input_stop, "Stop the console line reader"),
    plain!("input_idle", Device, crate::host::input_idle, "Whether the CLI could restart now: empty draft, no panel, nothing queued, no selection"),
    plain!("binary_changed", ReadOnly, crate::host::binary_changed, "Whether this process's wa binary was replaced on disk since it started"),
    plain!("cli_reexec", RunsProcess, crate::host::cli_reexec, "Replace the interactive CLI process with the installed wa binary (restart into a session)"),
    plain!("stream", Device, crate::host::stream, "Push one server-sent event to the connected UI page"),
    // ---- this inventory ----------------------------------------------------------------------
    plain!("capability_inventory", ReadOnly, inventory_capability, "List every host capability as JSON: name, one-line description and effect class"),
];

/// The registry, stably ordered by name. This is what every surface answers with, so two callers
/// comparing output do not have to know the declaration order.
pub fn inventory() -> Vec<&'static Capability> {
    let mut items: Vec<&'static Capability> = REGISTRY.iter().collect();
    items.sort_by(|a, b| a.name.cmp(b.name));
    items
}

/// The inventory as the JSON array every surface returns: `[{name, description, effect}, ...]`,
/// sorted by name. Deterministic byte-for-byte, because `/health` publishes its digest.
pub fn inventory_json() -> String {
    let items: Vec<Value> = inventory()
        .into_iter()
        .map(|cap| {
            json!({
                "name": cap.name,
                "description": cap.description,
                "effect": cap.effect.as_str(),
            })
        })
        .collect();
    serde_json::to_string(&Value::Array(items)).expect("capability inventory is serializable")
}

/// SHA-256 of [`inventory_json`] - the same value `/health` publishes as `sha256`. The installed Lua
/// tree pins it (main.rs `load_lua_tree`, `wa --capability-digest`): a Lua tree only runs on a binary
/// whose capability surface it was installed for.
pub fn digest() -> String {
    digest_of(&inventory_json())
}

/// SHA-256 of an inventory document, so a caller that already has the text does not serialize it
/// twice - `/health` is polled, and its digest has to be of exactly the bytes the CLI prints.
fn digest_of(text: &str) -> String {
    ring_digest(&SHA256, text.as_bytes())
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// The compact form `/health` publishes: the names and the digest of the list, never the
/// descriptions. `/health` is polled, so the whole inventory would make every poll pay for text
/// nobody read; `wa capabilities --json` is the place to ask for the long form.
pub fn health() -> Value {
    let text = inventory_json();
    json!({
        "count": REGISTRY.len(),
        "names": inventory().into_iter().map(|cap| cap.name).collect::<Vec<_>>(),
        "sha256": digest_of(&text),
    })
}

/// Register every capability into the `host` table. The only registration site: the interpreter
/// cannot grow a `host.*` function this list does not name.
pub fn register(lua: &wa_host_support::lua::Lua, host_ptr: *mut c_void) {
    for capability in REGISTRY {
        match capability.bind {
            Bind::Plain(function) => lua.register(capability.name, function),
            Bind::Upvalue(function) => lua.register_with_upvalue(capability.name, function, host_ptr),
        }
    }
}

/// `host.capability_inventory()` -> the JSON array from [`inventory_json`].
///
/// One implementation, three surfaces: the CLI prints it, the codemode sandbox hands it to JS, and
/// `/health` publishes its names and digest.
pub extern "C-unwind" fn inventory_capability(l: *mut wa_host_support::lua::LuaState) -> c_int {
    let text = inventory_json();
    unsafe {
        wa_host_support::lua::lua_pushlstring(l, text.as_ptr() as *const std::os::raw::c_char, text.len());
    }
    1
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    /// The canonical list in `docs/HOST.md`, between these markers. Hand-maintained on purpose:
    /// the point of the test is that the document and the registry have to be made to agree by a
    /// human, and a generated block would only prove the generator ran.
    const DOC_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../docs/HOST.md");
    const DOC_BEGIN: &str = "<!-- capability-inventory:begin -->";
    const DOC_END: &str = "<!-- capability-inventory:end -->";

    fn documented() -> BTreeMap<String, String> {
        let text = std::fs::read_to_string(DOC_PATH).expect("docs/HOST.md is readable");
        let start = text.find(DOC_BEGIN).expect("docs/HOST.md has the inventory begin marker") + DOC_BEGIN.len();
        let end = text[start..]
            .find(DOC_END)
            .expect("docs/HOST.md has the inventory end marker")
            + start;
        let mut rows = BTreeMap::new();
        for line in text[start..end].lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with(';') {
                continue;
            }
            let mut parts = line.splitn(2, char::is_whitespace);
            let name = parts.next().expect("row name").trim().trim_matches('`');
            let effect = parts.next().unwrap_or("").trim();
            assert!(
                Effect::parse(effect).is_some(),
                "docs/HOST.md documents `{name}` with an unknown effect class {effect:?}"
            );
            assert!(
                rows.insert(name.to_string(), effect.to_string()).is_none(),
                "docs/HOST.md documents `{name}` twice"
            );
        }
        rows
    }

    fn registered() -> BTreeMap<String, String> {
        let mut rows = BTreeMap::new();
        for capability in REGISTRY {
            assert!(
                rows.insert(
                    capability.name.to_string(),
                    capability.effect.as_str().to_string()
                )
                .is_none(),
                "the registry registers `{}` twice",
                capability.name
            );
        }
        rows
    }

    /// The point of the whole change: a capability registered but undocumented, or documented but
    /// absent, fails here with the exact names - not with a diff somebody has to read.
    #[test]
    fn documented_inventory_matches_the_live_registry() {
        let documented = documented();
        let registered = registered();
        let undocumented: Vec<&str> = registered
            .keys()
            .filter(|name| !documented.contains_key(*name))
            .map(String::as_str)
            .collect();
        let absent: Vec<&str> = documented
            .keys()
            .filter(|name| !registered.contains_key(*name))
            .map(String::as_str)
            .collect();
        assert!(
            undocumented.is_empty(),
            "registered but undocumented in docs/HOST.md: {undocumented:?}"
        );
        assert!(
            absent.is_empty(),
            "documented in docs/HOST.md but not registered: {absent:?}"
        );
        for (name, effect) in &registered {
            assert_eq!(
                documented.get(name),
                Some(effect),
                "docs/HOST.md gives `{name}` a different effect class than the registry"
            );
        }
    }

    #[test]
    fn every_entry_has_a_usable_description() {
        for capability in REGISTRY {
            assert!(
                !capability.description.trim().is_empty(),
                "`{}` has no description",
                capability.name
            );
            assert!(
                capability.description.len() <= 240,
                "`{}` has a description that is not one line",
                capability.name
            );
            assert!(
                !capability.description.ends_with('.'),
                "`{}` description ends with a period",
                capability.name
            );
        }
    }

    /// The surfaces have to be diffable: same bytes, same order, every call.
    #[test]
    fn inventory_is_sorted_and_deterministic() {
        let names: Vec<&str> = inventory().into_iter().map(|cap| cap.name).collect();
        let mut sorted = names.clone();
        sorted.sort_unstable();
        assert_eq!(names, sorted, "the inventory is not stably ordered by name");
        assert_eq!(inventory_json(), inventory_json());
        assert_eq!(digest(), digest());
        assert_eq!(digest().len(), 64);
    }

    /// `wa capabilities --json` has to parse as JSON and carry all three fields per entry.
    #[test]
    fn inventory_json_parses_and_lists_every_capability() {
        let value: Value = serde_json::from_str(&inventory_json()).expect("valid JSON");
        let array = value.as_array().expect("a JSON array");
        assert_eq!(array.len(), REGISTRY.len());
        for entry in array {
            for field in ["name", "description", "effect"] {
                assert!(entry[field].is_string(), "entry without {field}: {entry}");
            }
            assert!(
                Effect::parse(entry["effect"].as_str().unwrap()).is_some(),
                "unknown effect class in {entry}"
            );
        }
        let names: Vec<&str> = array.iter().map(|e| e["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"exec") && names.contains(&"read_file"));
        assert!(names.contains(&"capability_inventory"));
    }

    /// The description and effect the sandbox answers with are the registry's, not a copy.
    #[test]
    fn the_inventory_is_the_registry() {
        for capability in inventory() {
            let from_registry = REGISTRY
                .iter()
                .find(|candidate| candidate.name == capability.name)
                .expect("inventory entry comes from the registry");
            assert_eq!(from_registry.description, capability.description);
            assert_eq!(from_registry.effect, capability.effect);
        }
    }
}
