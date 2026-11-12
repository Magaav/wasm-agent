//! Code mode's guest protocol as a component (`docs/CODEMODE.md`, `docs/CORE-SPLIT.md`).
//!
//! It exports `wa:codemode` and imports one thing: `wa:kernel/quickjs`, the checksum-pinned QuickJS
//! sandbox the kernel hosts. A component cannot host wasmtime, so the sandbox is not inside this
//! crate — but its *protocol* is: which call may run, in what order, what the guest may discover,
//! what a refusal is named, and what the script's report says. That is the half that a swap can
//! change without touching the interpreter.
//!
//! The loop stays where the turn is. `open`/`advance`/`finish` are three answers to the Lua core,
//! which between them re-checks authority, validates the arguments against the live schema,
//! dispatches the tool, retains the original, writes the telemetry span and answers the two globals
//! that read the node (`showCall`, `capabilities`). A call this component hands out carries the
//! refusal when the fence already decided it — the loop delivers that and dispatches nothing.
//!
//! State: a script's loop state (its drained items, its queued calls, the ids it has seen) lives in
//! this instance's own memory, keyed by the session id the host names. The host keeps the instance
//! alive for exactly that session, so a script's state is as durable as the script and no longer.
use std::cell::RefCell;
use std::collections::{HashMap, HashSet, VecDeque};

use logic::{interpret, plan, Catalogue, Execution, Fact, Guest, ToolAdmittance};
use serde_json::{json, Map, Value};

wit_bindgen::generate!({ path: "../../../wit/codemode", world: "codemode-component", generate_all });

mod logic;

use crate::exports::wa::codemode::codemode::Guest as CodemodeGuest;
use crate::wa::codemode::types::{
    AnsweredCall, CallStep, Execution as WitExecution, GlobalStep, OpenRequest, Opened, Outcome,
    OutputItem, Progress, Refusal, Reply, Report, Step, StoreEntry, TargetRefusal, UnexecutedCall,
};
use crate::wa::kernel::quickjs::{self, Event, Failure};

/// One script's live state. Dropped when the loop calls `finish`.
struct Script {
    owner: String,
    sandbox: String,
    catalogue: Catalogue,
    /// The calls the guest has queued and nobody has admitted yet, in the order the guest made them.
    queued: VecDeque<quickjs::CallEvent>,
    /// What the guest printed or returned so far (`console.log`, `text(...)`).
    items: Vec<OutputItem>,
    /// The guest's terminal event, when it produced one.
    done: Option<quickjs::DoneEvent>,
    /// Every call id this script has handed out: a second delivery of one id is a protocol failure.
    seen: HashSet<u64>,
    /// The script's verdict, once its `done` has been turned into one.
    outcome: Option<Outcome>,
    /// The first named protocol failure this seam issued, kept so `finish` can still say why.
    aborted: Option<String>,
    sandbox_calls: u64,
    /// The globals this seam answered inside the guest, oldest first, in the order the guest made
    /// them. The loop journals one `attempt` per guest call (`lua/core/codemode.lua`), so a seam that
    /// answered in place without reporting it left the two paths disagreeing about which calls
    /// happened. Drained by every `Progress`.
    answered: Vec<AnsweredCall>,
}

thread_local! {
    static SCRIPTS: RefCell<HashMap<String, Script>> = RefCell::new(HashMap::new());
}

/// The component: no state of its own between calls; every script is a [`Script`].
struct CodemodeComponent;

fn execution(wit: WitExecution) -> Execution {
    Execution {
        status: wit.status,
        scope: wit.scope,
        binding: wit.workspace_binding,
        reason: wit.reason,
        detail: wit.detail,
        next: wit.next,
        available: wit.available,
        required: wit.required,
    }
}

fn failure_detail(failure: Failure) -> String {
    match failure {
        Failure::Refused(detail) | Failure::Failed(detail) => detail,
    }
}

fn output(event: quickjs::OutputEvent) -> OutputItem {
    OutputItem { text: event.text, console: event.console }
}

