// The feature-health renderer's rules (`wa health`): the same six verdicts the Lua module uses, the same
// bound taken from the row, and a registry that cannot be read named instead of answered as "no features".
use super::feature_health::*;
use serde_json::json;

fn scratch(label: &str) -> std::path::PathBuf {
    let id = std::process::id();
    let dir = std::env::temp_dir().join(format!("wa-feature-health-{label}-{id}"));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join(".wasm-agent")).expect("scratch state root");
    dir
}

fn write_registry(home: &std::path::Path, text: &str) {
    std::fs::write(home.join(".wasm-agent/features.json"), text).expect("registry written");
}

/// Three dates that would catch a wrong epoch base or a wrong civil conversion.
#[test]
fn an_iso_time_is_utc_and_whole() {
    assert_eq!(iso_utc(0), "1970-01-01T00:00:00Z");
    assert_eq!(iso_utc(1_700_000_000), "2023-11-14T22:13:20Z");
    assert_eq!(iso_utc(1_735_689_599), "2024-12-31T23:59:59Z");
}

#[test]
fn the_five_verdicts_are_the_lua_ones() {
    let entry = json!({"last_ok_at": 1000});
    assert_eq!(verdict(60, Some(&entry), 1060).0, Verdict::Working, "exactly at the bound is inside it");
    assert_eq!(verdict(60, Some(&entry), 1061).0, Verdict::Stale, "one second past the bound is stale");
    assert_eq!(verdict(60, None, 1061).0, Verdict::Never, "nothing recorded is never");
    let failed = json!({"last_ok_at": 1000, "last_fail_at": 1030, "last_fail_stage": "post"});
    let (failed_verdict, detail) = verdict(60, Some(&failed), 1040);
    assert_eq!(failed_verdict, Verdict::Failing);
    assert!(detail.contains("stage post"), "the stage is named: {detail}");
    let recovered = json!({"last_ok_at": 1030, "last_fail_at": 1020, "last_fail_stage": "post"});
    assert_eq!(verdict(60, Some(&recovered), 1040).0, Verdict::Working, "a later success puts it back");
    let only_failed = json!({"last_fail_at": 1030, "last_fail_stage": "lease"});
    assert_eq!(verdict(60, Some(&only_failed), 1040).0, Verdict::Failing, "a feature that only failed is failing");
}

#[test]
fn a_row_says_when_it_last_worked_and_a_componentless_role_is_off_node() {
    let home = scratch("rows");
    write_registry(&home, &json!({"schema": 1, "features": [
        {"name": "chat", "role": "any", "canary": "chat", "last_success": "x", "stale_after_s": 3600},
        {"name": "mail", "role": "component:wa-email", "canary": "mail", "last_success": "x", "stale_after_s": 3600}
    ]}).to_string());
    std::fs::write(home.join(".wasm-agent/feature-health.json"),
        json!({"schema": 1, "features": {"chat": {"last_ok_at": 1_700_000_000}}}).to_string()).unwrap();
    let rows = rows(&config_dir_for(&home), 1_700_000_100).expect("the rows answer");
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].verdict, Verdict::Working);
    assert_eq!(rows[1].verdict, Verdict::OffNode, "a component this node does not have is off-node, not failing");
    let lines = lines(&config_dir_for(&home), 1_700_000_100);
    assert!(lines[0].contains("2 listed"), "the summary counts the list: {}", lines[0]);
    assert!(lines[1].contains("last worked: 2023-11-14T22:13:20Z"), "each row names the time: {}", lines[1]);
    // A CANARY'S TIME SAYS SO: a synthetic pass must not read as a user's use (Fable's review, item 4).
    std::fs::write(home.join(".wasm-agent/feature-health.json"),
        json!({"schema": 1, "features": {"chat": {"last_ok_at": 1_700_000_000, "last_ok_source": "canary"}}}).to_string()).unwrap();
    let with_canary = super::feature_health::lines(&config_dir_for(&home), 1_700_000_100);
    assert!(with_canary[1].contains("last worked: 2023-11-14T22:13:20Z  [canary]"), "a canary-sourced time is labelled: {}", with_canary[1]);
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_missing_registry_is_named_not_answered_as_no_features() {
    let home = scratch("missing");
    let lines = lines(&config_dir_for(&home), 0);
    assert_eq!(lines.len(), 1);
    assert!(lines[0].starts_with("features:  unreadable - "), "the missing registry is named: {}", lines[0]);
    assert!(lines[0].contains("features.json"), "and so is the file it looked for: {}", lines[0]);
    let _ = std::fs::remove_dir_all(&home);
}

/// A ROW THAT DEFAULTS OFF IS DORMANT, NOT NEVER (docs/GRAPH.md, 23/11): with nothing recorded and the
/// switch off there is nothing broken to report, and the moment the node's own policy file says true the
/// row goes back to its ordinary verdict - so switching it on can never be hidden by the word dormant.
#[test]
fn a_row_that_defaults_off_is_dormant_until_the_policy_switches_it_on() {
    let home = scratch("dormant");
    write_registry(&home, &json!({"schema": 1, "features": [
        {"name": "chat", "role": "any", "canary": "chat", "last_success": "x", "stale_after_s": 3600},
        {"name": "graph", "role": "any", "canary": "graph", "default": "off", "last_success": "x", "stale_after_s": 3600}
    ]}).to_string());
    let config = config_dir_for(&home);
    let rows = super::feature_health::rows(&config, 1_700_000_100).expect("the rows answer");
    assert_eq!(rows[1].name, "graph");
    assert_eq!(rows[1].verdict, Verdict::Dormant, "off by default and nobody asked: dormant, not never");
    assert!(rows[1].detail.contains("docs/GRAPH.md"), "the detail names the document: {}", rows[1].detail);
    assert_eq!(rows[0].verdict, Verdict::Never, "the row beside it is unaffected: the word is per row");
    let lines = super::feature_health::lines(&config, 1_700_000_100);
    assert!(lines[0].contains("1 dormant"), "the summary counts it: {}", lines[0]);
    assert!(lines[0].contains("1 never"), "and chat is still counted red: {}", lines[0]);
    // The node's own policy switches it on: the ordinary verdict comes back.
    std::fs::write(config.join("policy.json"), json!({"features": {"graph": true}}).to_string()).unwrap();
    let switched_on = super::feature_health::rows(&config, 1_700_000_100).expect("the rows answer");
    assert_eq!(switched_on[1].verdict, Verdict::Never, "switched on with nothing recorded: never, and red");
    let _ = std::fs::remove_dir_all(&home);
}
