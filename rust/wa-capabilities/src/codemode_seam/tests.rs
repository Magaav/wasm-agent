//! The code-mode seam end to end: the *built* component, over the `wa:kernel/quickjs` import, with the
//! sandbox answered by the benchmark's scripted peer.
//!
//! Why the peer and not QuickJS: the pinned assets (`quickjs.wasm`, `prelude.js`) are provisioned, not
//! vendored, and a checkout that has not been provisioned cannot run a script at all — the native path
//! refuses before its first call in exactly the same way. The peer emits the same *events* for these
//! scripts, so what is under test here is the seam (the fence, the ordering, the discovery answers, the
//! report), not the VM. `scripts/bench-codemode.sh` says the same thing about its numbers, and
//! `scripts/test-codemode-component.lua` is the suite that runs when the assets are there.
//!
//! The artifact is found by [`artifact()`] and SKIPPED — printed, and reported in REPORT.md — when this
//! checkout has not built the component. A skip is never counted as a pass.
use super::*;

fn temp_dir(tag: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "wa-codemode-seam-{}-{}-{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
    ));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).expect("temp dir");
    base
}

/// The built component, wherever this checkout put it. `WA_CODEMODE_COMPONENT_WASM` wins (the Lua parity
/// test passes it), then the workspace target dir, then an in-tree build.
fn artifact() -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(path) = std::env::var("WA_CODEMODE_COMPONENT_WASM") {
        candidates.push(PathBuf::from(path));
    }
    if let Ok(target) = std::env::var("CARGO_TARGET_DIR") {
        candidates.push(PathBuf::from(target).join("wasm32-wasip2/release/codemode.wasm"));
    }
    candidates.push(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../components/codemode/target/wasm32-wasip2/release/codemode.wasm"));
    let found = candidates.into_iter().find(|path| path.is_file());
    if found.is_none() {
        eprintln!("SKIPPED: no codemode.wasm built (bash scripts/build-components.sh codemode)");
    }
    found
}

/// The seam's configuration for these tests: this checkout's artifact, the scripted sandbox peer, and a
/// components directory that does not exist (nothing pinned is involved).
fn config() -> Option<Config> {
    let mut config = Config::from_env().with_components(temp_dir("components")).with_sandbox(Sandbox::Stub).with_timeout(5_000);
    config.wasm = Some(artifact()?);
    Some(config)
}

struct Seam {
    config: Config,
}

impl Seam {
    fn open(&self, session: &str, code: &str) -> Value {
        call_with(
            &self.config,
            &json!({
                "op": "open",
                "session": session,
                "owner": "0".repeat(64),
                "code": code,
                "timeout_ms": 30_000,
                "catalogue": catalogue(),
                "store": {"remembered": "1"},
                "module_cache": "",
            }),
        )
    }

    fn advance(&self, session: &str, reply: Option<Value>) -> Value {
        let mut request = json!({"op": "advance", "session": session});
        if let Some(reply) = reply {
            request["reply"] = reply;
        }
        call_with(&self.config, &request)
    }

    fn finish(&self, session: &str) -> Value {
        call_with(&self.config, &json!({"op": "finish", "session": session}))
    }

    /// The whole loop, the way `lua/core/codemode.lua` drives it: open, step, answer, repeat.
    fn run(&self, session: &str, code: &str) -> (Value, Vec<Value>) {
        let mut steps = Vec::new();
        let opened = self.open(session, code);
        assert_eq!(opened["ok"], true, "open: {opened}");
        if !opened["sandbox_failure"].is_null() {
            return (opened, steps);
        }
        let mut reply: Option<Value> = None;
        loop {
            let progress = self.advance(session, reply.take());
            assert_eq!(progress["ok"], true, "advance: {progress}");
            let step = progress["step"].clone();
            steps.push(step.clone());
            match step["kind"].as_str().unwrap_or_default() {
                "call" => {
                    let payload = if step["name"] == "read" { json!("x".repeat(200 * 1024)) } else { json!({"rows": []}) };
                    reply = Some(json!({
                        "call_id": step["id"],
                        "ok": true,
                        "payload_json": payload.to_string(),
                    }));
                }
                "host_global" => {
                    // The loop's answer for the node's own globals.
                    reply = Some(json!({"call_id": step["id"], "ok": true, "payload_json": "{\"how\":{}}"}));
                }
                "finished" | "aborted" => break,
                other => panic!("unknown step kind {other}"),
            }
        }
        (opened, steps)
    }
}

