//! Profiles as layers: the effective configuration is an ordered stack of rows addressed by id
//! (`docs/KERNEL.md`, lesson 4).
//!
//! Four layers, applied in this order and never reordered:
//!
//! 1. **base** - what the shipped binary knows (`base.json` beside the component definitions, or the
//!    compiled-in rows below when there is no file);
//! 2. **node** - what this machine's operator wrote (`<state>/profiles/node.json`);
//! 3. **user** - what the user running the node wrote (`<state>/profiles/user.json`);
//! 4. **patch** - one installation's or one experiment's override (`<state>/profiles/patch.json`, or
//!    a `patch` object in the request).
//!
//! A layer is an object of **rows by id** (`{"whatsapp": {...}, "default": {...}}`), and a row is a
//! JSON object. Merging is per row *and* per key, recursively for nested objects, so a node layer that
//! sets one key of one row does not erase the rest of the row. A `null` value removes the key it names:
//! that is how a later layer turns something off without deleting the row, and it is the only way to
//! say "unset", because an absent key means "inherit".
//!
//! Why rows and not one flat object: the same effective configuration has to answer two questions at
//! once - "what does *this* component run with" (row `wa-whatsapp` or the `default` row) and "what did
//! the operator change" (a diff of the rows). A flat object answers the first badly and the second not
//! at all.
//!
//! Nothing here is a capability: a profile row can say `language = pt`, it cannot grant `net`. Grants
//! stay in the manifest and the node policy (`docs/GRANT-POLICY.md`); a profile can only shape the
//! non-secret `config` a component is started with, which is the same data the `services` definition
//! already carries.

use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::path::PathBuf;

/// The layer names, in application order. `Effective::layers` reports which ones existed, so
/// `profile_dump` says "the node layer is empty" instead of looking the same either way.
pub const LAYERS: [&str; 4] = ["base", "node", "user", "patch"];

/// Rows a node has when nobody wrote anything: the shipped defaults, by id. Deliberately tiny - a
/// default that is not needed is a default nobody can find the reason for.
fn base_rows() -> Value {
    json!({
        "default": {
            "limits": {"memory_mb": 512, "cpu_ms": 5000}
        }
    })
}

/// One resolved configuration: the rows, and which layers contributed.
#[derive(Clone, Debug)]
pub struct Effective {
    pub rows: BTreeMap<String, Value>,
    /// `(layer, rows it wrote)` for every layer that existed. A layer that is not there is absent from
    /// this list, which is what makes `profile_dump` honest about an empty stack.
    pub layers: Vec<(&'static str, Vec<String>)>,
}

impl Effective {
    pub fn row(&self, id: &str) -> Option<&Value> {
        self.rows.get(id)
    }

    /// The configuration one component runs with: its own row over the `default` row, per key.
    ///
    /// `default` is a row like any other, so a node can set `language` for every component once and
    /// one component can override it in its own row. A component with no row of its own gets `default`.
    pub fn config_for(&self, component: &str) -> Value {
        let mut config = self.rows.get("default").cloned().unwrap_or_else(|| json!({}));
        if let (Some(base), Some(own)) = (config.as_object_mut(), self.rows.get(component).and_then(Value::as_object)) {
            merge_object(base, own);
        }
        // `limits` is the kernel's, not a component's opinion: it stays visible but is not passed to a
        // guest as configuration.
        if let Some(object) = config.as_object_mut() {
            object.remove("limits");
        }
        config
    }

    /// The `limits` a component's row asks for, over the `default` row. The kernel caps whatever comes
    /// out of here (`wa_governance::component_limits`); a profile can only ask for less.
    pub fn limits_for(&self, component: &str) -> Value {
        let mut limits = self.rows.get("default").and_then(|row| row.get("limits")).cloned().unwrap_or_else(|| json!({}));
        if let (Some(object), Some(own)) = (
            limits.as_object_mut(),
            self.rows.get(component).and_then(|row| row.get("limits")).and_then(Value::as_object),
        ) {
            merge_object(object, own);
        }
        limits
    }

