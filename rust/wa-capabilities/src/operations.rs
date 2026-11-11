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
        let available = page["available_bytes"].as_u64().unwrap_or(0);
        state["stderr_bytes"] = json!(available);
        state["stderr_truncated"] = json!(available > 8 * 1024);
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
        let home = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| ".".into()));
        Manager::new(home.join(".wasm-agent/operations"))
            // A shell whose recorded directory is gone starts in the agent home, and says so in
            // its result, instead of inheriting a directory that no longer exists (a released
            // worktree is the ordinary way this happens). See `Manager::with_fallback_cwd`.
            .with_fallback_cwd(home)
        // A command the agent runs can print the node's own key; the operation's stdout is
        // written as it arrives, so redact before the write, not only in the transcript.
        .with_env_secrets()
    })
}
// The preserved draft used script files. A named refusal is the narrower safe route:
// no script with changed $0 semantics or credential-bearing command artifact is executed.
//
// The inline bound is not a style rule. Git-Bash on Windows silently CUTS a `-c` string at
// 8192 bytes: a 9000-byte command ran, did nothing and exited 0, so the refusal has to stay
// below that. What changes here is that an over-long command is no longer refused - it is
// staged to a private file and executed as `bash <file>`, the exact route the refusal used
// to tell the caller to take by hand. Bytes are preserved verbatim, and the result says
// `staged_script` so the one semantic difference ($0 is the script path, not "bash") is
// visible rather than implied.
const WINDOWS_INLINE_COMMAND_BUDGET: usize = 8192;
// Still bounded: a staged script is a real file, not an unbounded dump.
const STAGED_COMMAND_LIMIT: usize = 1 << 20;

pub(crate) struct Launch {
    pub program: String,
    pub args: Vec<String>,
    pub staged: Option<std::path::PathBuf>,
}

fn command_line_overflow(program: &str, flag: &str, command: &str) -> bool {
    let escaped = |s: &str| s.encode_utf16().map(|c| if c == 34 || c == 92 { 2 } else { 1 }).sum::<usize>();
    cfg!(windows) && escaped(program) + escaped(flag) + escaped(command) + 520 > WINDOWS_INLINE_COMMAND_BUDGET
}

fn commands_dir() -> std::path::PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    std::path::PathBuf::from(home).join(".wasm-agent/commands")
}

fn stage_command(command: &str) -> Result<std::path::PathBuf, String> {
    stage_command_in(&commands_dir(), command)
}

fn stage_command_in(dir: &std::path::Path, command: &str) -> Result<std::path::PathBuf, String> {
    use std::io::Write;
    std::fs::create_dir_all(dir).map_err(|e| format!("shell_command_stage_failed: {e}"))?;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let path = dir.join(format!("command-{}-{stamp}.sh", std::process::id()));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&path).map_err(|e| format!("shell_command_stage_failed: {e}"))?;
    file.write_all(command.as_bytes())
        .map_err(|e| format!("shell_command_stage_failed: {e}"))?;
    Ok(path)
}

// Inline when it fits; otherwise the same bytes run from a staged script file.
fn command_launch(program: &str, flag: &str, command: &str) -> Result<Launch, String> {
    if command.len() > STAGED_COMMAND_LIMIT {
        return Err(format!(
            "shell_command_too_long: {} bytes; a staged script is capped at {STAGED_COMMAND_LIMIT} bytes - write the script yourself and run it by path",
            command.len()
        ));
    }
    if !command_line_overflow(program, flag, command) {
        return Ok(Launch { program: program.into(), args: vec![flag.into(), command.into()], staged: None });
    }
    let path = stage_command(command)?;
    Ok(Launch { program: program.into(), args: vec![path.to_string_lossy().into_owned()], staged: Some(path) })
}
fn spec(launch: &Launch, cwd: &str, seconds: u64, owner: String, promote: bool) -> Spec {
    configure_spec(
        Spec::command(launch.program.clone(), launch.args.clone()),
        cwd,
        seconds,
        owner,
        promote,
    )
}
/// The kinds an operation can be, and what each one's default deadline is when the caller gives none.
///
/// Measured on wasm_the_first (2026-11-10): a supervised build was killed at the 300 s default because the
/// caller passed no `timeout_seconds` at all - the deadline existed, was applied, and was never said. `bash`
/// documents its own 300 s in the tool description, but `operation start` promised a supervised long command
/// and silently gave it the short one. The default now follows what the command IS, and every start that used
/// a default says so in its receipt (`timeout_source`, `timeout_kind`, `timeout_notice`), so nobody has to
/// learn it from a kill.
pub(crate) const OPERATION_KINDS: [&str; 4] = ["command", "build", "test", "deploy"];

