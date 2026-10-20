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
use crate::lua::HostFn;
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
    plain!("input_take", Device, crate::host::input_take, "Take lines the reader buffered while a run was in flight"),
    plain!("input_stop", Device, crate::host::input_stop, "Stop the console line reader"),
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

/// SHA-256 of [`inventory_json`]. Test-only, like the parser above: [`health`] digests the text it
/// already built, so this is the shape the tests assert rather than a second production path.
#[cfg(test)]
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
pub fn register(lua: &crate::lua::Lua, host_ptr: *mut c_void) {
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
pub extern "C-unwind" fn inventory_capability(l: *mut crate::lua::LuaState) -> c_int {
    let text = inventory_json();
    unsafe {
        crate::lua::lua_pushlstring(l, text.as_ptr() as *const std::os::raw::c_char, text.len());
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