    pub fn to_json(&self) -> Value {
        json!({
            "rows": self.rows,
            "layers": self.layers.iter().map(|(name, rows)| json!({"layer": name, "rows": rows})).collect::<Vec<_>>(),
        })
    }
}

/// Merge `over` into `into`, recursively for objects; `null` in `over` removes the key.
fn merge_object(into: &mut Map<String, Value>, over: &Map<String, Value>) {
    for (key, value) in over {
        match value {
            Value::Null => {
                into.remove(key);
            }
            Value::Object(nested) => {
                let entry = into.entry(key.clone()).or_insert_with(|| json!({}));
                if !entry.is_object() {
                    *entry = json!({});
                }
                if let Some(object) = entry.as_object_mut() {
                    merge_object(object, nested);
                }
            }
            other => {
                into.insert(key.clone(), other.clone());
            }
        }
    }
}

/// Apply an ordered stack of layers. Each layer is `{row id: {key: value}}`; a layer that is not an
/// object is refused by the caller ([`load`] and [`resolve`] report it), never merged as nothing.
pub fn resolve(layers: impl IntoIterator<Item = (&'static str, Value)>) -> Effective {
    let mut rows: BTreeMap<String, Value> = BTreeMap::new();
    let mut applied = Vec::new();
    for (name, layer) in layers {
        let Some(object) = layer.as_object() else {
            // A layer that is present but is not a map of rows is reported as "named, wrote nothing":
            // the stack stays truthful about what exists, and the mistake is visible in `layers`.
            applied.push((name, Vec::new()));
            continue;
        };
        let mut wrote = Vec::new();
        for (id, row) in object {
            let entry = rows.entry(id.clone()).or_insert_with(|| json!({}));
            match (entry.as_object_mut(), row) {
                (Some(into), Value::Object(over)) => merge_object(into, over),
                (Some(into), Value::Null) => {
                    // A whole row set to null removes the row: "this component has no profile", not
                    // "an empty one".
                    into.clear();
                    wrote.push(id.clone());
                    continue;
                }
                (Some(into), other) => {
                    // A row that is not an object is a configuration mistake; keep it as a `value` key
                    // rather than dropping it, so `profile_dump` shows what was written.
                    into.insert("value".into(), other.clone());
                }
                (None, _) => {}
            }
            wrote.push(id.clone());
        }
        applied.push((name, wrote));
    }
    Effective { rows, layers: applied }
}

/// Where the layers live.
pub fn layer_path(layer: &str) -> Option<PathBuf> {
    if !LAYERS.contains(&layer) {
        return None;
    }
    let root = wa_governance::store::state_root().join("profiles");
    Some(root.join(format!("{layer}.json")))
}

/// The node's effective configuration: `base`, then whichever of the three files exist.
///
/// A layer that exists and does not parse is **reported** in the answer (and on the log) and skipped:
/// profiles shape configuration, not authority, so a broken user layer must not stop a node - but it
/// must not be silently ignored either, which is the reason `errors` exists.
pub fn load() -> (Effective, Vec<Value>) {
    let mut layers: Vec<(&'static str, Value)> = vec![("base", base_rows())];
    let mut errors = Vec::new();
    for layer in ["node", "user", "patch"] {
        let Some(path) = layer_path(layer) else { continue };
        match std::fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str::<Value>(&text) {
                Ok(value) if value.is_object() => layers.push((LAYERS[LAYERS.iter().position(|l| *l == layer).unwrap()], value)),
                Ok(_) => errors.push(json!({"layer": layer, "error": "profile_not_an_object", "path": path.to_string_lossy()})),
                Err(error) => errors.push(json!({"layer": layer, "error": format!("profile_invalid:{error}"), "path": path.to_string_lossy()})),
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => errors.push(json!({"layer": layer, "error": format!("profile_unreadable:{error}"), "path": path.to_string_lossy()})),
        }
    }
    let effective = resolve(layers);
    for error in &errors {
        eprintln!("[profiles] {}: {}", error["layer"].as_str().unwrap_or("?"), error["error"].as_str().unwrap_or("?"));
    }
    (effective, errors)
}

/// `services profile_dump [name]`: the effective stack, and - with a name - what that component would
/// be started with.
pub fn dump(name: Option<&str>) -> Value {
    let (effective, errors) = load();
    let mut answer = json!({
        "ok": true,
        "order": LAYERS,
        "effective": effective.to_json(),
        "errors": errors,
    });
    if let Some(name) = name {
        answer["component"] = json!(name);
        answer["config"] = effective.config_for(name);
        answer["limits"] = effective.limits_for(name);
        answer["node_limits"] = crate::limits::caps().to_json();
    }
    answer
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layer(pairs: &[(&str, Value)]) -> Value {
        let mut map = Map::new();
        for (id, row) in pairs {
            map.insert(id.to_string(), row.clone());
        }
        Value::Object(map)
    }

    #[test]
    fn the_last_layer_wins_per_key_and_a_null_removes_a_key() {
        let base = layer(&[("wa-whatsapp", json!({"language": "pt", "post_transcripts": false, "alerts": true}))]);
        let node = layer(&[("wa-whatsapp", json!({"post_transcripts": true}))]);
        let user = layer(&[("wa-whatsapp", json!({"alerts": null}))]);
        let patch = layer(&[("wa-whatsapp", json!({"language": "en"}))]);
        let effective = resolve([("base", base), ("node", node), ("user", user), ("patch", patch)]);
        let row = effective.row("wa-whatsapp").unwrap();
        assert_eq!(row["language"], "en", "the last layer that names a key wins");
        assert_eq!(row["post_transcripts"], true, "a node layer changes one key and keeps the rest");
        assert!(row.get("alerts").is_none(), "null removes the key rather than setting it to null");
        // The order is the contract, so it is also what the answer reports.
        assert_eq!(effective.layers.iter().map(|(name, _)| *name).collect::<Vec<_>>(), vec!["base", "node", "user", "patch"]);
    }

    #[test]
    fn nested_objects_merge_instead_of_replacing() {
        let base = layer(&[("svc", json!({"limits": {"memory_mb": 256, "cpu_ms": 20}, "net": {"mode": "strict"}}))]);
        let node = layer(&[("svc", json!({"limits": {"memory_mb": 512}}))]);
        let effective = resolve([("base", base.clone()), ("node", node.clone())]);
        let limits = &effective.row("svc").unwrap()["limits"];
        assert_eq!(limits["memory_mb"], 512);
        assert_eq!(limits["cpu_ms"], 20, "a key the later layer does not name is inherited, not dropped");
        assert_eq!(effective.row("svc").unwrap()["net"]["mode"], "strict");
    }

    #[test]
    fn a_component_row_over_the_default_row_is_what_it_is_started_with() {
        let base = layer(&[("default", json!({"language": "pt", "limits": {"memory_mb": 512}}))]);
        let node = layer(&[("default", json!({"fresh_seconds": 300})), ("wa-whatsapp", json!({"language": "en"}))]);
        let effective = resolve([("base", base.clone()), ("node", node.clone())]);
        // The default row's keys are the component's unless its own row says otherwise.
        assert_eq!(effective.config_for("wa-whatsapp"), json!({"language": "en", "fresh_seconds": 300}));
        assert_eq!(effective.config_for("nothing-named"), json!({"language": "pt", "fresh_seconds": 300}));
        // `limits` is the kernel's, not guest configuration, so it does not travel as `config`.
        assert!(effective.config_for("wa-whatsapp").get("limits").is_none());
        assert_eq!(effective.limits_for("wa-whatsapp")["memory_mb"], 512);
        // A component row may lower its own limits; the kernel caps whatever comes out.
        let patch = layer(&[("wa-whatsapp", json!({"limits": {"memory_mb": 256}}))]);
        let effective = resolve([("base", base.clone()), ("node", node.clone()), ("patch", patch)]);
        assert_eq!(effective.limits_for("wa-whatsapp")["memory_mb"], 256);
    }

    #[test]
    fn a_layer_that_is_not_an_object_contributes_nothing_but_is_not_invented_either() {
        let effective = resolve([("base", base_rows()), ("node", json!(["not", "a", "map"]))]);
        assert_eq!(effective.rows.keys().cloned().collect::<Vec<_>>(), vec!["default".to_string()]);
        // The base layer is the shipped default, and it is where the limits defaults live.
        assert_eq!(effective.row("default").unwrap()["limits"]["cpu_ms"], 5000, "the shipped cpu budget");
        assert_eq!(effective.layers.len(), 2, "both layers were named, even though one wrote nothing");
        assert!(layer_path("base").is_some());
        assert!(layer_path("nonsense").is_none());
    }

    #[test]
    fn the_dump_reports_the_order_the_rows_and_the_errors() {
        let answer = dump(None);
        assert_eq!(answer["order"], json!(["base", "node", "user", "patch"]));
        assert!(answer["effective"]["rows"].is_object());
        assert!(answer["errors"].is_array());
        let answer = dump(Some("wa-whatsapp"));
        assert_eq!(answer["component"], "wa-whatsapp");
        assert!(answer["config"].is_object());
        assert!(answer["limits"].is_object());
        assert!(answer["node_limits"]["memory_mb"].is_number());
    }
}
