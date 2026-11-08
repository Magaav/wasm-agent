//! The hooks seam's own tests: the grant (the component holds none), the missing-component answer,
//! and — when the `hooks` artifact is in this checkout's target dir — the engine itself, driven
//! through the seam exactly as `lua/core/hooks.lua` drives it.
//!
//! The Lua parity suite (`scripts/test-hooks-component.lua`, run by `scripts/test-hooks-component.sh`)
//! is the one that compares both paths decision for decision; these tests are the part that must pass
//! on a machine with no `wa` binary, and they say SKIPPED out loud when the artifact is absent.
use super::*;

fn artifact() -> Option<PathBuf> {
    let candidates = [
        std::env::var("WA_HOOKS_COMPONENT_WASM").ok().filter(|value| !value.is_empty()).map(PathBuf::from),
        std::env::var("CARGO_TARGET_DIR")
            .ok()
            .filter(|value| !value.is_empty())
            .map(|dir| PathBuf::from(dir).join("wasm32-wasip2/release/hooks.wasm")),
        Some(PathBuf::from(concat!(env!("CARGO_MANIFEST_DIR"), "/../target/wasm32-wasip2/release/hooks.wasm"))),
    ];
    candidates.into_iter().flatten().find(|path| path.is_file())
}

fn config_for(path: &std::path::Path) -> Config {
    Config {
        components_dir: path.parent().unwrap_or(std::path::Path::new(".")).to_path_buf(),
        wasm: Some(path.to_path_buf()),
        manifest: None,
        timeout_ms: 10_000,
    }
}

/// The manifest is the grant: this component declares no capability at all, so nothing a mod does
/// through the engine can reach a capability through it.
#[test]
fn the_hooks_component_declares_no_capability() {
    let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../components/hooks/manifest.json"))
        .expect("the hooks manifest is in the tree");
    let manifest: Value = serde_json::from_str(&text).expect("the hooks manifest is JSON");
    assert_eq!(manifest["name"], json!("hooks"));
    let capabilities = manifest.get("capabilities").cloned().unwrap_or_else(|| json!({}));
    assert!(
        capabilities.as_object().map(|object| object.is_empty()).unwrap_or(false),
        "the hooks component must declare no capability, found {capabilities}"
    );
    // And the world it is built from imports nothing: the only interfaces it has are the ones `std`
    // brings (tier A clocks/random/stdio), which reach nothing outside the guest.
    let witness = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../wit/hooks/hooks.wit"))
        .expect("wit/hooks/hooks.wit is in the tree");
    assert!(!witness.contains("import "), "wa:hooks imports no interface");
}

#[test]
fn the_artifact_imports_nothing_it_could_act_with() {
    let Some(path) = artifact() else {
        println!("SKIPPED the_artifact_imports_nothing_it_could_act_with: no hooks.wasm artifact in this checkout");
        return;
    };
    let bytes = std::fs::read(&path).expect("the artifact is readable");
    let interfaces = crate::imports::of_bytes(&bytes).expect("the artifact's interfaces are readable");
    for import in &interfaces.imports {
        // Exporting `wa:hooks` makes the component *import* its own type package (a type used by an
        // export crosses as an import); nothing else from `wa:` may appear, and nothing from
        // `wa:kernel/` at all, because that is where a capability would come from.
        assert!(
            !import.starts_with("wa:") || import.starts_with("wa:hooks/"),
            "the hooks component imports no kernel interface, found {import}"
        );
        if import.starts_with("wasi:") || import.starts_with("wasi-") {
            let tier = crate::wasi_grants::tier_of(import);
            assert_eq!(
                tier,
                Some(crate::wasi_grants::Tier::Always),
                "a hooks guest may import only tier A WASI, found {import} ({tier:?})"
            );
        }
    }
}