/// The prelude's tool list: what the guest's `tools` object is built from. Descriptions are bounded by
/// the node's own schema, and the guest never sees a name the fence refused.
fn tools_json(catalogue: &Catalogue) -> String {
    // The guest's ABI for a descriptor is the native loop's, field for field: `name` is the tool's own
    // name and `jsName` the identifier the guest's `tools` proxy exposes (`lua/core/codemode.lua`,
    // `descriptors[#descriptors+1]`). Sending the js name AS `name` and no `jsName` made the guest's
    // lookup compare `undefined`, so the same script failed on the component path with a different
    // TypeError than the native one - `scripts/test-codemode-component.lua` caught exactly that.
    let mut tools: Vec<Value> = catalogue
        .tools
        .iter()
        .map(|tool| json!({"name": tool.name, "jsName": tool.js_name, "description": tool.description}))
        .collect();
    // Every name the model can see outside is a member inside (11/11): a fenced tool answers with its
    // route when it is *called*, so reading it is never a TypeError that reads as "does not exist".
    // The native loop's guest has always had these; this side did not, and the parity suite - which now
    // runs this far - compared the two guests and said so.
    for outside in &catalogue.outside {
        tools.push(json!({
            "name": outside.name,
            "jsName": logic::js_name(&outside.name),
            "description": logic::schema_description(&outside.schema),
        }));
    }
    Value::Array(tools).to_string()
}

fn globals_json() -> String {
    let globals: Vec<Value> = logic::GUEST_GLOBALS
        .iter()
        .map(|(name, spread)| json!({"name": name, "spread": spread}))
        .collect();
    Value::Array(globals).to_string()
}

fn store_json(entries: &[StoreEntry]) -> String {
    let mut store = Map::new();
    for entry in entries {
        if let Some(value) = &entry.value {
            store.insert(entry.key.clone(), Value::String(value.clone()));
        }
    }
    Value::Object(store).to_string()
}

impl Script {
    /// One drained batch of guest events: items accumulate, calls queue, `done` is recorded. An event
    /// this seam does not know is the one protocol failure that is never ignored.
    fn consume(&mut self, events: Vec<Event>) -> Result<(), String> {
        for event in events {
            match event {
                Event::Call(call) => self.queued.push_back(call),
                Event::Output(item) => self.items.push(output(item)),
                Event::Done(done) => self.done = Some(done),
            }
        }
        Ok(())
    }

    fn take_items(&mut self) -> Vec<OutputItem> {
        std::mem::take(&mut self.items)
    }

    /// The journal rows this seam owes the loop for the globals it answered in place, oldest first.
    fn take_answered(&mut self) -> Vec<AnsweredCall> {
        std::mem::take(&mut self.answered)
    }

    /// One `Progress`: what the script printed, the in-place answers the loop has not been told about,
    /// and the step it must act on. Every return from [`advance_script`] goes through here, so no
    /// journal row can be dropped on an early return (an abort is a step too).
    fn emit(&mut self, step: Step) -> Progress {
        Progress { items: self.take_items(), answered: self.take_answered(), step }
    }

    fn sandbox_call(&mut self) {
        self.sandbox_calls += 1;
    }

    /// The verdict a finished script leaves: its own return value and the store writes it asked for.
    fn finish_outcome(&mut self) -> Outcome {
        if let Some(outcome) = &self.outcome {
            return outcome.clone();
        }
        let done = self.done.take();
        let outcome = match done {
            Some(done) => {
                let writes = match done.writes.as_deref() {
                    None | Some("undefined") => Ok(Vec::new()),
                    Some(raw) => store_writes(raw),
                };
                match writes {
                    // A failed script's error is the guest's own message; the sandbox reports it as the
                    // terminal event's `value` when `ok` is false (the prelude sends both through one
                    // field), so the loop reads it there.
                    // A failed script's error is the guest's own message. It arrives in `error` now (the
                    // seam's record carries it), and in `value` from a host built before that field
                    // existed - the two hold the same text, so either answers the model. `value` is the
                    // script's VALUE and a failed script has none: the legacy spelling must not leak
                    // into it, or the same script would answer `{ok: false, value: <error>}` here and
                    // `{ok: false}` natively.
                    Ok(writes) => Outcome {
                        ok: done.ok,
                        value: if done.ok { done.value.clone() } else { None },
                        error: if done.ok { None } else { done.error.clone().or(done.value.clone()) },
                        writes,
                    },
                    Err(reason) => {
                        self.aborted = Some(reason);
                        Outcome { ok: false, value: None, error: Some("codemode_store_protocol_invalid".into()), writes: Vec::new() }
                    }
                }
            }
            None => Outcome { ok: false, value: None, error: None, writes: Vec::new() },
        };
        self.outcome = Some(outcome.clone());
        outcome
    }

