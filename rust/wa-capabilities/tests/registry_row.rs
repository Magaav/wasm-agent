//! The runtime row the world's status doc was still missing: start the REAL component, the way the node
//! starts it, ask it for its registry over the queue, and compare the document it answers with the one the
//! host declares.
//!
//! It is a test binary of its own because it sets `WASM_AGENT_HOME` and `WA_COMPONENTS_DIR` for the whole
//! process: the node resolves its component directory and its state from those, and a scratch value is the
//! only way to boot a service without touching the account this machine is linked to.

use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{Duration, Instant};

const COMPONENT: &str = "wa-whatsapp";
const QUEUE: &str = "whatsapp.query";

/// The installed component (bytes, pin, manifest) to copy from. Read only there, never written.
fn installed_source() -> PathBuf {
    if let Ok(dir) = std::env::var("WA_TEST_SERVICE_DIR") {
        return PathBuf::from(dir);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".wasm-agent").join("components")
}

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("wa-registry-row-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("components")).expect("a scratch home");
    dir
}

/// Ask the registry over the queue and wait for the COMPONENT to settle it - nothing here writes a `done`.
fn ask_the_registry() -> Value {
    let queue = wa_kernel_runtime::queue_host::node().queue(COMPONENT);
    let id = queue
        .enqueue(
            wa_queue::EnqueueRequest::new(QUEUE, br#"{"op":"ops"}"#.to_vec())
                .fresh_for(60_000)
                .max_attempts(2)
                .dedupe("registry|row")
                .dedupe_in_flight(),
        )
        .expect("the registry question must enqueue")
        .id
        .0;
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        if let Ok(Some(job)) = queue.job(wa_queue::JobId(id)) {
            match job.state.as_str() {
                "done" => {
                    return serde_json::from_slice(job.result.as_deref().unwrap_or(b"{}"))
                        .expect("the registry is a JSON document")
                }
                "dead" | "failed" => panic!(
                    "the component refused the registry: state={:?} result={:?}",
                    job.state,
                    job.result.as_deref().map(|raw| String::from_utf8_lossy(raw).into_owned())
                ),
                _ => {}
            }
        }
        assert!(Instant::now() < deadline, "the component did not answer its registry within 120 s");
        std::thread::sleep(Duration::from_millis(200));
    }
}

#[test]
fn the_started_component_answers_the_registry_the_host_declares() {
    let source = installed_source();
    let home = scratch("home");
    for extension in ["wasm", "wasm.sha256", "json"] {
        let name = format!("{COMPONENT}.{extension}");
        let from = source.join(&name);
        assert!(from.is_file(), "the component must be installed to be started: {}", from.display());
        std::fs::copy(&from, home.join("components").join(&name)).expect("copy the component");
    }
    std::env::set_var("WASM_AGENT_HOME", &home);
    std::env::set_var("WA_COMPONENTS_DIR", home.join("components"));
    std::env::set_var("WA_COMPONENT_CACHE", "0");

    let started = wa_kernel_runtime::services::start(&json!({"name": COMPONENT}));
    assert!(
        started.get("ok").and_then(Value::as_bool).unwrap_or(false),
        "the component must start the way the node starts it: {started}"
    );
    let answer = ask_the_registry();
    let _ = wa_kernel_runtime::services::stop(COMPONENT);

    // What it answered: `{"ok":true,"op":"ops","ops":[{"name":"search","effect":"read-only",...}]}` -
    // the NAME is the word on the wire (`search`), and the tool the model is offered is `whatsapp_<word>`.
    let answered: Vec<(String, String)> = answer
        .get("ops")
        .and_then(Value::as_array)
        .unwrap_or_else(|| panic!("the registry document has no ops: {answer}"))
        .iter()
        .map(|entry| {
            let name = entry.get("name").and_then(Value::as_str).expect("every op has a name").to_string();
            let effect = entry.get("effect").and_then(Value::as_str).expect("every op has an effect").to_string();
            (name, effect)
        })
        .collect();

    // 1. The component answered exactly the seam's op set, in the seam's order.
    let seam_ops: Vec<(&str, &str)> = wa_whatsapp_index::Op::ALL
        .iter()
        .map(|op| {
            let effect = match op.effect() {
                wa_whatsapp_index::Effect::ReadOnly => "read-only",
                wa_whatsapp_index::Effect::Network => "network",
                wa_whatsapp_index::Effect::WritesFiles => "writes-files",
            };
            (op.as_str(), effect)
        })
        .collect();
    let answered_refs: Vec<(&str, &str)> = answered.iter().map(|(name, effect)| (name.as_str(), effect.as_str())).collect();
    assert_eq!(
        answered_refs, seam_ops,
        "the registry the running component answers must be the seam's own op set and effect classes"
    );

    // 2. Every op it answers is a capability the host declares, under the tool name the model is offered:
    //    the question that gets asked and the pair of names the model sees have to be the same string.
    let declared: Vec<String> = wa_capabilities::capabilities::inventory()
        .iter()
        .map(|capability| capability.name.to_string())
        .collect();
    for (name, _) in &answered {
        let tool = format!("whatsapp_{name}");
        assert!(
            declared.iter().any(|declared| declared == &tool),
            "the component answers {name} and the host declares no {tool} capability"
        );
    }
}
