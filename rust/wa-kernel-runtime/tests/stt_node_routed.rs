//! The node-level routed path, in a process of its own.
//!
//! Why a separate test binary (and not a case in stt_node/tests.rs): the switch this needs,
//! WA_COMPONENTS_DIR, is process-global. Setting it inside the module's own binary made two neighbouring
//! tests fail by sharing the guest's single instance (measured 26/11); a test target is a process, so here
//! it is only this test's.
//!
//! What it proves: a configured node's call - the wire call scripts/test-stt-two-nodes.sh sends - is
//! ADMITTED BY THE GUEST when the component is installed and pinned. Nothing here is a stub: the artifact
//! named by WA_STT_COMPONENT_WASM is installed with its pin, the feature resolver is asked per call, and
//! the fallback log must stay empty - a line there means the guest was asked and could not answer, which
//! is not this test.
//!
//! SKIPPED, and said so, when no artifact is named. scripts/test-stt-seam.sh builds one and names it.
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{json, Value};
use wa_kernel_runtime::stt_node;

fn artifact() -> Option<std::path::PathBuf> {
    std::env::var("WA_STT_COMPONENT_WASM").ok().map(Into::into)
}

fn install(artifact: &std::path::Path) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("wa-stt-node-routed-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("component dir");
    let bytes = std::fs::read(artifact).expect("artifact readable");
    std::fs::write(dir.join("stt.wasm"), &bytes).expect("artifact copied");
    // The pin is the sha256 of the module: the same hash the resolver takes, from the same crate.
    let pinned: String = ring::digest::digest(&ring::digest::SHA256, &bytes)
        .as_ref()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    std::fs::write(dir.join("stt.wasm.sha256"), pinned + "\n").expect("pin written");
    dir
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

#[test]
fn a_configured_nodes_call_is_admitted_by_the_guest() {
    let Some(artifact) = artifact() else {
        eprintln!("SKIPPED: no WA_STT_COMPONENT_WASM (scripts/test-stt-seam.sh builds and names it)");
        return;
    };
    let dir = install(&artifact);
    std::env::set_var("WA_COMPONENTS_DIR", &dir);

    // The node this test is: an identity and an owner list, which is all a scratch node lacks.
    let configured = stt_node::configure(&json!({
        "me": "producer",
        "owner_nodes": ["producer", "worker"],
        "producer": false,
        "worker": false,
    }));
    assert_eq!(configured["ok"], Value::Bool(true), "the node configures: {configured}");

    let submitted = stt_node::submit(&json!({
        "audio_b64": "eA==",
        "mime": "audio/ogg",
        "language": "pt",
        "chat": "chat",
        "msg": "note-1",
        "account": "acct",
    }));
    assert!(submitted.get("refused").is_none(), "a note is enqueued: {submitted}");

    let envelope = json!({
        "v": 1,
        "op": "take",
        "from": "worker",
        "to": "producer",
        "ts_ms": now_ms(),
        "rid": "rid-node-routed-1",
        "body": {"queue": "stt.requests", "worker": "w1", "wait_ms": 0},
    })
    .to_string();
    let answer: Value = serde_json::from_str(&stt_node::call(&envelope, "worker")).expect("a reply is JSON");
    assert_eq!(answer["refused"], Value::Null, "the guest admitted the take: {answer}");
    assert!(answer["ok"].is_object(), "a take answers its body: {answer}");

    // The same rid again: the guest's ledger refuses it. The native rule would answer the same, but its
    // memory is the host's; here the memory is the component's.
    let replay: Value = serde_json::from_str(&stt_node::call(&envelope, "worker")).expect("a reply is JSON");
    assert_eq!(replay["refused"], Value::String("replayed_request".into()), "the ledger refused the replay: {replay}");

    assert!(stt_node::fallbacks().is_empty(), "the guest answered every call: {:?}", stt_node::fallbacks());
    let _ = std::fs::remove_dir_all(&dir);
}