/// The catalogue the loop hands over: two callable tools, two fenced, one blocked by the node's own
/// workspace status — the three cases the fence distinguishes.
fn catalogue() -> Value {
    let execution = json!({"status": "not_blocked", "scope": "workspace_policy_only", "workspace_binding": "not_applicable"});
    let blocked = json!({"status": "blocked", "scope": "workspace_policy_only", "workspace_binding": "supported",
        "reason": "session_workspace_unavailable", "detail": "no allocated binding"});
    json!([
        {"name": "sessions", "description": "List sessions", "schema_json": schema("sessions", "List sessions"), "execution": execution},
        {"name": "read", "description": "Read a file", "schema_json": schema("read", "Read a file"), "execution": execution},
        {"name": "subagent", "description": "Delegate", "schema_json": schema("subagent", "Delegate"), "execution": execution},
        {"name": "codemode", "description": "Code mode", "schema_json": schema("codemode", "Code mode"), "execution": execution},
        {"name": "operation", "description": "Operations", "schema_json": schema("operation", "Operations"), "execution": blocked},
    ])
}

fn schema(name: &str, description: &str) -> String {
    json!({"type": "function", "function": {"name": name, "description": description, "parameters": {"type": "object", "properties": {}}}})
        .to_string()
}

#[test]
fn a_trivial_script_finishes_with_its_value_and_two_sandbox_crossings() {
    let Some(config) = config() else { return };
    let seam = Seam { config };
    let (opened, steps) = seam.run("s1", "return 1");
    assert!(opened["items"].as_array().unwrap().is_empty());
    assert_eq!(opened["session"], "s1", "the loop names the session; the answer confirms it");
    assert_eq!(steps.len(), 1);
    assert_eq!(steps[0]["kind"], "finished");
    assert_eq!(steps[0]["outcome"]["ok"], true);
    assert_eq!(steps[0]["outcome"]["value"], "1");
    let report = seam.finish("s1");
    assert_eq!(report["ok"], true, "finish: {report}");
    assert_eq!(report["sandbox_calls"], 2, "start and close: {report}");
    assert_eq!(report["close_failure"], Value::Null);
}

#[test]
fn one_tool_call_is_one_step_and_the_answer_settles_the_script() {
    let Some(config) = config() else { return };
    let seam = Seam { config };
    let (_, steps) = seam.run("s2", "const r = await tools.sessions({limit:1}); return r;");
    assert_eq!(steps.len(), 2, "one call step then the script's finish: {steps:?}");
    assert_eq!(steps[0]["kind"], "call");
    assert_eq!(steps[0]["name"], "sessions");
    assert_eq!(steps[0]["target"], "tool");
    assert_eq!(steps[0]["id"], 1);
    assert!(steps[0]["refusal"].is_null(), "a callable tool carries no refusal");
    assert_eq!(steps[1]["kind"], "finished");
    assert_eq!(steps[1]["outcome"]["ok"], true);
    let report = seam.finish("s2");
    // start, admit, deliver, close.
    assert_eq!(report["sandbox_calls"], 4, "{report}");
}

#[test]
fn ten_parallel_calls_arrive_as_ten_ordered_steps() {
    let Some(config) = config() else { return };
    let seam = Seam { config };
    let (_, steps) = seam.run("s3", "const r = await Promise.all([1,2,3,4,5,6,7,8,9,10].map(i => tools.sessions({limit:i}))); return r.length;");
    let calls: Vec<&Value> = steps.iter().filter(|step| step["kind"] == "call").collect();
    assert_eq!(calls.len(), BENCH_PARALLEL as usize, "Promise.all is ten queued calls: {steps:?}");
    let ids: Vec<u64> = calls.iter().map(|call| call["id"].as_u64().unwrap()).collect();
    assert_eq!(ids, (1..=10).collect::<Vec<u64>>(), "the guest's order, not ours");
    assert_eq!(steps.last().unwrap()["kind"], "finished");
    let report = seam.finish("s3");
    // start + ten admits + ten deliveries + close.
    assert_eq!(report["sandbox_calls"], 1 + 2 * BENCH_PARALLEL + 1, "{report}");
}

