//! The resolver's own tests: the rule, the reasons, the live file and the pin check.
//!
//! They need no node, no component and no wasm toolchain: `resolve` is pure (env text, parsed policy,
//! what the directory says), and the live half is a [`PolicyView`] over a temp file. That is
//! deliberate - the thing this crate exists to make impossible is "a feature that silently fell back",
//! and the only way to be sure of it is to test the rule where nothing else can be blamed for the
//! answer.

use super::*;
use std::io::Write;

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("wa-features-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    dir
}

/// A components directory holding one component whose pin is its own bytes.
fn components_with(name: &str, bytes: &[u8]) -> PathBuf {
    let dir = temp_dir(&format!("components-{name}"));
    std::fs::write(dir.join(format!("{name}.wasm")), bytes).expect("component");
    let sha = hex(ring::digest::digest(&ring::digest::SHA256, bytes).as_ref());
    std::fs::write(dir.join(format!("{name}.wasm.sha256")), format!("{sha}\n")).expect("pin");
    std::fs::write(dir.join(format!("{name}.json")), "{}").expect("manifest");
    dir
}

fn empty_policy() -> PolicyFeatures {
    PolicyFeatures::default()
}

fn policy_with(pairs: &[(&str, Value)]) -> PolicyFeatures {
    let mut values = Map::new();
    for (key, value) in pairs {
        values.insert((*key).to_string(), value.clone());
    }
    PolicyFeatures { values, error: None }
}

#[test]
fn every_feature_is_declared_once_and_names_a_component_an_env_and_a_native_path() {
    let mut ids = Vec::new();
    for spec in FEATURES {
        assert!(!spec.id.is_empty() && !spec.component.is_empty());
        assert!(spec.env.starts_with("WA_"), "{} env {}", spec.id, spec.env);
        assert!(!spec.native.is_empty());
        assert!(!spec.summary.is_empty());
        assert!(!ids.contains(&spec.id), "duplicate feature id {}", spec.id);
        ids.push(spec.id);
    }
    // The eight features of docs/FEATURES.md, and no others: adding one is a documented edit, not an
    // accident of a table growing.
    assert_eq!(
        ids,
        vec![
            "selfloop",
            "codemode",
            "hooks",
            "memory",
            "gateway",
            "mesh_component",
            "agent_core",
            "telemetry_sink"
        ]
    );
    assert!(spec("nope").is_none());
}

#[test]
fn nothing_turns_a_feature_on_by_accident() {
    let spec = spec("memory").expect("memory");
    let status = resolve(spec, None, &empty_policy(), &Installed::Verified("abc".into()));
    assert!(!status.enabled, "default is off");
    assert_eq!(status.source, Source::Default);
    assert_eq!(status.active, ActivePath::Native, "installed is not enabled");
    assert_eq!(status.reason, REASON_DEFAULT_OFF);
    assert_eq!(status.to_json()["installed"], Value::String("abc".into()));
    assert_eq!(status.to_json()["source"], Value::String("default".into()));
}

#[test]
fn policy_turns_it_on_and_a_verified_component_makes_it_the_active_path() {
    let spec = spec("selfloop").expect("selfloop");
    let policy = policy_with(&[("selfloop", Value::Bool(true))]);
    let status = resolve(spec, None, &policy, &Installed::Verified("deadbeef".into()));
    assert!(status.enabled);
    assert_eq!(status.source, Source::Policy);
    assert_eq!(status.active, ActivePath::Component);
    assert_eq!(status.reason, REASON_COMPONENT);
    assert_eq!(status.to_json()["active"], Value::String("component".into()));
}

#[test]
fn a_feature_on_without_its_component_says_component_missing_and_runs_native() {
    let spec = spec("codemode").expect("codemode");
    let policy = policy_with(&[("codemode", Value::Bool(true))]);
    let status = resolve(spec, None, &policy, &Installed::Missing);
    assert!(status.enabled, "the operator asked for it: that part is not undone");
    assert_eq!(status.active, ActivePath::Native);
    assert_eq!(status.reason, REASON_COMPONENT_MISSING);
    assert_eq!(status.to_json()["installed"], Value::Null);
}