#[test]
fn a_missing_component_is_a_reason_not_a_panic() {
    let dir = std::env::temp_dir().join(format!("wa-hooks-missing-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("a scratch dir");
    let config = Config { components_dir: dir.clone(), wasm: None, manifest: None, timeout_ms: 2_000 };
    let answer = call_with(&config, &json!({"op": "configure"}));
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(answer["ok"], json!(false));
    let error = answer["error"].as_str().unwrap_or_default();
    assert!(error.starts_with("component_unavailable:"), "a missing component is named, found {error}");
}

fn source(name: &str, path: &str, text: &str) -> Value {
    json!({"name": name, "path": path, "kind": "native", "text": text})
}

fn configure(config: &Config, text: &str) -> Value {
    let answer = call_with(
        config,
        &json!({
            "op": "configure",
            "workdir": "/tmp/project",
            "disabled": false,
            "claude_env_opt_in": false,
            "sources": [source("node", "/tmp/home/hooks.json", text)],
        }),
    );
    assert_eq!(answer["ok"], json!(true), "configure answered: {answer}");
    answer["result"].clone()
}

fn hook(name: &str, matcher: &str, command: &str) -> Value {
    json!({"name": name, "matcher": matcher, "command": command, "timeout_ms": 3000})
}

fn row(name: &str, event: &str, status: &str, stdout: &str, exit_code: Option<i64>) -> Value {
    let mut row = json!({
        "name": name, "event": event, "kind": "command", "origin": "node", "status": status,
        "timeout_ms": 3000, "at": 1_700_000_000_000u64, "stdout": stdout, "stderr": "",
    });
    if let Some(code) = exit_code {
        row["exit_code"] = json!(code);
    }
    row
}

/// The engine through the seam: matchers, order, a deny that stops the event, a timeout that does not,
/// a rewrite that merges over the call's arguments, and the footer's segment.
#[test]
fn the_seam_decides_like_the_native_engine() {
    let Some(path) = artifact() else {
        println!("SKIPPED the_seam_decides_like_the_native_engine: no hooks.wasm artifact in this checkout");
        return;
    };
    let config = config_for(&path);
    let text = json!({
        "hooks": {
            "PreToolUse": [
                hook("deny-bash", "bash", "/bin/deny"),
                hook("later", "bash", "/bin/later"),
                hook("read-only", "^read$", "/bin/read"),
            ],
            "PostToolUse": [hook("timeout", "bash", "/bin/slow")],
        },
        "mods": {
            "statusline": [{"name": "branch", "command": "git rev-parse --abbrev-ref HEAD"}],
            "commands": [{"name": "/hello", "description": "say hello", "command": "/bin/hello"}],
        },
    })
    .to_string();
    let facts = configure(&config, &text);
    assert_eq!(facts["disabled"], json!(false));
    assert_eq!(facts["present"], json!(true));
    assert_eq!(facts["errors"], json!([]));
    let pre = facts["hooks"]["PreToolUse"].clone();
    assert_eq!(pre.as_array().map(Vec::len), Some(3), "three PreToolUse entries: {pre}");
    assert_eq!(pre[0]["name"], json!("deny-bash"));
    assert_eq!(pre[1]["timeout_ms"], json!(3000), "a timeout stays an integer, as the native config has it");
    assert_eq!(facts["mods"]["statusline"][0]["event"], json!("StatusLine"));
    assert_eq!(facts["mods"]["commands"][0]["name"], json!("/hello"));

    // The matcher keeps the read hook out of a bash call, and the order is the file's.
    let matched = call_with(
        &config,
        &json!({"op": "entries", "event": "PreToolUse", "tool": "bash", "entries": pre}),
    );
    let matched = matched["result"].as_array().cloned().unwrap_or_default();
    assert_eq!(matched.iter().map(|entry| entry["name"].as_str().unwrap_or_default()).collect::<Vec<_>>(), vec!["deny-bash", "later"]);

    // A deny stops the event: the hook after it never runs.
    let deny = json!({"hookSpecificOutput": {"permissionDecision": "deny",
        "permissionDecisionReason": "no"}}).to_string();
    let step = call_with(
        &config,
        &json!({"op": "decide", "event": "PreToolUse", "payload": "{\"tool_name\":\"bash\"}",
                "entry": matched[0], "row": row("deny-bash", "PreToolUse", "ok", &deny, Some(0))}),
    );
    assert_eq!(step["ok"], json!(true), "{step}");
    let decision = step["result"]["decision"].clone();
    assert_eq!(decision["blocked"], json!(true));
    assert_eq!(decision["blocked_by"], json!("deny-bash"));
    assert_eq!(decision["status"], json!("denied"));
    assert_eq!(decision["reason"], json!("no"));
    assert_eq!(decision["ran"], json!(1));
    assert_eq!(step["result"]["stop"], json!(true));

    // A timeout is recorded and does not block: the turn continues per policy.
    let step = call_with(
        &config,
        &json!({"op": "decide", "event": "PostToolUse", "payload": "{}",
                "entry": {"name": "timeout", "event": "PostToolUse", "kind": "command",
                          "command": "/bin/slow", "timeout_ms": 500.0, "on_ask": "deny", "origin": "node", "order": 1},
                "row": row("timeout", "PostToolUse", "timeout", "", None)}),
    );
    let decision = step["result"]["decision"].clone();
    assert_eq!(decision["blocked"], json!(false));
    assert_eq!(step["result"]["stop"], json!(false));
    assert_eq!(decision["errors"][0]["error"], json!("timeout"));

    // updatedInput is merged over the call's arguments, and the payload a later hook sees carries it.
    let rewrite = json!({"hookSpecificOutput": {"updatedInput": {"path": "README.md"}}}).to_string();
    let step = call_with(
        &config,
        &json!({"op": "decide", "event": "PreToolUse",
                "payload": "{\"tool_name\":\"read\",\"tool_input\":{\"path\":\"notes.md\",\"limit\":5}}",
                "entry": matched[0], "row": row("deny-bash", "PreToolUse", "ok", &rewrite, Some(0))}),
    );
    let decision = step["result"]["decision"].clone();
    assert_eq!(decision["updated_input"]["path"], json!("README.md"));
    assert_eq!(decision["input_changes"]["path"], json!("README.md"));
    let payload: Value = serde_json::from_str(step["result"]["payload"].as_str().unwrap_or("{}")).expect("payload");
    assert_eq!(payload["tool_input"]["path"], json!("README.md"));
    assert_eq!(payload["tool_input"]["limit"], json!(5), "the merge keeps the other arguments");

    // The footer: one segment per statusline row, a broken mod named instead of one fact fewer.
    let segment = call_with(
        &config,
        &json!({"op": "segment",
                "entries": facts["mods"]["statusline"],
                "rows": [row("branch", "StatusLine", "ok", "main", Some(0))]}),
    );
    assert_eq!(segment["result"], json!("main"));
    let segment = call_with(
        &config,
        &json!({"op": "segment", "entries": facts["mods"]["statusline"],
                "rows": [row("branch", "StatusLine", "error", "", Some(7))]}),
    );
    assert_eq!(segment["result"], json!("!branch"));
}

/// Ten hooks on one event, in the file's order, with only the last denying: every row is interpreted
/// (the crossing count the bench reports is this loop's), and the deny is the one that stops it.
#[test]
fn ten_hooks_run_in_order_until_one_denies() {
    let Some(path) = artifact() else {
        println!("SKIPPED ten_hooks_run_in_order_until_one_denies: no hooks.wasm artifact in this checkout");
        return;
    };
    let config = config_for(&path);
    let entries: Vec<Value> = (0..10).map(|index| hook(&format!("h{index}"), "bash", "/bin/hook")).collect();
    let text = json!({"hooks": {"PreToolUse": entries}}).to_string();
    let facts = configure(&config, &text);
    let pre = facts["hooks"]["PreToolUse"].as_array().cloned().unwrap_or_default();
    assert_eq!(pre.len(), 10);
    let mut prior: Option<Value> = None;
    let mut ran = 0;
    for (index, entry) in pre.iter().enumerate() {
        let last = index == 9;
        let stdout = if last {
            json!({"hookSpecificOutput": {"permissionDecision": "deny"}}).to_string()
        } else {
            String::new()
        };
        let row = row(&format!("h{index}"), "PreToolUse", "ok", &stdout, Some(0));
        let mut request = json!({"op": "decide", "event": "PreToolUse", "payload": "{}", "entry": entry, "row": row});
        if let Some(prior) = &prior {
            request["prior"] = prior.clone();
        }
        let step = call_with(&config, &request);
        assert_eq!(step["ok"], json!(true), "{step}");
        prior = Some(step["result"]["decision"].clone());
        ran += 1;
        if last {
            assert_eq!(step["result"]["stop"], json!(true));
        } else {
            assert_eq!(step["result"]["stop"], json!(false));
        }
    }
    let decision = prior.expect("a verdict");
    assert_eq!(decision["ran"], json!(ran));
    assert_eq!(decision["outcomes"].as_array().map(Vec::len), Some(10));
    assert_eq!(decision["blocked_by"], json!("h9"));
}
