//! Lua's policy stays in Lua; process ownership and cancellation stay outside its interpreter.
use serde_json::{json, Value};
use std::{sync::OnceLock, time::Duration};
use wa_operation::{Manager, Spec};

fn command_result(manager: &Manager, id: &str, mut state: Value) -> Value {
    let code = state["process_exit_code"].as_i64().unwrap_or(-1);
    if let Ok(page) = manager.read(id, "stdout", 0, 24 * 1024) {
        state["stdout"] = page["content"].clone();
        state["stdout_truncated"] =
            json!(page["available_bytes"].as_u64().unwrap_or(0) > 24 * 1024);
    }
    if let Ok(page) = manager.read(id, "stderr", 0, 8 * 1024) {
        state["stderr"] = page["content"].clone();
    }
    state["command_completed"] = json!(true);
    state["command_code"] = json!(code);
    state["command_ok"] = json!(code == 0);
    state["completion_scope"] = json!("command");
    state["operation_settled"] = state["settled"].clone();
    state["ok"] = json!(code == 0);
    state["code"] = json!(code);
    state["output_complete"] = json!(state["output_streams_closed"] == true);
    state["note"] = json!(format!(
        "the shell command completed with exit code {code}; descendants remain supervised as operation {id} under the original command timeout. Their work is not complete, and they may produce more output. Observe or await full settlement only if the task depends on them."
    ));
    state
}
pub fn manager() -> &'static Manager {
    static MANAGER: OnceLock<Manager> = OnceLock::new();
    MANAGER.get_or_init(|| {
        Manager::new(
            std::path::PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()))
                .join(".wasm-agent/operations"),
        )
        // A command the agent runs can print the node's own key; the operation's stdout is
        // written as it arrives, so redact before the write, not only in the transcript.
        .with_env_secrets()
    })
}
fn spec(
    program: &str,
    flag: &str,
    command: &str,
    cwd: &str,
    seconds: u64,
    owner: String,
    promote: bool,
) -> Spec {
    let mut spec = Spec::command(program, vec![flag.into(), command.into()]);
    spec.cwd = cwd.into();
    spec.timeout = Duration::from_secs(seconds);
    // A foreground `bash` adopts a descendant tree it cannot wait for; a deliberately
    // started operation is already background and never needs to.
    spec.promote_descendants = promote;
    // A child's operation is owned by the child session/run, not by whatever
    // interpreter slot happens to be on this thread, so settlement is attributable.
    spec.owner = crate::subagents::current_owner().unwrap_or(owner);
    if crate::serve::in_turn() {
        spec.env.push(("WASM_AGENT_IN_TURN".into(), "1".into()));
    } // naming-check: allow (installed deploy scripts)
    spec
}
pub fn foreground(
    program: &str,
    flag: &str,
    command: &str,
    cwd: &str,
    seconds: u64,
) -> Result<Value, String> {
    let id = manager()
        .start(spec(
            program,
            flag,
            command,
            cwd,
            seconds,
            format!("worker:{}", crate::serve::worker_id()),
            true,
        ))
        .map_err(|e| e.to_string())?;
    loop {
        let mut state = manager()
            .wait(&id, Duration::from_millis(100))
            .map_err(|e| e.to_string())?;
        if state["settled"] == true {
            if state["error"] == "deadline_exceeded" {
                let stderr = state["stderr"].as_str().unwrap_or("");
                state["stderr"] = json!(format!("{stderr}\n{}", deadline_note(seconds, &state)));
            }
            return Ok(state);
        }
        // The shell exited leaving live descendants, so they were adopted rather than
        // failed. Return the receipt now: the operation keeps running under the
        // supervisor, and the caller is told which process it now owns.
        if state["promoted"] == true
            && (state["output_streams_closed"] == true
                || state["output_idle_ms"].as_u64().unwrap_or(0)
                    >= wa_operation::COMMAND_OUTPUT_IDLE_MS)
        {
            state["foreground_return_elapsed_ms"] = state["elapsed_ms"].clone();
            return Ok(command_result(manager(), &id, state));
        }
        if state["overdue"] == true {
            let _ = manager().cancel(&id);
            return Ok(
                json!({"operation_id":id,"ok":false,"code":-1,"error":"operation_supervisor_overdue","cleanup":"unknown","output_complete":false}),
            );
        }
        // A cancelled run or child cancels its operation too, and stays attached
        // until the operation actually settles: returning while it still runs would
        // let the effect outlive the execution that owns it.
        if crate::host::run_cancel_requested() {
            let _ = manager().cancel(&id);
            let cleanup = std::time::Instant::now() + Duration::from_millis(1000);
            while std::time::Instant::now() < cleanup {
                let stopped = manager()
                    .wait(&id, Duration::from_millis(50))
                    .map_err(|e| e.to_string())?;
                if stopped["settled"] == true {
                    return Ok(json!({"operation_id":id,"ok":false,"error":"run_cancelled",
                        "state":stopped["state"],"cleanup":"settled","output_complete":stopped["output_complete"]}));
                }
            }
            return Ok(json!({"operation_id":id,"ok":false,"error":"run_cancelled",
                "cleanup":"unknown","output_complete":false}));
        }
        // This is the waiting interpreter observing the supervisor, not a helper beating forever.
        crate::serve::beat();
    }
}
pub fn control(action: &str, args: &Value, shell: &(String, String)) -> Result<Value, String> {
    let id = args["id"].as_str().unwrap_or("");
    let result = match action {
        "start" => {
            let command = args["command"]
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or("command_required")?;
            let owner = args["owner"].as_str().unwrap_or("").to_string();
            let seconds = args["timeout_seconds"]
                .as_u64()
                .unwrap_or(crate::host::exec_timeout_seconds());
            let id = manager()
                .start(spec(
                    &shell.0,
                    &shell.1,
                    command,
                    args["cwd"].as_str().unwrap_or(""),
                    seconds,
                    owner,
                    false,
                ))
                .map_err(|e| e.to_string())?;
            return Ok(
                json!({"operation_id":id,"state":"accepted","settled":false,"note":"Launch receipt, not execution success. Observe this operation; do not launch it again. Keep background commands in the foreground of this shell (or use wait)."}),
            );
        }
        "list" => return Ok(manager().list()),
        "status" => manager().snapshot(id),
        "await" => {
            // Foreground bash can complete while its adopted descendants remain supervised.
            // Default to the command boundary for those operations; explicit operation start
            // and wait_for=settled retain full process-tree settlement semantics.
            let wait_for = args["wait_for"].as_str().unwrap_or("command");
            if wait_for != "command" && wait_for != "settled" {
                return Err("invalid_wait_for:expected_command_or_settled".into());
            }
            loop {
                let state = manager()
                    .wait(id, Duration::from_millis(250))
                    .map_err(|e| e.to_string())?;
                if state["settled"] == true {
                    return Ok(state);
                }
                if wait_for == "command"
                    && state["promoted"] == true
                    && (state["output_streams_closed"] == true
                        || state["output_idle_ms"].as_u64().unwrap_or(0)
                            >= wa_operation::COMMAND_OUTPUT_IDLE_MS)
                {
                    return Ok(command_result(manager(), id, state));
                }
                if crate::host::run_cancel_requested() {
                    return Ok(json!({"operation_id":id,"ok":false,"settled":false,
                        "error":"await_interrupted","outcome":"still_running",
                        "note":"The wait was interrupted; the independently supervised operation was not canceled. Inspect it or await again. Do not rerun it."}));
                }
                if state["overdue"] == true {
                    return Ok(json!({"operation_id":id,"ok":false,"settled":false,
                        "error":"operation_supervisor_overdue","outcome":"unknown",
                        "note":"No replay or inferred success. Inspect or explicitly cancel/recover."}));
                }
                crate::serve::beat();
            }
        }
        "cancel" => manager().cancel(id),
        "wait" => manager().wait(
            id,
            Duration::from_millis(args["wait_ms"].as_u64().unwrap_or(1000).min(10000)),
        ),
        "read" => manager().read(
            id,
            args["stream"].as_str().unwrap_or("stdout"),
            args["offset"].as_u64().unwrap_or(0),
            args["limit"].as_u64().unwrap_or(8192) as usize,
        ),
        _ => return Err("unknown_operation_action".into()),
    };
    result.map_err(|e| e.to_string())
}
pub fn health() -> Value {
    let entries = manager().list();
    json!(entries.as_array().unwrap().iter().filter(|s|s["settled"]!=true).map(|s|json!({"operation_id":s["operation_id"],"owner":s["owner"],"state":s["state"],"elapsed_ms":s["elapsed_ms"],"timeout_ms":s["timeout_ms"],"cleanup_budget_ms":s["cleanup_budget_ms"],"overdue":s["overdue"],"output_bytes":s["output_bytes"]})).collect::<Vec<_>>())
}