    /// The calls the script left queued, with the reason the native path gives them.
    fn unexecuted(&self, reason: &str) -> Vec<UnexecutedCall> {
        self.queued
            .iter()
            .map(|call| UnexecutedCall { id: call.id, name: call.name.clone(), reason: reason.to_string() })
            .collect()
    }
}

/// The guest's `store` writes: an array of `[key, value]` pairs, `value: null` deleting a key. A shape
/// this seam does not recognise is `codemode_store_protocol_invalid`, exactly as the native path says.
fn store_writes(raw: &str) -> Result<Vec<StoreEntry>, String> {
    let entries: Vec<Value> = serde_json::from_str(raw).map_err(|_| "codemode_store_protocol_invalid".to_string())?;
    let mut writes = Vec::new();
    for entry in entries {
        let pair = entry.as_array().filter(|pair| pair.len() == 2).ok_or_else(|| "codemode_store_protocol_invalid".to_string())?;
        let key = pair[0].as_str().ok_or_else(|| "codemode_store_protocol_invalid".to_string())?.to_string();
        let value = match &pair[1] {
            Value::Null => None,
            Value::String(text) => Some(text.clone()),
            _ => return Err("codemode_store_protocol_invalid".to_string()),
        };
        writes.push(StoreEntry { key, value });
    }
    Ok(writes)
}

fn refusal(target: &logic::ToolCall) -> Option<Refusal> {
    match &target.admittance {
        ToolAdmittance::Dispatch => None,
        ToolAdmittance::Fenced(route) => Some(Refusal::TargetNotAvailable(TargetRefusal {
            name: target.name.clone(),
            route: route.clone(),
        })),
    }
}

impl CodemodeGuest for CodemodeComponent {
    fn open(request: OpenRequest) -> Opened {
        let facts: Vec<Fact> = request
            .catalogue
            .into_iter()
            .map(|tool| Fact {
                name: tool.name,
                description: tool.description,
                schema: serde_json::from_str(&tool.schema_json).unwrap_or(Value::Null),
                execution: execution(tool.execution),
            })
            .collect();
        let Some(catalogue) = plan(facts) else {
            // Two tools spell the same name inside the guest: refuse rather than let one shadow the
            // other. The native path returns the same name.
            return Opened {
                session: None,
                items: Vec::new(),
                backend: None,
                sandbox_failure: None,
                unexecuted: Vec::new(),
                aborted: Some("codemode_identifier_collision".to_string()),
            };
        };
        let started = quickjs::start(&quickjs::Spec {
            owner: request.owner.clone(),
            code: request.code,
            timeout_ms: request.timeout_ms,
            tools_json: tools_json(&catalogue),
            globals_json: globals_json(),
            store_json: store_json(&request.store),
            wasm_path: request.wasm_path,
            prelude_path: request.prelude_path,
            module_cache: request.module_cache,
        });
        let mut script = Script {
            owner: request.owner,
            sandbox: started.id.clone().unwrap_or_default(),
            catalogue,
            queued: VecDeque::new(),
            items: Vec::new(),
            done: None,
            seen: HashSet::new(),
            outcome: None,
            aborted: None,
            sandbox_calls: 1,
            answered: Vec::new(),
        };
        let _ = script.consume(started.events);
        let backend = if started.backend.is_empty() { None } else { Some(started.backend.clone()) };
        let Some(_sandbox) = started.id else {
            // The guest never ran. Keep whatever it printed and name the calls it never admitted.
            return Opened {
                session: None,
                items: script.take_items(),
                backend,
                sandbox_failure: started.failure,
                unexecuted: script.unexecuted("sandbox_failed_before_admission"),
                aborted: None,
            };
        };
        let items = script.take_items();
        let session = request.session;
        SCRIPTS.with(|scripts| scripts.borrow_mut().insert(session.clone(), script));
        Opened { session: Some(session), items, backend, sandbox_failure: None, unexecuted: Vec::new(), aborted: None }
    }

