//! `host.features`: the node's feature switches as one capability (docs/FEATURES.md).
//!
//! The rule itself lives in `wa-features` - env override > `policy.json` `features` > default (on, since
//! 08/11) - plus "is the component installed with a verified pin" - and this is only the door the Lua side
//! reaches it through. `lua/core/features.lua` is the one Lua caller, and every gate that can choose
//! between a component and the native path asks it:
//!
//! ```text
//! host.features()                       -> {"ok":true,"policy":"…","features":[…],"mesh":{…}}
//! host.features({"feature":"memory"})   -> {"ok":true,"feature":{…}}                  (one feature)
//!                                       -> {"ok":false,"error":"unknown_feature:nope"}
//! ```
//!
//! Read-only in both shapes: it reads the policy file (one stat a second, `WA_FEATURES_WATCH_MS`) and
//! the component directory, and changes nothing. It exists as a capability rather than as a Lua-side
//! reimplementation because "which path is live" must have exactly one answer: `wa features`, this
//! capability, `services {"action":"features"}` and the gates all read the same resolver, so they
//! cannot disagree about a node.
use serde_json::Value;
use wa_host_support::lua;
use wa_host_support::json::push_json;

/// The mesh's own switch (docs/MESH.md), beside the feature table: `mesh_component` answers "which code
/// decides a peer call", and this answers "is the mesh in use on this node at all" - on by default when
/// a roster verifies against the pinned key, off (the legacy path) otherwise, and reported so an operator
/// never has to guess which one they got.
fn mesh_switch() -> Value {
    let paths = wa_mesh::host_call::Paths::resolve();
    let switch = wa_mesh::gate::cached(&paths.policy);
    serde_json::json!({
        "enabled": switch.enabled,
        "source": switch.label(),
        "problem": switch.problem,
        "policy": paths.policy.to_string_lossy(),
    })
}

pub extern "C-unwind" fn capability(l: *mut lua::LuaState) -> std::os::raw::c_int {
    let raw = lua::arg_string(l, 1).unwrap_or_default();
    // No argument at all is the whole table (`host.features()`), and so is an empty string: Lua hands a
    // missing argument over as `""`, and a caller that has nothing to ask for should not have to
    // encode `{}` to say so.
    let answer = if raw.trim().is_empty() {
        let mut document = wa_features::node_value();
        document["mesh"] = mesh_switch();
        document
    } else {
        match serde_json::from_str::<Value>(&raw) {
            Ok(Value::Null) => {
                let mut document = wa_features::node_value();
                document["mesh"] = mesh_switch();
                document
            }
            Ok(request) => match request.get("feature").and_then(Value::as_str) {
                Some(id) => wa_features::feature_value(id),
                None => {
                    let mut document = wa_features::node_value();
                    document["mesh"] = mesh_switch();
                    document
                }
            },
            Err(_) => Value::from(serde_json::json!({"ok": false, "error": "invalid_features_request"})),
        }
    };
    push_json(l, &answer);
    1
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shape the Lua door answers with, without a Lua state: a value in, a value out. The rule
    /// itself is `wa-features`' tests; this proves the door does not reshape what it is handed.
    #[test]
    fn one_feature_and_the_whole_table_are_distinguishable() {
        let one = wa_features::feature_value("memory");
        assert_eq!(one["ok"], Value::Bool(true));
        assert_eq!(one["feature"]["feature"], Value::from("memory"));
        assert!(one["features"].is_null(), "one feature is not the table");

        let all = wa_features::node_value();
        assert_eq!(all["ok"], Value::Bool(true));
        assert_eq!(all["features"].as_array().map(Vec::len), Some(wa_features::FEATURES.len()));

        let unknown = wa_features::feature_value("nope");
        assert_eq!(unknown["ok"], Value::Bool(false));
        assert_eq!(unknown["error"], Value::from("unknown_feature:nope"));
    }
}
