//! The node's capability inventory: the *one* list of `host.*` functions.
//!
//! Before this module the only way to learn what a node can do was to grep `rust/` for
//! `lua.register` calls and read `docs/HOST.md` beside them, in two languages, and hope the two
//! agreed. They did not have a way to disagree loudly: a registered capability nobody documented
//! and a documented capability nobody registered were both silent.
//!
//! Registration and inventory are the same act here, and a capability's registration is DATA: its
//! name, its effect class, its one-line description and its handler are one `plain!`/`upvalue!` row
//! in a file under `src/capability_rows/`, one file per area, beside the module that implements the
//! handler. This module collects those files - `build.rs` lists every file in that directory
//! (`registry_scan`), so ADDING OR MOVING A CAPABILITY EDITS ITS OWN FILE AND NOT THIS ONE - and
//! [`register`] walks the collected rows, which makes them the live registry rather than a second
//! hand-written copy. Everything that answers "what can this node do" reads it:
//!
//! - `wa capabilities --json` (CLI, through `host.capability_inventory`),
//! - the `capabilities` field of `/health` (names + a digest, never the descriptions),
//! - `capabilities()` and `describe(name)` inside the codemode sandbox,
//! - and the drift test in this module's `tests`, which fails when `docs/HOST.md` and those rows
//!   disagree in either direction.

use wa_host_support::lua::HostFn;
use ring::digest::{digest as ring_digest, SHA256};
use serde_json::{json, Value};
use std::ffi::{c_int, c_void};
use std::sync::OnceLock;

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
/// the shared plugin/bridge state) says so in its own row, so a row file is the only place a
/// registration can happen.
#[derive(Clone, Copy)]
pub enum Bind {
    Plain(HostFn),
    /// Bound with `lua.register_with_upvalue` and the interpreter's `host_ptr`.
    Upvalue(HostFn),
}

#[derive(Clone, Copy)]
pub struct Capability {
    pub name: &'static str,
    /// One line, no trailing period: the same text the CLI, the sandbox and `/health` callers read.
    pub description: &'static str,
    pub effect: Effect,
    pub bind: Bind,
}

/// One row, bound plainly (`lua.register`). `$crate` keeps a row file free of imports beyond the
/// macro itself: the row names its area and nothing else.
macro_rules! plain {
    ($name:literal, $effect:ident, $f:path, $description:literal) => {
        $crate::capabilities::Capability {
            name: $name,
            description: $description,
            effect: $crate::capabilities::Effect::$effect,
            bind: $crate::capabilities::Bind::Plain($f),
        }
    };
}
pub(crate) use plain;

/// The same row bound with `lua.register_with_upvalue` and the interpreter's `host_ptr`.
macro_rules! upvalue {
    ($name:literal, $effect:ident, $f:path, $description:literal) => {
        $crate::capabilities::Capability {
            name: $name,
            description: $description,
            effect: $crate::capabilities::Effect::$effect,
            bind: $crate::capabilities::Bind::Upvalue($f),
        }
    };
}
pub(crate) use upvalue;

/// The rows: one module per file in `src/capability_rows/`. `build.rs` writes this list
/// (`registry_scan`), so a row file is discovered without an edit here - that is what makes a
/// capability, and the component it moves into, carry its registration with it.
mod capability_rows {
    include!(concat!(env!("OUT_DIR"), "/capability_rows.rs"));
}

/// The live registry: the rows of every row file, flattened in file order. `main.rs` boots the
/// interpreter from it, so a capability that is not in a row file is not one the Lua side can call,
/// and a capability the Lua side can call is in a row file.
///
/// Built once: `/health` is polled and `inventory()` copies this list on every call.
pub fn registry() -> &'static [Capability] {
    static REGISTRY: OnceLock<Vec<Capability>> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        capability_rows::SECTIONS.iter().flat_map(|rows| rows.iter().copied()).collect()
    })
}

/// The registry, stably ordered by name. This is what every surface answers with, so two callers
/// comparing output do not have to know the declaration order.
pub fn inventory() -> Vec<&'static Capability> {
    let mut items: Vec<&'static Capability> = registry().iter().collect();
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
        "count": registry().len(),
        "names": inventory().into_iter().map(|cap| cap.name).collect::<Vec<_>>(),
        "sha256": digest_of(&text),
    })
}

/// Register every capability into the `host` table. The only registration site: the interpreter
/// cannot grow a `host.*` function this list does not name.
pub fn register(lua: &wa_host_support::lua::Lua, host_ptr: *mut c_void) {
    for capability in registry() {
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
        for capability in registry() {
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
        for capability in registry() {
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
        assert_eq!(array.len(), registry().len());
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
            let from_registry = registry()
                .iter()
                .find(|candidate| candidate.name == capability.name)
                .expect("inventory entry comes from the registry");
            assert_eq!(from_registry.description, capability.description);
            assert_eq!(from_registry.effect, capability.effect);
        }
    }
}