    fn advance(session: String, reply: Option<Reply>) -> Progress {
        let Some(mut script) = SCRIPTS.with(|scripts| scripts.borrow_mut().remove(&session)) else {
            return Progress {
                items: Vec::new(),
                answered: Vec::new(),
                step: Step::Aborted("codemode_session_unknown".to_string()),
            };
        };
        let progress = advance_script(&mut script, reply);
        SCRIPTS.with(|scripts| scripts.borrow_mut().insert(session, script));
        progress
    }

    fn finish(session: String) -> Report {
        let Some(mut script) = SCRIPTS.with(|scripts| scripts.borrow_mut().remove(&session)) else {
            return Report {
                items: Vec::new(),
                unexecuted: Vec::new(),
                outcome: None,
                aborted: Some("codemode_session_unknown".to_string()),
                close_failure: None,
                sandbox_calls: 0,
            };
        };
        let closed = quickjs::close(&script.sandbox, &script.owner);
        script.sandbox_call();
        let close_failure = closed.err().map(failure_detail);
        // The script's own verdict is only reached here when the loop stopped early (a raised error, a
        // cancellation): a script that finished already produced it at `advance`.
        let outcome = match &script.outcome {
            Some(outcome) => Some(outcome.clone()),
            None => None,
        };
        Report {
            items: script.take_items(),
            unexecuted: script.unexecuted("script_finished_before_admission"),
            outcome,
            aborted: script.aborted.clone(),
            close_failure,
            sandbox_calls: script.sandbox_calls,
        }
    }
}

/// The loop's body, one step at a time: deliver what the loop answered, then admit and hand out the
/// next call. The order is the native loop's — deliver, drain, check `done`, admit, take the next call
/// — so a cancelled or expired run stops at the same point on both paths.
fn advance_script(script: &mut Script, reply: Option<Reply>) -> Progress {
    if let Some(reply) = reply {
        let delivered = quickjs::deliver(
            &script.sandbox,
            &script.owner,
            reply.call_id,
            reply.ok,
            &reply.payload_json,
        );
        script.sandbox_call();
        if script.consume(delivered.events).is_err() {
            script.aborted = Some("codemode_protocol_unknown_event".to_string());
            return script.emit(Step::Aborted("codemode_protocol_unknown_event".to_string()));
        }
        if let Some(failure) = delivered.failure {
            script.aborted = Some(failure.clone());
            return script.emit(Step::Aborted(failure));
        }
    }
    loop {
        if script.done.is_some() {
            let outcome = script.finish_outcome();
            return script.emit(Step::Finished(outcome));
        }
        // A loop that asks again after the script finished gets the same answer rather than a stall:
        // the verdict is already known and asking twice is not a protocol error.
        if let Some(outcome) = script.outcome.clone() {
            return script.emit(Step::Finished(outcome));
        }
        if let Err(failure) = quickjs::admit(&script.sandbox, &script.owner) {
            script.sandbox_call();
            let detail = failure_detail(failure);
            script.aborted = Some(detail.clone());
            return script.emit(Step::Aborted(detail));
        }
        script.sandbox_call();
        let Some(call) = script.queued.pop_front() else {
            // The guest stopped without a `done` and nothing is queued: the script can never finish.
            script.aborted = Some("codemode_stalled".to_string());
            return script.emit(Step::Aborted("codemode_stalled".to_string()));
        };
        if !script.seen.insert(call.id) {
            script.aborted = Some("codemode_duplicate_call".to_string());
            return script.emit(Step::Aborted("codemode_duplicate_call".to_string()));
        }
        match interpret(&script.catalogue, &call.target, &call.name, call.args_json.as_deref()) {
            Guest::Tool(target) => {
                let step = Step::Call(CallStep {
                    id: call.id,
                    target: call.target.clone(),
                    name: call.name.clone(),
                    args_json: target.args.clone(),
                    refusal: refusal(&target),
                });
                return script.emit(step);
            }
            Guest::Host => {
                let step = Step::HostGlobal(GlobalStep {
                    id: call.id,
                    name: call.name.clone(),
                    args_json: call.args_json.clone(),
                });
                return script.emit(step);
            }
            Guest::Answered(value, ok) => {
                // The seam's own answer, handed back to the guest at once (the native loop answers these
                // in place too) - and reported to the loop in this `Progress`, because the journal is the
                // loop's: the native loop writes one `attempt` per guest call, `searchTools` included, and
                // a seam that answered silently left the two records disagreeing about which calls ran.
                script.answered.push(AnsweredCall {
                    id: call.id,
                    name: call.name.clone(),
                    ok,
                    args_json: call.args_json.clone(),
                    result_json: value.to_string(),
                });
                let delivered = quickjs::deliver(&script.sandbox, &script.owner, call.id, ok, &value.to_string());
                script.sandbox_call();
                if script.consume(delivered.events).is_err() {
                    script.aborted = Some("codemode_protocol_unknown_event".to_string());
                    return script.emit(Step::Aborted("codemode_protocol_unknown_event".to_string()));
                }
                if let Some(failure) = delivered.failure {
                    script.aborted = Some(failure.clone());
                    return script.emit(Step::Aborted(failure));
                }
            }
        }
    }
}