pub(crate) fn default_operation_timeout_seconds(kind: &str) -> u64 {
    match kind {
        "build" => 5400,
        "test" => 3600,
        "deploy" => 3600,
        _ => 300,
    }
}

/// What this operation is: the caller's explicit `kind`, or a conservative read of its command line.
/// An explicit kind is validated; an inference is only ever used to pick a default, and the receipt says
/// which one was used, so a wrong guess costs time and never silently shortens the caller's intent.
pub(crate) fn operation_kind(args: &Value, command: &str) -> Result<&'static str, String> {
    if let Some(kind) = args["kind"].as_str().filter(|kind| !kind.is_empty()) {
        return OPERATION_KINDS.iter().copied().find(|known| *known == kind)
            .ok_or_else(|| format!("operation_kind_unknown:{kind}: expected one of {}", OPERATION_KINDS.join(", ")));
    }
    let text = command.to_ascii_lowercase();
    if ["cargo build", "build-window.sh", "codemode-build", "publish-node-binaries", "build-components", "build-plugins"]
        .iter().any(|needle| text.contains(needle)) {
        return Ok("build");
    }
    if ["deploy.sh", "upgrade.sh", "install.sh", "wa update", "wa update"].iter().any(|needle| text.contains(needle)) {
        return Ok("deploy");
    }
    if ["test.sh", "fast.sh", "cargo test", "test-", "bench-"].iter().any(|needle| text.contains(needle)) {
        return Ok("test");
    }
    Ok("command")
}

fn configure_spec(mut spec: Spec, cwd: &str, seconds: u64, owner: String, promote: bool) -> Spec {
    spec.cwd = cwd.into();
    spec.timeout = Duration::from_secs(seconds);
    // A foreground `bash` adopts a descendant tree it cannot wait for; a deliberately
    // started operation is already background and never needs to.
    spec.promote_descendants = promote;
    // A child's operation is owned by the child session/run, not by whatever
    // interpreter slot happens to be on this thread, so settlement is attributable.
    spec.owner = crate::subagents::current_owner().unwrap_or(owner);
    if crate::serve::in_turn() || crate::subagents::current_provenance() == Some("child") {
        spec.env.push(("WASM_AGENT_IN_TURN".into(), "1".into()));
    } // naming-check: allow (installed deploy scripts)
    // Who this process is, so a guard can decide by role. The host knows it from the thread's own
    // task context (a run of a session is `orchestrator`, a subagent task is `child`), and the
    // commit guard in `.githooks/pre-commit` reads it: that is what lets the node's orchestrator
    // session land on `main` while a child cannot get there by exporting the old
    // `WASM_AGENT_ALLOW_MAIN` flag, which said nothing about who was committing. Pushed beside the
    // turn boolean so the bash tool and `operation start` cannot disagree about the answer.
    //
    // Pushed for *every* shell, including an explicit empty value when this thread has no task
    // context, because the marker is inherited: `wa-operation` adds `spec.env` without `env_clear`,
    // so a shell started from a run's own shell hands `orchestrator` down to everything below it. An
    // empty value stops a host-started shell from passing on a marker the *host* did not just
    // decide - and the hook reads empty exactly as it reads unset (the human path). It does not
    // reach a process that never re-enters the host: a terminal, an external agent runtime or a node
    // restarted from an orchestrator shell keeps what it inherited. That residual trust boundary is
    // named in `.githooks/pre-commit` rather than papered over.
    spec.env.push((
        "WASM_AGENT_PROVENANCE".into(),
        crate::subagents::current_provenance().unwrap_or_default().to_string(),
    ));
    spec
}
fn launch_context(mut spec: Spec, context: &Value) -> Spec {
    spec.cwd_requested = context["requested"].as_str().map(String::from);
    spec.cwd_source = context["source"].as_str().map(String::from);
    spec.require_cwd = context["required"] == true;
    spec
}
/// One tick of a long call's row (`docs/TOOL-PROGRESS.md`): the tail of the operation's two output
/// streams, parsed and published for the session-status-content row.
///
/// It runs on every pass of a wait loop, which is safe because `crate::tool_progress` bounds itself -
/// at most four writes a second and a grow-only byte cursor - and it reads the output *file*, which
/// `wa-operation` already wrote without the node's secrets. Nothing here is on the result path: the
/// state this loop returns is untouched by it.
fn progress_tick(state: &Value, tool: &str) {
    let Some(id) = state["operation_id"].as_str() else { return };
    let Some(stdout) = state["stdout_path"].as_str() else { return };
    let stderr = state["stderr_path"].as_str().unwrap_or("");
    let elapsed = state["elapsed_ms"].as_u64().unwrap_or(0) as f64 / 1000.0;
    crate::tool_progress::tick(id, tool, crate::tool_progress::now_epoch() - elapsed, stdout, stderr);
}