#[test]
fn a_component_whose_bytes_are_not_its_pin_is_not_installed() {
    let spec = spec("hooks").expect("hooks");
    let policy = policy_with(&[("hooks", Value::Bool(true))]);
    let status =
        resolve(spec, None, &policy, &Installed::PinMismatch("component_hash_mismatch:pinned=x".into()));
    assert_eq!(status.active, ActivePath::Native);
    assert!(status.reason.starts_with(REASON_PIN_MISMATCH), "{}", status.reason);
}

#[test]
fn the_environment_overrides_the_policy_in_both_directions() {
    let spec = spec("memory").expect("memory");
    let verified = Installed::Verified("abc".into());
    // on, though the policy says off
    let status = resolve(spec, Some("1"), &policy_with(&[("memory", Value::Bool(false))]), &verified);
    assert!(status.enabled);
    assert_eq!(status.source, Source::Env);
    assert_eq!(status.active, ActivePath::Component);
    // off, though the policy says on
    let status = resolve(spec, Some("0"), &policy_with(&[("memory", Value::Bool(true))]), &verified);
    assert!(!status.enabled);
    assert_eq!(status.source, Source::Env);
    assert_eq!(status.active, ActivePath::Native);
    assert_eq!(status.reason, REASON_OFF);
    // the spellings an operator writes
    for on in ["true", "ON", "yes", " 1 "] {
        assert!(resolve(spec, Some(on), &empty_policy(), &verified).enabled, "{on}");
    }
}

#[test]
fn an_unusable_env_value_is_refused_by_name_not_read_as_on_or_fallen_through() {
    let spec = spec("memory").expect("memory");
    let policy = policy_with(&[("memory", Value::Bool(true))]);
    let status = resolve(spec, Some("y"), &policy, &Installed::Verified("abc".into()));
    assert!(!status.enabled, "a typo must not start a component");
    assert_eq!(status.source, Source::Env);
    assert_eq!(status.reason, REASON_ENV_INVALID);
    assert_eq!(status.active, ActivePath::Native, "and it must not quietly read the policy either");
}

#[test]
fn a_policy_value_that_is_not_a_boolean_is_reported() {
    let spec = spec("gateway").expect("gateway");
    let policy = policy_with(&[("gateway", Value::String("yes".into()))]);
    let status = resolve(spec, None, &policy, &Installed::Verified("abc".into()));
    assert!(!status.enabled);
    assert_eq!(status.source, Source::Policy);
    assert!(status.reason.starts_with(REASON_VALUE_INVALID), "{}", status.reason);
}