/// What a deadline can honestly say.
///
/// This message used to assert a cause - "a call to this node's own busy session cannot serve
/// itself; use an independent route" - which the record cannot support: everything that outlives
/// its bound lands here, including a read-only `grep` that never addressed this node at all. A
/// printed cause is a fact-shaped thing, so it was quoted onward as a finding; a false one costs
/// the round twice. What the operation *does* know is where its time went - `timing` is measured
/// in phases - so the note reports exactly that, and nothing it did not measure.
fn deadline_note(seconds: u64, state: &Value) -> String {
    let phase = |name: &str| state["timing"][name].as_u64();
    let mut phases = Vec::new();
    for (name, label) in [
        ("setup_ms", "setup"),
        ("spawn_ms", "spawn"),
        ("execution_ms", "executing"),
        ("drain_cleanup_ms", "cleanup"),
    ] {
        if let Some(ms) = phase(name) {
            phases.push(format!("{label} {ms}ms"));
        }
    }
    let account = if phases.is_empty() {
        "no phase breakdown was recorded".to_string()
    } else {
        phases.join(", ")
    };
    match state["elapsed_ms"].as_u64() {
        Some(total) => format!(
            "the command did not finish within {seconds}s; its operation was terminated after {total}ms ({account})."
        ),
        None => format!(
            "the command did not finish within {seconds}s; its operation was terminated ({account})."
        ),
    }
}