pub fn foreground(
    program: &str,
    flag: &str,
    command: &str,
    cwd: &str,
    seconds: u64,
    context: &Value,
) -> Result<Value, String> {
    let launch = command_launch(program, flag, command)?;
    let staged = launch.staged.clone();
    let id = manager()
        .start(launch_context(spec(
            &launch,
            cwd,
            seconds,
            format!("worker:{}", crate::serve::node_thread_id()),
            true,
        ), context))
        .map_err(|e| e.to_string())?;
    // The name the reader knows this call by: the `bash` tool's own name, sent with the launch
    // (`lua/core/tools.lua`), so the row says `⟳ bash` and not `⟳ worker:7`.
    let tool = context["tool"].as_str().filter(|name| !name.is_empty()).unwrap_or("bash").to_string();
    loop {
        let mut state = manager()
            .wait(&id, Duration::from_millis(100))
            .map_err(|e| e.to_string())?;
        progress_tick(&state, &tool);
        if state["settled"] == true {
            crate::tool_progress::finish(&id);
            if state["error"] == "deadline_exceeded" {
                let stderr = state["stderr"].as_str().unwrap_or("");
                state["stderr"] = json!(format!("{stderr}\n{}", deadline_note(seconds, &state)));
            }
            if let Some(path) = staged.as_ref() {
                state["staged_script"] = json!(path.to_string_lossy());
                state["staged_script_note"] = json!("the command was too long for the Windows command line and ran from this staged file; $0 is the file path");
                // Settled means the shell has finished, so the staged bytes can go. A failure
                // here is not the caller's problem: the file stays under ~/.wasm-agent/commands.
                let _ = std::fs::remove_file(path);
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
            if let Some(path) = staged.as_ref() {
                // Still running: the shell may read this file again, so it stays until settled.
                state["staged_script"] = json!(path.to_string_lossy());
                state["staged_script_note"] = json!("the command was too long for the Windows command line and ran from this staged file; $0 is the file path, and the file is kept while the operation runs");
            }
            crate::tool_progress::finish(&id);
            return Ok(command_result(manager(), &id, state));
        }
        if state["overdue"] == true {
            crate::tool_progress::finish(&id);
            let _ = manager().cancel(&id);
            return Ok(
                json!({"operation_id":id,"ok":false,"code":-1,"error":"operation_supervisor_overdue","cleanup":"unknown","output_complete":false}),
            );
        }
        // A cancelled run or child cancels its operation too, and stays attached
        // until the operation actually settles: returning while it still runs would
        // let the effect outlive the execution that owns it.
        if crate::host::run_cancel_requested() {
            crate::tool_progress::finish(&id);
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
            if args.get("replay_of").is_some(){return Err("operation_replay_forbidden: inspect original and make a separately authorized decision".into());}
            let owner = args["owner"].as_str().unwrap_or("").to_string();
            let command_hint = args["command"].as_str().unwrap_or("");
            let requested_seconds = args["timeout_seconds"].as_u64();
            let default_kind = if requested_seconds.is_none() {
                Some(operation_kind(args, command_hint)?)
            } else {
                // An explicit kind with an explicit timeout is still validated, so a typo cannot look applied.
                if args["kind"].as_str().is_some_and(|kind| !kind.is_empty()) {
                    let _ = operation_kind(args, command_hint)?;
                }
                None
            };
            let seconds = requested_seconds
                .unwrap_or_else(|| default_operation_timeout_seconds(default_kind.unwrap_or("command")));
            let cwd=args["cwd"].as_str().unwrap_or("");
            let mut staged_script: Option<std::path::PathBuf> = None;
            let launch=if let Some(program)=args["program"].as_str() {
                if args.get("command").is_some() {return Err("program_and_command_are_exclusive".into());}
                let name=if cfg!(windows) && !program.ends_with(".exe") {format!("{program}.exe")} else {program.to_string()};
                let executable=if std::path::Path::new(&name).is_absolute() {
                    if !std::path::Path::new(&name).is_file() {return Err("program_not_found".into());}
                    name
                } else {
                    if name.contains('/') || name.contains('\\') {return Err("program_requires_native_absolute_path_or_path_name".into());}
                    crate::host::executable_on_path(&name).ok_or("program_not_found_on_path")?
                };
                let argv=args["args"].as_array().ok_or("program_args_required")?.iter()
                    .map(|arg|arg.as_str().map(String::from).ok_or("program_args_must_be_strings"))
                    .collect::<Result<Vec<_>,_>>()?;
                configure_spec(Spec::command(executable,argv),cwd,seconds,owner,false)
            } else {
                let command=args["command"].as_str().filter(|s|!s.is_empty()).ok_or("command_required")?;
                let prepared = command_launch(&shell.0, &shell.1, command)?;
                staged_script = prepared.staged.clone();
                spec(
                    &prepared,
                    cwd,
                    seconds,
                    owner,
                    false,
                )
            };
            let id = manager()
                .start(launch_context(launch, &args["_launch_cwd"]))
                .map_err(|e| e.to_string())?;
            let state = manager().snapshot(&id).map_err(|e| e.to_string())?;
            let mut receipt = json!({"operation_id":id,"state":"accepted","settled":false,"note":"Launch receipt, not execution success. Observe this operation; do not launch it again. Keep background commands in the foreground of this shell (or use wait)."});
            // No silent deadline. A caller that named one gets `timeout_source: caller`; a caller that did
            // not gets the kind's default AND a sentence saying which default was used and how to raise it.
            match default_kind {
                Some(kind) => {
                    receipt["timeout_source"] = json!("default");
                    receipt["timeout_kind"] = json!(kind);
                    receipt["timeout_ms"] = json!(seconds * 1000);
                    receipt["timeout_notice"] = json!(format!(
                        "no timeout_seconds was given: this {kind} operation uses the {kind} default of {seconds}s. Pass timeout_seconds (1-86400) to set it explicitly; when it runs out the operation is killed and reported deadline_exceeded."));
                }
                None => {
                    receipt["timeout_source"] = json!("caller");
                    receipt["timeout_ms"] = json!(seconds * 1000);
                }
            }
            if let Some(path) = staged_script.as_ref() {
                receipt["staged_script"] = json!(path.to_string_lossy());
                receipt["staged_script_note"] = json!("the command was too long for the Windows command line and ran from this staged file; $0 is the file path, the script is not removed while the operation may still read it");
            }
            for key in ["cwd", "cwd_requested", "cwd_source", "effective_cwd", "cwd_substitution", "cwd_note"] {
                if let Some(value) = state.get(key) { receipt[key] = value.clone(); }
            }
            return Ok(receipt);
        }
        "list" => return Ok(manager().list()),
        "relevant" => manager().relevant(
            args["cwd"].as_str().unwrap_or(""),
            args["after"].as_str().unwrap_or(""),
            args["limit"].as_u64().unwrap_or(64).min(256) as usize,
        ),
        "index" => manager().import_index(args["evidence"].as_str().unwrap_or("")),
        "reconcile" => manager().reconcile(args),
        "quarantine_retire" => {
            if crate::serve::in_turn() || std::env::var("WASM_AGENT_IN_TURN").as_deref()==Ok("1") || std::env::var("WA_QUARANTINE_EXECUTOR").as_deref()!=Ok("1") {return Err("quarantine_requires_explicit_external_executor".into());}
            manager().quarantine_retire(args)
        },
        "legacy_adjudicate" => {
            if crate::serve::in_turn() || std::env::var("WASM_AGENT_IN_TURN").ok().as_deref()==Some("1") || std::env::var("WA_LEGACY_EXTERNAL_EXECUTOR").ok().as_deref()!=Some("1") {return Err("legacy_adjudication_requires_external_reviewed_executor".into());}
            manager().adjudicate_legacy(args)
        },
        "allocation_safety" => manager().allocation_safety(args),
        "identity" => manager().identity(),
        "status" => manager().snapshot(id),
        "await" => {
            // Foreground bash can complete while its adopted descendants remain supervised.
            // Default to the command boundary for those operations; explicit operation start
            // and wait_for=settled retain full process-tree settlement semantics.
            let wait_for = args["wait_for"].as_str().unwrap_or("command");
            if wait_for != "command" && wait_for != "settled" {
                return Err("invalid_wait_for:expected_command_or_settled".into());
            }
            let tool = args["tool"].as_str().filter(|name| !name.is_empty()).unwrap_or("operation");
            loop {
                let state = manager()
                    .wait(id, Duration::from_millis(250))
                    .map_err(|e| e.to_string())?;
                progress_tick(&state, tool);
                if state["settled"] == true {
                    crate::tool_progress::finish(id);
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
        "cancel" => {
            let stopped = manager().cancel(id);
            // A cancelled call is over: its row goes with it.
            crate::tool_progress::finish(id);
            stopped
        }
        // A caller polling an operation is the other place that owns its tail for a while (the
        // `operation` tool's own loop, the window's `/operation` read): refresh the row while it
        // waits, so a long call that the model is watching says what it is doing.
        "wait" => {
            let budget = Duration::from_millis(args["wait_ms"].as_u64().unwrap_or(1000).min(10000));
            let started = std::time::Instant::now();
            loop {
                let state = manager()
                    .wait(id, budget.min(Duration::from_millis(250)))
                    .map_err(|e| e.to_string())?;
                progress_tick(&state, args["tool"].as_str().filter(|name| !name.is_empty()).unwrap_or("operation"));
                if state["settled"] == true { crate::tool_progress::finish(id); return Ok(state); }
                if started.elapsed() >= budget { return Ok(state); }
            }
        }
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

    #[test]
    fn child_shell_is_marked_in_turn_and_cannot_request_installation() {
        use crate::subagents::{TaskContext,Provenance,SocketSlot};
        use std::sync::{Arc,atomic::AtomicBool};
        crate::subagents::enter_task(TaskContext{cancel:Arc::new(AtomicBool::new(false)),deadline:None,
            sockets:SocketSlot::default(),owner:"child-fixture".into(),provenance:Provenance::Child});
        let spec=super::configure_spec(wa_operation::Spec::command("fixture",vec![]),"",1,"".into(),false);
        crate::subagents::leave_task();
        assert!(spec.env.contains(&("WASM_AGENT_IN_TURN".into(),"1".into())));
        assert!(spec.env.contains(&("WASM_AGENT_PROVENANCE".into(),"child".into())));
        assert_eq!(spec.owner,"child-fixture");
    }
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

#[cfg(test)]
mod command_launch_tests {
    use super::{
        command_launch, command_line_overflow, stage_command_in, STAGED_COMMAND_LIMIT,
        WINDOWS_INLINE_COMMAND_BUDGET,
    };

    #[test]
    fn short_commands_stay_inline() {
        let launch = command_launch("bash", "-c", "echo short").expect("short command launches");
        assert!(launch.staged.is_none());
        assert_eq!(launch.args, vec!["-c".to_string(), "echo short".to_string()]);
    }

    // The measured trap: Git-Bash cuts a `-c` string at 8192 bytes, so a 10 KB command
    // must run from a staged file instead of being put on the command line.
    #[test]
    fn a_multi_kb_command_is_staged_instead_of_refused() {
        let command = format!("#{}\necho REACHED\n", "x".repeat(10_000));
        assert_eq!(command_line_overflow("bash", "-c", &command), cfg!(windows));
        let launch = command_launch("bash", "-c", &command).expect("a 10 KB command must launch");
        if cfg!(windows) {
            let path = launch.staged.as_ref().expect("over-long command must be staged");
            assert_eq!(std::fs::read_to_string(path).unwrap(), command, "staged bytes are exact");
            assert_eq!(launch.args, vec![path.to_string_lossy().into_owned()], "bash <file>");
            let _ = std::fs::remove_file(path);
        } else {
            assert!(launch.staged.is_none(), "no command-line limit to work around");
        }
    }

    #[test]
    fn staged_bytes_are_exact_and_private() {
        let dir = std::env::temp_dir().join(format!("wa-command-stage-{}", std::process::id()));
        let body = "echo 'aspas \" e $VAR'\r\necho segunda linha\n";
        let path = stage_command_in(&dir, body).expect("stage");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), body);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        }
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    #[test]
    fn absurd_scripts_are_still_refused_by_name() {
        let command = "x".repeat(STAGED_COMMAND_LIMIT + 1);
        let error = match command_launch("bash", "-c", &command) {
            Ok(_) => panic!("a 1 MiB command must refuse"),
            Err(error) => error,
        };
        assert!(error.contains("shell_command_too_long"), "{error}");
    }

    // `\` and `"` escape to two units, so a quote-heavy command reaches the bound sooner.
    #[test]
    fn counts_quoting_overhead_towards_the_bound() {
        let command = "\"".repeat(WINDOWS_INLINE_COMMAND_BUDGET / 2 + 10);
        assert_eq!(command_line_overflow("bash", "-c", &command), cfg!(windows));
    }
}

/// No silent deadline. A caller that gives no `timeout_seconds` gets a default chosen by what the command
/// IS, and the receipt says so; an explicit timeout is used as given. Measured on wasm_the_first
/// (2026-11-10): a supervised build died at the 300 s command default because its caller passed nothing -
/// the deadline was real, applied, and never mentioned.
#[cfg(test)]
mod operation_deadline_tests {
    use super::{default_operation_timeout_seconds, operation_kind};
    use serde_json::json;

    #[test]
    fn the_default_follows_the_kind_of_work() {
        assert_eq!(default_operation_timeout_seconds("build"), 5400);
        assert_eq!(default_operation_timeout_seconds("test"), 3600);
        assert_eq!(default_operation_timeout_seconds("deploy"), 3600);
        assert_eq!(default_operation_timeout_seconds("command"), 300);
        assert_eq!(default_operation_timeout_seconds("something-else"), 300);
    }

    #[test]
    fn a_command_is_classified_from_what_it_runs() {
        assert_eq!(operation_kind(&json!({}), "cargo build --release --offline").unwrap(), "build");
        assert_eq!(operation_kind(&json!({}), "bash scripts/build-window.sh").unwrap(), "build");
        assert_eq!(operation_kind(&json!({}), "bash scripts/fast.sh").unwrap(), "test");
        assert_eq!(operation_kind(&json!({}), "cargo test --offline -p wa-host").unwrap(), "test");
        assert_eq!(operation_kind(&json!({}), "bash scripts/deploy.sh").unwrap(), "deploy");
        assert_eq!(operation_kind(&json!({}), "git status").unwrap(), "command");
        assert_eq!(operation_kind(&json!({}), "rm -rf /tmp/x").unwrap(), "command");
    }

    #[test]
    fn an_explicit_kind_wins_and_a_wrong_one_is_refused() {
        assert_eq!(operation_kind(&json!({"kind": "build"}), "git status").unwrap(), "build");
        let error = operation_kind(&json!({"kind": "everything"}), "git status").unwrap_err();
        assert!(error.starts_with("operation_kind_unknown:everything"), "{error}");
        assert!(error.contains("expected one of command, build, test, deploy"), "{error}");
    }
}
