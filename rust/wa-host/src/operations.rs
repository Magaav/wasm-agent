//! Lua's policy stays in Lua; process ownership and cancellation stay outside its interpreter.
use serde_json::{json, Value};
use std::{sync::OnceLock, time::Duration};
use wa_operation::{Manager, Spec};
pub fn manager() -> &'static Manager {
    static MANAGER: OnceLock<Manager> = OnceLock::new();
    MANAGER.get_or_init(|| {
        Manager::new(
            std::path::PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()))
                .join(".wasm-agent/operations"),
        )
    })
}
fn spec(program: &str, flag: &str, command: &str, cwd: &str, seconds: u64, owner: String, promote: bool) -> Spec {
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
                state["stderr"]=json!(format!("{stderr}\nthe command did not finish within {seconds}s; its operation was terminated. A call to this node's own busy session cannot serve itself; use an independent route."));
            }
            return Ok(state);
        }
        // The shell exited leaving live descendants, so they were adopted rather than
        // failed. Return the receipt now: the operation keeps running under the
        // supervisor, and the caller is told which process it now owns.
        if state["promoted"] == true {
            let mut receipt = state;
            // Output up to the moment the shell exited is real evidence; a receipt with
            // none would read as a command that printed nothing.
            if let Ok(page) = manager().read(&id, "stdout", 0, 24 * 1024) {
                receipt["stdout"] = page["content"].clone();
                receipt["stdout_truncated"] =
                    json!(page["available_bytes"].as_u64().unwrap_or(0) > 24 * 1024);
            }
            if let Ok(page) = manager().read(&id, "stderr", 0, 8 * 1024) {
                receipt["stderr"] = page["content"].clone();
            }
            receipt["ok"] = json!(true);
            receipt["output_complete"] = json!(false);
            receipt["note"] = json!("the shell exited leaving live processes; they are adopted as this operation and keep running. Read it with operation read; stop it with operation cancel.");
            return Ok(receipt);
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
            // One model call observes settlement; no synthesized conversation events or replay.
            loop {
                let state=manager().wait(id,Duration::from_millis(250)).map_err(|e|e.to_string())?;
                if state["settled"] == true {return Ok(state);}
                if state["overdue"] == true {
                    return Ok(json!({"operation_id":id,"ok":false,"settled":false,
                        "error":"operation_supervisor_overdue","outcome":"unknown",
                        "note":"No replay or inferred success. Inspect or explicitly cancel/recover."}));
                }
                crate::serve::beat();
            }
        },
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