#[test]
fn the_policy_section_is_parsed_and_a_broken_one_is_visible() {
    let parsed = parse_features(br#"{"version":1,"features":{"memory":true,"hooks":false}}"#);
    assert_eq!(parsed.get("memory"), Ok(Some(true)));
    assert_eq!(parsed.get("hooks"), Ok(Some(false)));
    assert_eq!(parsed.get("selfloop"), Ok(None));

    // No section at all: every feature keeps its default, and that is not an error.
    let absent = parse_features(br#"{"version":1,"components":{}}"#);
    assert_eq!(absent, PolicyFeatures::default());
    assert_eq!(absent.error, None);

    // A section that is not an object, and a file that does not parse: both are errors, and a feature
    // resolved against them says so instead of pretending the default was a decision.
    let wrong = parse_features(br#"{"features":["memory"]}"#);
    assert!(wrong.error.as_deref().unwrap_or_default().starts_with("not_an_object"));
    let status = resolve(spec("memory").unwrap(), None, &wrong, &Installed::Verified("abc".into()));
    assert!(status.reason.starts_with(REASON_POLICY_UNREADABLE), "{}", status.reason);
    let broken = parse_features(b"{oops");
    assert!(broken.error.as_deref().unwrap_or_default().starts_with("json:"));
}

#[test]
fn the_shipped_default_names_every_feature_and_turns_every_one_off() {
    // The file a deploy installs (`policies/default.json`): a missing feature is a silent default, so
    // the shipped file must name all of them - and `installed` is not `enabled` (docs/FEATURES.md).
    let default: Value = serde_json::from_str(include_str!("../../../policies/default.json"))
        .expect("policies/default.json parses");
    let features = default.get("features").and_then(Value::as_object).expect("a features section");
    for spec in FEATURES {
        assert_eq!(
            features.get(spec.id),
            Some(&Value::Bool(false)),
            "policies/default.json must ship {} as false",
            spec.id
        );
    }
    assert_eq!(features.len(), FEATURES.len(), "no feature in the default that this crate does not know");
}

#[test]
fn the_live_view_switches_a_feature_without_a_restart() {
    // What a policy.json edit does to a running node: the same view, a newer file.
    let dir = temp_dir("live");
    let file = dir.join("policy.json");
    let write = |features: &str| {
        let mut handle = std::fs::File::create(&file).expect("policy file");
        handle
            .write_all(format!(r#"{{"version":1,"features":{features}}}"#).as_bytes())
            .expect("write");
    };
    write(r#"{"hooks":false}"#);
    let mut view = PolicyView::new(&file);
    assert_eq!(view.features().get("hooks"), Ok(Some(false)));
    // A refresh inside the watch interval is a stat, and the answer is the same one.
    assert!(!view.refresh_at(now_ms(), false) || view.features().get("hooks") == Ok(Some(false)));

    write(r#"{"hooks":true}"#);
    // The mtime may be the same millisecond on a fast filesystem; `force` is what a caller asks for
    // when it knows the file moved (the gate uses the watch interval, which is time, not mtime).
    assert!(view.refresh_at(now_ms(), true));
    assert_eq!(view.features().get("hooks"), Ok(Some(true)));
    let verified = Installed::Verified("abc".into());
    let status = resolve(spec("hooks").unwrap(), None, view.features(), &verified);
    assert_eq!(status.active, ActivePath::Component, "the same process now routes to the component");

    // Deleting the file is not an error: every feature is back to its default.
    std::fs::remove_file(&file).expect("remove");
    view.refresh_at(now_ms(), true);
    assert_eq!(view.features(), &PolicyFeatures::default());
}

#[test]
fn a_pin_that_does_not_match_the_bytes_is_a_mismatch_not_an_install() {
    let dir = components_with("memory", b"component-bytes");
    assert!(matches!(installed_in(&dir, "memory"), Installed::Verified(_)));
    assert_eq!(installed_in(&dir, "selfloop"), Installed::Missing);

    std::fs::write(dir.join("memory.wasm"), b"swapped-bytes").expect("swap");
    assert!(matches!(installed_in(&dir, "memory"), Installed::PinMismatch(_)));

    // A module with no pin is refused by name, exactly as the kernel refuses it.
    std::fs::write(dir.join("selfloop.wasm"), b"x").expect("unpinned");
    assert_eq!(installed_in(&dir, "selfloop"), Installed::PinMismatch("component_pin_missing".into()));
}

#[test]
fn the_wire_document_carries_the_policy_file_and_its_error() {
    let dir = temp_dir("wire");
    let file = dir.join("policy.json");
    std::fs::write(&file, r#"{"features":42}"#).expect("policy");
    let list = FEATURES
        .iter()
        .map(|spec| resolve(spec, None, &parse_features(br#"{"features":42}"#), &Installed::Missing))
        .collect::<Vec<_>>();
    let text = status_json(&list, &file);
    let document: Value = serde_json::from_str(&text).expect("json");
    assert_eq!(document["ok"], Value::Bool(true));
    assert_eq!(document["features"].as_array().map(Vec::len), Some(FEATURES.len()));
    assert_eq!(document["features"][0]["feature"], Value::String("selfloop".into()));
    assert_eq!(document["features"][0]["active"], Value::String("native".into()));
    assert!(
        document["policy_error"].as_str().unwrap_or_default().starts_with("not_an_object"),
        "{text}"
    );
}

#[test]
fn an_unknown_feature_is_an_error_not_an_off() {
    let answer: Value = serde_json::from_str(&feature_json("nope")).expect("json");
    assert_eq!(answer["ok"], Value::Bool(false));
    assert_eq!(answer["error"], Value::String("unknown_feature:nope".into()));
}
