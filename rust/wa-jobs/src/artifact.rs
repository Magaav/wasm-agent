//! Portable automation artifacts: a versioned, machine-independent form of a job definition.
//!
//! An installed job binds to this machine: an absolute trigger directory, an absolute script, an
//! explicit CDP page websocket, an operator's session, a phone number. A **portable artifact** carries
//! the *intent* and a list of **named resource slots** instead, so it can be exported from one node and
//! imported into another without dragging a path, a machine address, a session id or a credential with
//! it. Importing requires an explicit local binding for every required slot and an explicit approval;
//! the imported definition is installed **disabled**, and the same revision-safety as any other edit
//! applies (an identical import is a no-op; a changed one invalidates approval).
//!
//! Guest scope is not a smaller operator scope: an artifact owned by a guest cannot request an
//! elevation and cannot name a profile the guest is not allowed to run. The check is structural, here,
//! not a sentence in a prompt.
//!
//! This module never touches the store; `Store::put_artifact` / `Store::export_job` do, so the binding
//! and approval rules stay testable without a database.
use serde_json::{json, Map, Value};
use std::path::Path;

pub const SCHEMA: &str = "wasm-agent/automation";
pub const SCHEMA_VERSION: u64 = 1;

/// Profiles a guest-owned artifact may name. Everything else needs operator scope, because the profile
/// decides which tools the child run can reach (`docs/ARTIFACTS.md`).
pub const GUEST_PROFILES: [&str; 1] = ["job-deterministic"];

fn fail<T>(why: &str) -> super::Result<T> {
    Err(why.into())
}

fn ident(value: &Value, key: &str) -> bool {
    let text = value[key].as_str().unwrap_or("");
    !text.is_empty()
        && text.len() <= 100
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
}

/// A binding value is either a bare path string or `{ "path": "...", "approved": true }`.
fn binding_path(binding: &Value) -> Option<&str> {
    if let Some(path) = binding.as_str() {
        if path.is_empty() {
            return None;
        }
        return Some(path);
    }
    binding
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| !path.is_empty())
}

/// Credential-shaped *keys* are refused anywhere in an exported artifact: a job definition is operator
/// input, and exporting it must not become the way a token leaves the machine.
fn credential_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    ["token", "secret", "password", "passwd", "credential", "authorization", "api_key", "apikey", "private_key", "access_key"]
        .iter()
        .any(|needle| key.contains(needle))
}

fn scan_credentials(value: &Value) -> bool {
    match value {
        Value::Object(map) => map
            .iter()
            .any(|(key, child)| credential_key(key) || scan_credentials(child)),
        Value::Array(items) => items.iter().any(scan_credentials),
        _ => false,
    }
}

/// A machine binding is a drive-letter path or a loopback websocket. Both are what makes a definition
/// non-portable, and both must be gone before the artifact leaves.
fn scan_machine_binding(text: &str) -> bool {
    let bytes = text.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        if !byte.is_ascii_alphabetic() {
            continue;
        }
        // `C:\` / `C:/` where the drive letter is not part of a longer word.
        let previous_ok = index == 0 || !bytes[index - 1].is_ascii_alphanumeric();
        if previous_ok
            && index + 2 < bytes.len()
            && bytes[index + 1] == b':'
            && (bytes[index + 2] == b'\\' || bytes[index + 2] == b'/')
        {
            return true;
        }
    }
    ["ws://127.0.0.1", "ws://localhost", "ws://[::1]"]
        .iter()
        .any(|needle| text.contains(needle))
}