#[test]
fn a_fenced_tool_is_handed_out_with_the_sentence_that_says_where_it_runs() {
    let Some(config) = config() else { return };
    let seam = Seam { config };
    let (_, steps) = seam.run("s4", "const r = await tools.subagent({task:\"x\"}); return r;");
    assert_eq!(steps[0]["kind"], "call");
    assert_eq!(steps[0]["name"], "subagent");
    let refusal = &steps[0]["refusal"];
    assert_eq!(refusal["kind"], "target_not_available");
    assert_eq!(refusal["name"], "subagent");
    assert!(
        refusal["route"].as_str().unwrap().starts_with("Control plane: call subagent as an ordinary tool"),
        "the fence says where it runs: {refusal}"
    );
    // The node's own blocked status wins over the generic sentence.
    seam.finish("s4");
    let (_, blocked) = seam.run("s4b", "const r = await tools.operation({action:\"start\"}); return r;");
    assert!(
        blocked[0]["refusal"]["route"].as_str().unwrap().contains("Not callable in this run: session_workspace_unavailable"),
        "the node's own reason is what the model reads: {blocked:?}"
    );
    seam.finish("s4b");
    // A name the catalogue does not have carries no route at all: plain `codemode_target_not_available`.
    let (_, none) = seam.run("s4c", "const r = await tools.nowhere(); return r;");
    assert_eq!(none[0]["refusal"]["kind"], "target_not_available");
    assert_eq!(none[0]["refusal"]["name"], "nowhere");
    assert_eq!(none[0]["refusal"]["route"], Value::Null);
    seam.finish("s4c");
}

#[test]
fn search_tools_is_answered_inside_the_seam_and_the_guest_gets_the_catalogue() {
    let Some(config) = config() else { return };
    let seam = Seam { config };
    let (_, steps) = seam.run("s5", "const all = await searchTools(\"*\"); return all;");
    // The guest's own global is answered inside the seam, so the whole script costs the loop *no* step:
    // the first advance hands out `finished` directly, exactly as the native loop answers it in place.
    assert_eq!(steps.len(), 1, "the global costs the loop no step: {steps:?}");
    assert_eq!(steps[0]["kind"], "finished");
    let value: Value = serde_json::from_str(steps[0]["outcome"]["value"].as_str().unwrap()).unwrap();
    assert_eq!(value["matches"], 5, "all five names are discoverable: {value}");
    assert_eq!(value["tools"][0]["name"], "codemode");
    assert_eq!(value["tools"][0]["callable"], false);
    assert_eq!(value["tools"][1]["name"], "operation");
    assert_eq!(value["tools"][1]["callable"], false);
    assert!(value["tools"][1]["route"].as_str().unwrap().contains("Not callable in this run"));
    assert_eq!(value["tools"][2]["name"], "read");
    assert_eq!(value["tools"][2]["callable"], true);
}

#[test]
fn describe_tool_showcall_is_a_host_global_because_presentation_is_the_loops() {
    let Some(config) = config() else { return };
    let seam = Seam { config };
    let (_, steps) = seam.run("s6", "const help = await describeTool(\"showCall\"); return help;");
    assert_eq!(steps.len(), 2, "{steps:?}");
    assert_eq!(steps[0]["kind"], "host_global");
    assert_eq!(steps[0]["name"], "describeTool");
    assert_eq!(steps[0]["args_json"], "[\"showCall\"]");
    assert_eq!(steps[1]["kind"], "finished");
}

#[test]
fn a_two_hundred_kilobyte_answer_comes_back_as_the_script_value() {
    let Some(config) = config() else { return };
    let seam = Seam { config };
    let (_, steps) = seam.run("s7", "const r = await tools.read({path:\"big.txt\"}); return r;");
    let value = steps[1]["outcome"]["value"].as_str().expect("the script's value");
    assert_eq!(value.len(), 2 + 200 * 1024, "the string came back whole, quotes and all: {} bytes", value.len());
}