#[cfg(test)]
mod deadline_note_tests {
    use super::deadline_note;
    use serde_json::json;

    // What the reader gets is the measurement, in the order the operation spends it.
    #[test]
    fn the_note_reports_the_measured_phases() {
        let state = json!({
            "elapsed_ms": 61005,
            "timing": {"setup_ms": 8712, "spawn_ms": 10, "execution_ms": 51182, "drain_cleanup_ms": 1000}
        });
        assert_eq!(
            deadline_note(60, &state),
            "the command did not finish within 60s; its operation was terminated after 61005ms \
             (setup 8712ms, spawn 10ms, executing 51182ms, cleanup 1000ms)."
        );
    }

    // The sentence this replaced was printed for *every* deadline and read onward as a
    // diagnosis. It must not come back in any form.
    #[test]
    fn the_note_never_names_a_cause() {
        let state = json!({"elapsed_ms": 300006, "timing": {"execution_ms": 299000}});
        let note = deadline_note(300, &state);
        assert!(!note.contains("busy session"), "{note}");
        assert!(!note.contains("independent route"), "{note}");
        assert!(note.contains("executing 299000ms"), "{note}");
    }

    // An operation killed before a phase was measured says what is known rather than inventing.
    #[test]
    fn a_missing_breakdown_is_stated_not_invented() {
        let state = json!({"elapsed_ms": 5000});
        assert_eq!(
            deadline_note(4, &state),
            "the command did not finish within 4s; its operation was terminated after 5000ms \
             (no phase breakdown was recorded)."
        );
    }
}