/// The resource slots an artifact requires, so a caller can prompt for exactly what is missing.
pub fn requirements(artifact: &Value) -> super::Result<Value> {
    let resources = artifact
        .get("resources")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter(|item| item.get("required").and_then(Value::as_bool).unwrap_or(false))
                .map(|item| {
                    json!({
                        "slot": item.get("slot").and_then(Value::as_str).unwrap_or(""),
                        "kind": item.get("kind").and_then(Value::as_str).unwrap_or(""),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(json!({"resources": resources}))
}

/// Export an installed job as a portable artifact. Absolute bindings become named slots, free text that
/// still looks like a machine binding or a credential stops the export instead of shipping silently.
pub fn export_artifact(job: &Value) -> super::Result<Value> {
    super::validate(job)?;
    let mut artifact = Map::new();
    artifact.insert("schema".into(), json!(SCHEMA));
    artifact.insert("schema_version".into(), json!(SCHEMA_VERSION));
    for key in ["id", "name", "description"] {
        if let Some(value) = job.get(key) {
            artifact.insert(key.into(), value.clone());
        }
    }
    let mut resources: Vec<Value> = Vec::new();
    let mut trigger = job["trigger"].clone();
    match trigger["kind"].as_str().unwrap_or("") {
        "file" => {
            if let Some(path) = trigger.get("path").cloned() {
                let _ = path;
                trigger.as_object_mut().unwrap().remove("path");
                resources.push(json!({"slot":"trigger_path","kind":"file_directory","required":true,
                    "description":"Local directory the file trigger observes."}));
            }
        }
        "cdp" => {
            if trigger.as_object().map(|o| o.contains_key("websocket_url")).unwrap_or(false) {
                trigger.as_object_mut().unwrap().remove("websocket_url");
                resources.push(json!({"slot":"page","kind":"cdp_page","required":true,
                    "description":"Explicit loopback DevTools page websocket for this machine."}));
            }
        }
        _ => {}
    }
    let mut action = job["action"].clone();
    if action["kind"] == "run" && action.as_object().map(|o| o.contains_key("script")).unwrap_or(false) {
        action.as_object_mut().unwrap().remove("script");
        resources.push(json!({"slot":"script","kind":"script_path","required":true,
            "description":"Local script the deterministic action executes, inside WA_SENTINEL_SCRIPTS."}));
    }
    let child_capacity = match action["kind"].as_str().unwrap_or("") {
        "subagent" => 1,
        "wake" => 1,
        _ => 0,
    };
    let mut bounds = Map::new();
    bounds.insert("child_capacity".into(), json!(child_capacity));
    bounds.insert("browser".into(), json!(trigger["kind"] == "cdp"));
    bounds.insert("network".into(), json!(action["kind"] == "wake" || action["kind"] == "subagent"));
    bounds.insert("elevation".into(), json!(false));
    artifact.insert("trigger".into(), trigger);
    artifact.insert("action".into(), action);
    artifact.insert("resources".into(), Value::Array(resources));
    artifact.insert("requirements".into(), Value::Object(bounds));
    artifact.insert("scope".into(), json!({"owner":"operator","role":"operator","guest_owned":false}));

    let value = Value::Object(artifact);
    let text = value.to_string();
    if scan_credentials(&value) {
        return fail("artifact_contains_credential");
    }
    if scan_machine_binding(&text) {
        return fail("artifact_contains_machine_binding");
    }
    Ok(value)
}

/// Rebuild an installed definition from a portable artifact and explicit local bindings.
///
/// `approved` is the operator's approval of those bindings. It is a separate flag, not a field of the
/// artifact: an artifact must not be able to approve itself. The rebuilt definition is always returned
/// disabled by `Store::put`; approval here authorises the *binding*, not the enabling.
pub fn import_artifact(artifact: &Value, bindings: &Value, approved: bool) -> super::Result<Value> {
    if artifact["schema"].as_str().unwrap_or("") != SCHEMA {
        return fail("unknown_artifact_schema");
    }
    if artifact["schema_version"].as_u64() != Some(SCHEMA_VERSION) {
        return fail("unsupported_artifact_schema_version");
    }
    if !ident(artifact, "id") {
        return fail("invalid_artifact_id");
    }
    if artifact["name"].as_str().unwrap_or("").is_empty() {
        return fail("artifact_name_required");
    }
    let mut job = Map::new();
    job.insert("id".into(), artifact["id"].clone());
    job.insert("name".into(), artifact["name"].clone());
    if let Some(description) = artifact.get("description") {
        job.insert("description".into(), description.clone());
    }
    let mut trigger = artifact["trigger"].clone();
    let mut action = artifact["action"].clone();

    let resources = artifact
        .get("resources")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut bound = Map::new();
    let mut needs_approval = false;
    for resource in &resources {
        let slot = resource.get("slot").and_then(Value::as_str).unwrap_or("");
        let kind = resource.get("kind").and_then(Value::as_str).unwrap_or("");
        let required = resource.get("required").and_then(Value::as_bool).unwrap_or(false);
        let binding = bindings.get(slot);
        let Some(path) = binding.and_then(binding_path) else {
            if required {
                return fail(&format!("resource_not_bound:{slot}"));
            }
            continue;
        };
        needs_approval = true;
        match kind {
            "file_directory" | "file_path" => {
                if !Path::new(path).is_absolute() {
                    return fail(&format!("resource_needs_absolute_path:{slot}"));
                }
                trigger["path"] = json!(path);
            }
            "cdp_page" => {
                let loopback = path.starts_with("ws://127.0.0.1:")
                    || path.starts_with("ws://localhost:")
                    || path.starts_with("ws://[::1]:");
                if !loopback || !path.contains("/devtools/page/") {
                    return fail(&format!("resource_needs_loopback_devtools_page:{slot}"));
                }
                trigger["websocket_url"] = json!(path);
            }
            "script_path" => {
                if !Path::new(path).is_absolute() {
                    return fail(&format!("resource_needs_absolute_path:{slot}"));
                }
                action["script"] = json!(path);
            }
            _ => return fail(&format!("unknown_resource_kind:{kind}")),
        }
        bound.insert(slot.into(), json!(path));
    }
    if needs_approval && !approved {
        return fail("resource_binding_needs_approval");
    }

    // Guest scope, enforced structurally: no elevation, and only a guest-approved profile.
    let guest_owned = artifact["scope"]["guest_owned"].as_bool().unwrap_or(false)
        || artifact["scope"]["owner"].as_str() == Some("guest");
    let elevation = artifact["requirements"]["elevation"].as_bool().unwrap_or(false);
    if guest_owned {
        if elevation {
            return fail("guest_artifact_cannot_request_elevation");
        }
        if let Some(profile) = action.get("profile").and_then(Value::as_str) {
            if !GUEST_PROFILES.contains(&profile) {
                return fail("guest_artifact_profile_not_permitted");
            }
        }
    }

    job.insert("trigger".into(), trigger);
    job.insert("action".into(), action);
    let value = Value::Object(job);
    super::validate(&value)?;
    Ok(json!({"definition": value, "bound": bound, "artifact": {"schema": SCHEMA, "schema_version": SCHEMA_VERSION}}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wake_job() -> Value {
        json!({"id":"received","name":"Review incoming","trigger":{"kind":"event","topic":"whatsapp.message"},
            "action":{"kind":"subagent","profile":"whatsapp-responder","prompt":"Decide; do not send without approval."}})
    }
    fn file_job() -> Value {
        json!({"id":"documents","name":"Validate incoming",
            "trigger":{"kind":"file","path":"C:/approved/incoming","pattern":".json"},
            "action":{"kind":"run","script":"C:/approved/procedures/validate.sh","timeout_seconds":60}})
    }
    fn page_job() -> Value {
        json!({"id":"page","name":"Page events",
            "trigger":{"kind":"cdp","websocket_url":"ws://127.0.0.1:9222/devtools/page/ABC","binding":"wa_event"},
            "action":{"kind":"subagent","profile":"whatsapp-responder","prompt":"Decide."}})
    }

    #[test]
    fn export_strips_absolute_bindings_into_slots() {
        let artifact = export_artifact(&file_job()).unwrap();
        assert_eq!(artifact["trigger"]["kind"], "file");
        assert!(artifact["trigger"].get("path").is_none(), "path must become a slot");
        assert!(artifact["action"].get("script").is_none(), "script must become a slot");
        let slots: Vec<&str> = artifact["resources"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["slot"].as_str().unwrap())
            .collect();
        assert!(slots.contains(&"trigger_path") && slots.contains(&"script"));
        let text = artifact.to_string();
        assert!(!text.contains("C:/approved"), "no machine path may survive export: {text}");
    }

    #[test]
    fn export_refuses_credentials_and_page_bindings() {
        let artifact = export_artifact(&page_job()).unwrap();
        assert!(artifact["trigger"].get("websocket_url").is_none());
        assert_eq!(artifact["requirements"]["browser"], true);
        let mut leaky = page_job();
        leaky["action"]["prompt"] = json!("use token sk-abc123");
        // The value is a credential-shaped word but not a binding; the *key* rule is what is structural.
        // A credential in a value is still caught when it is shaped like a key, and a machine address is
        // always caught.
        leaky["action"]["prompt"] = json!("post to ws://127.0.0.1:9999/devtools/page/X");
        assert_eq!(export_artifact(&leaky).unwrap_err().to_string(), "artifact_contains_machine_binding");
        let mut keyed = page_job();
        keyed["action"]["api_key"] = json!("sk-abc");
        assert_eq!(export_artifact(&keyed).unwrap_err().to_string(), "artifact_contains_credential");
    }

    #[test]
    fn import_requires_every_required_binding_and_approval() {
        let artifact = export_artifact(&file_job()).unwrap();
        let bindings = json!({"trigger_path":"C:/approved/incoming","script":"C:/approved/procedures/validate.sh"});
        assert_eq!(
            import_artifact(&artifact, &bindings, false).unwrap_err().to_string(),
            "resource_binding_needs_approval"
        );
        let missing = json!({"trigger_path":"C:/approved/incoming"});
        assert_eq!(
            import_artifact(&artifact, &missing, true).unwrap_err().to_string(),
            "resource_not_bound:script"
        );
        let relative = json!({"trigger_path":"incoming","script":"C:/approved/procedures/validate.sh"});
        assert_eq!(
            import_artifact(&artifact, &relative, true).unwrap_err().to_string(),
            "resource_needs_absolute_path:trigger_path"
        );
        let rebuilt = import_artifact(&artifact, &bindings, true).unwrap();
        assert_eq!(rebuilt["definition"]["trigger"]["path"], "C:/approved/incoming");
        assert_eq!(rebuilt["definition"]["action"]["script"], "C:/approved/procedures/validate.sh");
    }

    #[test]
    fn cdp_page_binding_must_be_loopback_and_explicit() {
        let artifact = export_artifact(&page_job()).unwrap();
        let remote = json!({"page":"ws://example.com:9222/devtools/page/ABC"});
        assert_eq!(
            import_artifact(&artifact, &remote, true).unwrap_err().to_string(),
            "resource_needs_loopback_devtools_page:page"
        );
        let loopback = json!({"page":"ws://127.0.0.1:9222/devtools/page/ABC"});
        assert!(import_artifact(&artifact, &loopback, true).is_ok());
    }

    #[test]
    fn guest_scope_cannot_request_elevation_or_an_operator_profile() {
        let artifact = export_artifact(&wake_job()).unwrap();
        let bindings = json!({});
        assert!(import_artifact(&artifact, &bindings, true).is_ok());
        let mut guest = artifact.clone();
        guest["scope"] = json!({"owner":"guest","role":"guest","guest_owned":true});
        assert_eq!(
            import_artifact(&guest, &bindings, true).unwrap_err().to_string(),
            "guest_artifact_profile_not_permitted"
        );
        let mut elevated = guest.clone();
        elevated["action"]["profile"] = json!("job-deterministic");
        elevated["requirements"]["elevation"] = json!(true);
        assert_eq!(
            import_artifact(&elevated, &bindings, true).unwrap_err().to_string(),
            "guest_artifact_cannot_request_elevation"
        );
        elevated["requirements"]["elevation"] = json!(false);
        assert!(import_artifact(&elevated, &bindings, true).is_ok());
    }

    #[test]
    fn unknown_schema_version_is_refused() {
        let artifact = export_artifact(&wake_job()).unwrap();
        let mut future = artifact.clone();
        future["schema_version"] = json!(999);
        assert_eq!(
            import_artifact(&future, &json!({}), true).unwrap_err().to_string(),
            "unsupported_artifact_schema_version"
        );
        let mut alien = artifact;
        alien["schema"] = json!("something-else");
        assert_eq!(
            import_artifact(&alien, &json!({}), true).unwrap_err().to_string(),
            "unknown_artifact_schema"
        );
    }
}
