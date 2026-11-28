//! `host.local_tz`'s identifier, answered by the `tz` component (`rust/components/tz`).
//!
//! WHAT THIS REPLACED. `rust/wa-local-tz` was linked into `wa` itself for this one answer, so a change to
//! how the OS's zone is read rebuilt the whole node - 443 lines of decision the binary never needed at
//! its own call sites. The component holds that decision now, and this is the seam: one MCP call, the
//! same shape `graph.rs` uses (`wa_kernel_runtime::components::mcp`), with `/etc` mounted read-only and
//! `TZ` passed through from the node's own resolved environment.
//!
//! WHY NOT ASK THE COMPONENT EVERY TIME. `host.local_tz` is read on the guest's clock calls, and the
//! answer changes when the operator changes their zone - practically never. The answer is cached per
//! process and per `TZ` value, so the cost is one component start per node run, not one per call. A
//! component that cannot answer falls back to the OS reading the *caller* still holds (`TZ` and the
//! /etc files are the host's own facts, so a missing component is a missing artifact, not a missing
//! truth) - and the node says so in `zone_source` rather than pretending the zone is UTC.
use serde_json::{json, Value};
use std::sync::{Mutex, OnceLock};

const COMPONENT: &str = "tz";

/// The zone this node is in, as `{id, source}`: `id` absent means the OS holds no name.
pub fn zone() -> Option<(Option<String>, String)> {
    let tz = crate::host::resolved_env("TZ");
    // THE CACHE IS KEYED ON WHAT THE NODE WOULD RUN, not only on TZ (28/11). A cache keyed on the
    // environment alone makes a component SWAP invisible: the decision is "one download, one swap, no
    // restart" (everything-is-a-component, (iii)), and a seam that answered from memory would keep the old
    // zone after a new artifact landed. The pin file is the identity the loader itself checks
    // (`components::load` refuses bytes that do not match it), so reading it is both the cheapest and the
    // truest key: a swap changes the pin, and the next call asks the new component.
    let pin = std::fs::read_to_string(
        wa_kernel_runtime::components::component_dir().join("tz.wasm.sha256"),
    )
    .ok()
    .and_then(|text| text.split_whitespace().next().map(str::to_string));
    static CACHE: OnceLock<Mutex<Option<(Option<String>, String, Option<String>, Option<String>)>>> =
        OnceLock::new();
    let cell = CACHE.get_or_init(|| Mutex::new(None));
    if let Ok(held) = cell.lock() {
        if let Some((id, source, cached_tz, cached_pin)) = held.as_ref() {
            if *cached_tz == tz && *cached_pin == pin {
                return Some((id.clone(), source.clone()));
            }
        }
    }
    let request = json!({
        "action": "call", "component": COMPONENT, "tool": "zone", "arguments": {},
        "dirs": [{"host": "/etc", "guest": "/etc", "write": false}],
        "env": {"TZ": "TZ"},
        "timeout_seconds": 10,
    });
    let answer = wa_kernel_runtime::components::mcp(&request);
    if answer["ok"] != json!(true) {
        return None;
    }
    let result: Value = answer["result_json"]
        .as_str()
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
        .map(|result| result["structuredContent"].clone())
        .unwrap_or(Value::Null);
    let id = result["id"].as_str().map(str::to_string);
    let source = result["source"].as_str().unwrap_or("tz_component_no_source").to_string();
    if let Ok(mut held) = cell.lock() {
        *held = Some((id.clone(), source.clone(), tz, pin.clone()));
    }
    Some((id, source))
}