#[test]
fn a_script_the_sandbox_cannot_start_is_a_visible_failure_not_an_empty_answer() {
    let Some(config) = config() else { return };
    let seam = Seam { config };
    let opened = seam.open("s8", "throw new Error('nope')");
    assert_eq!(opened["ok"], true, "the seam answered: {opened}");
    assert!(opened["session"].is_null(), "no session when the guest never ran");
    assert!(opened["sandbox_failure"].as_str().unwrap().contains("stub does not know this script"));
    assert_eq!(opened["unexecuted"].as_array().unwrap().len(), 0);
}

#[test]
fn an_unknown_session_is_a_named_failure_never_a_silent_success() {
    let Some(config) = config() else { return };
    let seam = Seam { config };
    // The host cannot answer for an instance it never kept: that is `ok:false` (the router's "the seam
    // could not answer"), not an empty step.
    let progress = seam.advance("never-opened", None);
    assert_eq!(progress["ok"], false);
    assert_eq!(progress["error"], "component_session_unknown");
    let report = seam.finish("never-opened");
    assert_eq!(report["ok"], false);
    assert_eq!(report["error"], "component_session_unknown");
}

#[test]
fn a_missing_component_is_a_reason_the_router_can_report() {
    let mut config = Config::from_env().with_components(temp_dir("missing")).with_sandbox(Sandbox::Stub).with_timeout(5_000);
    config.wasm = None;
    let answer = call_with(&config, &json!({"op": "open", "session": "s9", "owner": "0".repeat(64), "code": "return 1"}));
    assert_eq!(answer["ok"], false);
    assert!(answer["error"].as_str().unwrap().starts_with("component_not_installed"));
}

#[test]
fn a_second_script_does_not_share_the_first_ones_state() {
    let Some(config) = config() else { return };
    let seam = Seam { config };
    let (_, first) = seam.run("a", "return 1");
    assert_eq!(first[0]["outcome"]["value"], "1");
    seam.finish("a");
    let (opened, second) = seam.run("b", "const r = await tools.sessions({limit:1}); return r;");
    assert_eq!(opened["session"], "b");
    assert_eq!(second[0]["id"], 1, "a fresh script starts its call ids again");
}


/// A failed script's message crosses the seam in `error`, and in `value` for an older component.
///
/// The guest fills `value` for a script that finished and `error` for one that failed
/// (`rust/wa-capabilities/src/quickjs.rs`, the `done` event). The record used to carry only `value`, so
/// every failed script through the component answered `{ok: false}` with no reason at all while the
/// native loop still named it; the parity suite is what noticed
/// (`scripts/test-codemode-component.lua`, "a script that throws"). `error` is the field a component
/// reads now, `value` keeps the legacy spelling so a component built against the older record still
/// learns why.
#[test]
fn a_failed_scripts_message_crosses_the_seam_as_the_done_payload() {
    let answer = json!({"ok": true, "events": [
        {"type": "done", "ok": false, "error": "{\"name\":\"Error\",\"message\":\"boom\"}"},
        {"type": "done", "ok": true, "value": "42", "writes": "[[\"k\",\"v\"]]"}
    ]});
    let done: Vec<sandbox::DoneEvent> = events_of(&answer)
        .into_iter()
        .filter_map(|event| match event {
            sandbox::Event::Done(done) => Some(done),
            _ => None,
        })
        .collect();
    assert_eq!(done.len(), 2, "one done event per script");
    assert!(!done[0].ok, "the failing script stays failed");
    assert_eq!(done[0].error.as_deref(), Some("{\"name\":\"Error\",\"message\":\"boom\"}"),
        "the reason travels in the field the component reads");
    assert_eq!(done[0].value.as_deref(), Some("{\"name\":\"Error\",\"message\":\"boom\"}"),
        "and in `value` too, for a component built against the older record");
    assert!(done[0].writes.is_none(), "a failed script writes nothing");
    assert!(done[1].ok);
    assert_eq!(done[1].value.as_deref(), Some("42"));
    assert!(done[1].error.is_none(), "a finished script has no error");
    assert_eq!(done[1].writes.as_deref(), Some("[[\"k\",\"v\"]]"));
}