export!(CodemodeComponent);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_guest_sees_every_name_the_model_can_and_the_globals_the_native_loop_gives_it() {
        let catalogue = plan(vec![
            Fact {
                name: "read".into(),
                description: "Read a file".into(),
                schema: json!({"type":"function","function":{"name":"read","parameters":{}}}),
                execution: Execution { status: "not_blocked".into(), ..Execution::default() },
            },
            Fact {
                name: "subagent".into(),
                description: "Delegate".into(),
                schema: json!({"type":"function","function":{"name":"subagent","parameters":{}}}),
                execution: Execution { status: "not_blocked".into(), ..Execution::default() },
            },
        ])
        .expect("no collision");
        let tools: Value = serde_json::from_str(&tools_json(&catalogue)).unwrap();
        // Every name the model can see outside is a member inside, exactly as the native loop's guest
        // has it: a fenced tool answers with its route when it is CALLED, so reading it is not a
        // TypeError that reads as "does not exist". The two guests diverged here and the parity suite
        // (which now runs past its old skip) compared them field for field.
        assert_eq!(tools.as_array().unwrap().len(), 2, "the fence is a member inside, as it is natively: {tools}");
        assert_eq!(tools[1]["name"], "subagent");
        assert_eq!(tools[1]["jsName"], "subagent");
        // The descriptor is the native loop's ABI: the tool's own name AND the js identifier the guest
        // proxy exposes. Sending the js name as `name` and no `jsName` made the guest compare `undefined`,
        // so one script failed differently here than natively (caught by the parity suite).
        assert_eq!(tools[0]["name"], "read");
        assert_eq!(tools[0]["jsName"], "read");
        let globals: Value = serde_json::from_str(&globals_json()).unwrap();
        assert_eq!(globals.as_array().unwrap().len(), 6, "the native loop's six globals, name for name");
        assert_eq!(globals[0], json!({"name": "searchTools", "spread": true}));
        assert_eq!(globals[1], json!({"name": "results", "spread": true}), "the retained results and the session journal");
        assert_eq!(globals[2], json!({"name": "describeTool", "spread": false}));
        assert_eq!(globals[3], json!({"name": "showCall", "spread": false}));
        assert_eq!(globals[4], json!({"name": "capabilities", "spread": false}));
        assert_eq!(globals[5], json!({"name": "describe", "spread": false}));
    }

    #[test]
    fn the_store_round_trips_and_a_bad_shape_is_the_named_refusal() {
        let store: Value = serde_json::from_str(&store_json(&[StoreEntry { key: "a".into(), value: Some("1".into()) }])).unwrap();
        assert_eq!(store["a"], "1");
        assert_eq!(store_writes("[[\"a\",\"1\"],[\"b\",null]]").unwrap().len(), 2);
        assert_eq!(store_writes("[[\"a\",1]]").unwrap_err(), "codemode_store_protocol_invalid");
        assert_eq!(store_writes("{\"a\":1}").unwrap_err(), "codemode_store_protocol_invalid");
        assert_eq!(store_writes("[[\"a\"]]").unwrap_err(), "codemode_store_protocol_invalid");
    }
}
