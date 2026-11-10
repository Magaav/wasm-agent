//! Private atomic enrollment state and one outbound runtime. All enrollment policy is Lua.
use wa_host_support::lua::Lua;
use serde_json::{json,Value};
use std::path::PathBuf;
use std::sync::{Arc,Mutex,OnceLock,atomic::{AtomicBool,AtomicUsize,Ordering}};
use std::time::Duration;

static FACTORY:OnceLock<Arc<dyn Fn()->Lua+Send+Sync>>=OnceLock::new();
static STARTED:Mutex<bool>=Mutex::new(false);

/// Executes one relayed request: its JSON in, `(status, body)` out. The production value runs the
/// Lua `wa_binding_serve` in a fresh interpreter; the tests supply their own.
pub type Serve=Arc<dyn Fn(&Value)->(u16,String)+Send+Sync>;
/// Installs (`Some`) or clears (`None`) one relayed call's bound, cancel flag and owner on the thread
/// about to run it. `wa-capabilities` owns the mechanism; this crate only says when it applies.
pub type InstallContext=Arc<dyn Fn(Option<Arc<AtomicBool>>,Option<u64>,String)+Send+Sync>;
/// Posts one answer to `POST /relay/respond`, signed by this node.
pub type Respond=Arc<dyn Fn(&str,&str,&str,u16,&str)->Result<(),String>+Send+Sync>;

/// The worker lane: execution, the bound and the answer, all off the poll lane.
///
/// Polling never waits for a relayed call (measured 2026-11-10: one 60 s call detached the node and
/// every caller got `node_not_attached`). A request handed over here runs on its own thread and its
/// own interpreter; the poll lane goes straight back to polling, so the node stays attached for
/// everyone else. The number running at once is bounded, and a request over it is refused at once
/// with an answer the relay does not settle under the rid.
#[derive(Clone)]
pub struct RelayLane{
    pub serve:Serve,
    pub context:InstallContext,
    pub respond:Respond,
}

static LANE:OnceLock<RelayLane>=OnceLock::new();
/// Registered by the binary that owns both layers (`main.rs`): the lane's three pieces each live in a
/// different crate, and only that binary may name them all.
pub fn set_lane(lane:RelayLane){let _=LANE.set(lane);}
/// Relayed calls running right now.
static RELAY_RUNNING:AtomicUsize=AtomicUsize::new(0);

/// How many relayed calls run at once. Bounded on purpose: the poll lane pays for every one, and a
/// peer must not turn a node into its own worker pool. Beyond it: an explicit `relay_busy`.
fn relay_concurrency()->usize{
    std::env::var("WA_BINDING_RELAY_CONCURRENCY").ok().and_then(|v|v.parse::<usize>().ok())
        .map(|n|n.clamp(1,8)).unwrap_or(3)
}

/// The local cap for a request whose relay stamped no deadline (an older registry). It is the old exec
/// default, so the behaviour a caller already knew is kept, and a stuck call cannot hold a slot for
/// ever. It is named `local` in the log, never presented as the caller's own bound.
fn local_budget_ms()->u64{
    std::env::var("WASM_AGENT_RELAY_MAX_SECONDS").ok().and_then(|v|v.parse::<u64>().ok())
        .filter(|s|(1..=3600).contains(s)).unwrap_or(300)*1000
}

fn at()->String{crate::node::iso8601(crate::node::now_ms())}

impl RelayLane{
    /// Take one request from the poll lane. Hands over and returns: the caller is the loop that keeps
    /// the node attached, and it must never wait for work.
    pub fn dispatch(&self,dispatch:&Value){
        let service=dispatch["service"].as_str().unwrap_or_default().to_string();
        let node_id=dispatch["node_id"].as_str().unwrap_or_default().to_string();
        let request=dispatch["request"].clone();
        let rid=request["id"].as_str().unwrap_or_default().to_string();
        let method=request["method"].as_str().unwrap_or("POST").to_string();
        let path=request["path"].as_str().unwrap_or("/").to_string();
        if rid.is_empty()||node_id.is_empty()||service.is_empty(){
            eprintln!("[relay] dispatch refused node={node_id} at={} reason=incomplete envelope",at());
            return;
        }
        // The relay's number, or the local cap when it stamped none. `source` says which one the log
        // and the timeout answer are about.
        let (deadline_ms,budget_ms,source)=match request["deadline_ms"].as_u64(){
            Some(deadline)=>(deadline,request["budget_ms"].as_u64().unwrap_or(0),"relay"),
            None=>{let cap=local_budget_ms();(crate::node::now_ms()+cap,cap,"local")}
        };
        let limit=relay_concurrency();
        let running=RELAY_RUNNING.fetch_add(1,Ordering::SeqCst);
        if running>=limit{
            RELAY_RUNNING.fetch_sub(1,Ordering::SeqCst);
            // Explicit, immediate and *not started*: the relay erases the rid so the same request can
            // be sent again, and nothing has run twice.
            eprintln!("[relay] busy node={node_id} at={} rid={rid} reason=running {running}/{limit}",at());
            let body=json!({"error":"relay_busy","id":rid,"not_started":true,"running":running,"limit":limit,
                "retryable":true,"retry_after_ms":750,
                "hint":"the node is running its limit of relayed calls; nothing ran, so the same request may be retried"}).to_string();
            let respond=self.respond.clone();
            std::thread::spawn(move||{if let Err(error)=respond(&service,&node_id,&rid,503,&body){
                eprintln!("[relay] busy answer not delivered node={node_id} rid={rid}: {error}");}});
            return;
        }
        eprintln!("[relay] dispatch node={node_id} at={} rid={rid} {method} {path} budget_ms={budget_ms} source={source} running={}/{} ",at(),running+1,limit);
        let lane=self.clone();
        let thread_name=format!("wa-relay-{}",&rid[..rid.len().min(12)]);
        let bound_name=format!("wa-relay-bound-{}",&rid[..rid.len().min(12)]);
        let dispatch_failed=format!("[relay] dispatch failed node={node_id} at={} rid={rid}",at());
        let spawned=std::thread::Builder::new().name(thread_name).spawn(move||{
            let started=std::time::Instant::now();
            let cancel=Arc::new(AtomicBool::new(false));
            let answered=Arc::new(AtomicBool::new(false));
            let (done_tx,done_rx)=std::sync::mpsc::channel::<()>();
            // The bound is answered even if the call is stuck: the caller was told how long it waits,
            // and "no answer" is not one of the answers it was promised.
            {
                let cancel=cancel.clone();let answered=answered.clone();let respond=lane.respond.clone();
                let (service,node_id,rid)=(service.clone(),node_id.clone(),rid.clone());
                let log=format!("node={node_id}");
                std::thread::Builder::new().name(bound_name).spawn(move||{
                    let wait=deadline_ms.saturating_sub(crate::node::now_ms());
                    let reason=match done_rx.recv_timeout(Duration::from_millis(wait)){
                        // The call settled first: its own answer stands.
                        Ok(())=>return,
                        // The worker ended without answering (a panic in the lane): answer for it now
                        // rather than leaving the caller with silence.
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected)=>"worker ended without an answer",
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout)=>"bound passed",
                    };
                    if answered.swap(true,Ordering::SeqCst){return;}
                    // Stop the work, not only the answer: the flag is what a running `bash` and a
                    // silent provider read poll, so the operation is killed and the read is cut.
                    cancel.store(true,Ordering::SeqCst);
                    eprintln!("[relay] timeout {log} at={} rid={rid} budget_ms={budget_ms} source={source} reason={reason}",at());
                    let body=json!({"error":"relay_request_timeout","id":rid,"budget_ms":budget_ms,"bound":source,
                        "hint":"the call passed the deadline its caller was given; the work was stopped and no late result will be delivered"}).to_string();
                    if let Err(error)=respond(&service,&node_id,&rid,504,&body){
                        eprintln!("[relay] timeout answer not delivered node={node_id} rid={rid}: {error}");
                    }
                }).ok();
            }
            (lane.context)(Some(cancel.clone()),Some(deadline_ms),format!("relay:{rid}"));
            let answer=(lane.serve)(&request);
            (lane.context)(None,None,String::new());
            let elapsed=started.elapsed().as_millis() as u64;
            let _=done_tx.send(());
            RELAY_RUNNING.fetch_sub(1,Ordering::SeqCst);
            if answered.swap(true,Ordering::SeqCst){
                // The caller was already answered at the bound. This belongs to nobody: it is never
                // delivered as if it were fresh (`docs/RENDEZVOUS.md`, "Relay").
                eprintln!("[relay] late node={node_id} at={} rid={rid} status={} ms={elapsed} reason=answer after the bound, discarded",at(),answer.0);
                return;
            }
            eprintln!("[relay] done node={node_id} at={} rid={rid} status={} ms={elapsed}",at(),answer.0);
            if let Err(error)=(lane.respond)(&service,&node_id,&rid,answer.0,&answer.1){
                eprintln!("[relay] answer not delivered node={node_id} rid={rid}: {error}");
            }
        });
        if let Err(error)=spawned{
            RELAY_RUNNING.fetch_sub(1,Ordering::SeqCst);
            eprintln!("{dispatch_failed} reason={error}");
        }
    }
}

/// This process is the ledger's server (`wa serve`), so it is the one that should own the outbound
/// transport. Without this the CLI could not tell "no server" from "a server that has not attached yet":
/// it asked for `serve` whenever the run-lease was held, took the transport lease itself, exited, and
/// left the consent with no runtime - the state that made an operator stop a supervised node by hand
/// (measured 2026-11-01, nextcloud).
static SERVING:AtomicBool=AtomicBool::new(false);
static STATUS:Mutex<Option<Value>>=Mutex::new(None);
pub fn set_factory(factory:Arc<dyn Fn()->Lua+Send+Sync>){let _=FACTORY.set(factory);}
/// Called once by the process that is about to serve this ledger.
pub fn set_serving(){SERVING.store(true,Ordering::SeqCst);}
pub fn state_path()->PathBuf{PathBuf::from(wa_host_support::paths::resolve_home()).join(".wasm-agent/binding.json")}
pub fn present()->bool{state_path().exists()}
pub fn read()->Result<Option<Value>,String>{match std::fs::read(state_path()){
    Ok(bytes)=>serde_json::from_slice(&bytes).map(Some).map_err(|e|format!("binding_state_corrupt:{e}")),
    Err(e) if e.kind()==std::io::ErrorKind::NotFound=>Ok(None),Err(e)=>Err(format!("binding_state_unreadable:{e}"))}}
pub fn state(action:&str,args:&Value)->Result<Value,String>{
    if action=="read"{return Ok(json!({"ok":true,"state":read()?}));}
    if action!="cas"{return Err("binding_state_action_invalid".into());}
    let path=state_path();let dir=path.parent().unwrap();std::fs::create_dir_all(dir).map_err(|e|e.to_string())?;
    let lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join("binding.lock")).map_err(|e|e.to_string())?;
    lock.lock().map_err(|e|e.to_string())?;
    let old=read()?.unwrap_or(Value::Null);
    if args["expected"]!=old{return Err("binding_state_moved".into());}
    let new=args.get("state").filter(|v|v.is_object()).ok_or("binding_state_object_required")?;
    private_json(&path,new)?;
    Ok(json!({"ok":true,"state":new}))
}

fn private_json(path:&std::path::Path,value:&Value)->Result<(),String>{
    #[cfg(unix)] {
        use std::os::unix::fs::OpenOptionsExt;use std::io::Write;
        let temp=path.with_extension(format!("{}.tmp",std::process::id()));
        let mut file=std::fs::OpenOptions::new().create_new(true).write(true).mode(0o600).open(&temp).map_err(|e|e.to_string())?;
        let result=(||{file.write_all(serde_json::to_string(value)?.as_bytes())?;file.sync_all()?;std::fs::rename(&temp,path)?;
            std::fs::File::open(path.parent().unwrap())?.sync_all()?;Ok::<_,std::io::Error>(())})();
        if result.is_err(){let _=std::fs::remove_file(temp);}result.map_err(|e|e.to_string())
    }
    #[cfg(not(unix))] {wa_operation::atomic_json(path,value).map_err(|e|e.to_string())}
}

fn attachment_preflight()->Result<(),String>{
    // Do not add an outbound owner alongside an existing server of this ledger.
    // An actual exclusive lease, never file age/PID absence, decides it.
    let db=std::env::var("WASM_AGENT_DB").map_err(|_|"binding_database_identity_missing")?;
    let file=PathBuf::from(format!("{db}.run-lease.sqlite"));
    if file.exists(){let lease=rusqlite::Connection::open(file).map_err(|e|e.to_string())?;
        lease.busy_timeout(Duration::ZERO).map_err(|e|e.to_string())?;
        lease.execute_batch("BEGIN EXCLUSIVE; ROLLBACK;").map_err(|_|"binding_existing_server_owned; bind in its owner runtime or stop it explicitly".to_string())?;
    }
    Ok(())
}

/// Where a starting server asks the CLI that holds the transport to let go: `{pid, at}`. A request
/// older than `YIELD_STALE` is ignored, so a server that died while asking cannot park the CLI forever.
fn yield_path()->PathBuf{state_path().with_extension("transport.yield")}
const YIELD_STALE:u64=60;
fn now()->u64{std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d|d.as_secs()).unwrap_or(0)}
fn yield_requested()->bool{
    let Ok(bytes)=std::fs::read(yield_path()) else{return false};
    let at=serde_json::from_slice::<Value>(&bytes).ok().and_then(|v|v["at"].as_u64()).unwrap_or(0);
    now().saturating_sub(at)<YIELD_STALE
}
/// The per-home outbound lease (SQLite exclusive transaction, released by the OS with the process).
fn take_lease()->Result<rusqlite::Connection,String>{
    let lease=rusqlite::Connection::open(state_path().with_extension("transport.sqlite")).map_err(|e|e.to_string())?;
    lease.busy_timeout(Duration::ZERO).map_err(|e|e.to_string())?;
    lease.execute_batch("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE;").map_err(|_|"binding_transport_already_owned".to_string())?;
    Ok(lease)
}

/// One outbound owner per home, and the server is always the one that should be it.
///
/// `start` (a CLI) never refuses because someone else owns the transport: it takes the lease when it is
/// free and otherwise stands by, and while it holds the lease it lets go the moment a server asks
/// (`serve`). A standing-by CLI takes it back only when no server holds this ledger. Before this, the
/// two refused each other - a CLI would not start beside a node (`binding_existing_server_owned`), and a
/// node would not start beside a CLI (`binding_transport_already_owned`) - so every sentinel restart
/// failed while a terminal was open, and the agent wrote a script that killed the reader's CLI.
///
/// `serve` asks any CLI owner to yield and waits for the lease (up to `WA_BINDING_YIELD_WAIT`, 20 s).
pub fn transport(action:&str)->Result<Value,String>{
    if action=="preflight"{return attachment_preflight().map(|_|json!({"ok":true}));}
    if action=="status"{return Ok(STATUS.lock().map_err(|e|e.to_string())?.clone().unwrap_or(json!({"state":"stopped"})));}
    if action!="start" && action!="serve"{return Err("binding_transport_action_invalid".into());}
    let server=action=="serve"||SERVING.load(Ordering::SeqCst);
    let mut started=STARTED.lock().map_err(|e|e.to_string())?;
    if *started{return Ok(json!({"ok":true,"state":"running","reused":true}));}
    let factory=FACTORY.get().cloned().ok_or("binding_runtime_unavailable")?;
    if read()?.is_none(){return Err("binding_not_configured".into());}
    let lease=if server {
        let wait=std::env::var("WA_BINDING_YIELD_WAIT").ok().and_then(|v|v.parse().ok()).unwrap_or(20u64);
        let deadline=std::time::Instant::now()+Duration::from_secs(wait);
        let mut asked=false;
        let got=loop{
            match take_lease(){
                Ok(lease)=>break Some(lease),
                Err(error)=>{
                    if std::time::Instant::now()>=deadline{
                        if asked{let _=std::fs::remove_file(yield_path());}
                        return Err(format!("{error}: the owner did not yield within {wait}s"));
                    }
                    if !asked{
                        let _=std::fs::write(yield_path(),json!({"pid":std::process::id(),"at":now()}).to_string());
                        asked=true;
                    }
                    std::thread::sleep(Duration::from_millis(250));
                }
            }
        };
        if asked{let _=std::fs::remove_file(yield_path());}
        got
    } else if attachment_preflight().is_ok() && !yield_requested() { take_lease().ok() } else { None };
    *started=true;
    let state=if lease.is_some(){"starting"}else{"standby"};
    if let Ok(mut status)=STATUS.lock(){*status=Some(json!({"state":state,"owner":if lease.is_some(){"this process"}else{"another process"}}));}
    // The lease lives apart from the tick. A tick is network I/O and can block for as long as a peer
    // takes to answer; a yield checked between ticks then arrived after the starting node had given up
    // waiting, and the node stayed down behind an open CLI (28/10, every autostart for an hour).
    let lease=Arc::new(Mutex::new(lease));
    if !server {
        let held=lease.clone();
        std::thread::Builder::new().name("wa-binding-yield".into()).spawn(move||loop{
            if let Ok(mut lease)=held.lock(){
                // A server wants it: let go now; it takes the lease on its next try.
                if lease.is_some() && yield_requested(){
                    *lease=None;
                    if let Ok(mut status)=STATUS.lock(){*status=Some(json!({"state":"standby","owner":"the node","note":"yielded to the node that started"}));}
                }
                // Nobody serves this ledger any more (the node stopped or is restarting): take it back.
                if lease.is_none() && !yield_requested() && attachment_preflight().is_ok(){ *lease=take_lease().ok(); }
            }
            std::thread::sleep(Duration::from_millis(250));
        }).map_err(|e|e.to_string())?;
    }
    std::thread::Builder::new().name("wa-binding-transport".into()).spawn(move||{
        let lua=factory();
        // A failing tick used to be invisible: the view only reached `binding_transport('status')`, which a
        // later process cannot read (it is per-process), so a node that could not attach printed nothing and
        // the operator saw a healthy node with a bound registry and no reason (measured 2026-11-01).
        let mut reported:Option<String>=None;
        loop{
            let owned=lease.lock().map(|lease|lease.is_some()).unwrap_or(false);
            if owned{
                let result=lua.call_string("wa_binding_tick",&[]);
                let mut view=match result{Ok(text)=>serde_json::from_str(&text).unwrap_or(json!({"state":"unknown","error":"binding_tick_invalid"})),Err(e)=>json!({"state":"unknown","error":e})};
                let error=view.get("error").and_then(|v|v.as_str()).map(|s|s.to_string());
                if error!=reported{ if let Some(error)=&error{ eprintln!("binding_tick:{error}"); } reported=error; }
                // The request leaves this lane here: it is executed and answered on a worker thread,
                // and the next poll happens in two seconds whatever the call takes.
                if let Some(dispatch)=view.get("dispatch").cloned(){
                    if let Some(lane)=LANE.get(){ lane.dispatch(&dispatch); }
                    else{ eprintln!("binding_relay_lane_unavailable: a request arrived and no worker lane is registered"); }
                }
                if let Some(fields)=view.as_object_mut(){ fields.remove("dispatch"); }
                if let Ok(mut status)=STATUS.lock(){*status=Some(view);}
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    }).map_err(|e|{*started=false;e.to_string()})?;
    Ok(json!({"ok":true,"state":state,"note":"Transport receipt, not registration/attachment proof. A CLI stands by while a node owns it."}))
}

/// The production `Serve`: one fresh interpreter per admitted call, its `wa_binding_serve` global.
///
/// The interpreter is the same tree the poll lane runs (`lua/core/server.lua`), built by the factory
/// the binary registered. Admission, the answer's shape and the bound's wording stay in Lua
/// (`lua/core/binding.lua` `M.serve`); this only starts a thread and carries the bytes.
pub fn lua_serve(factory:Arc<dyn Fn()->Lua+Send+Sync>)->Serve{
    Arc::new(move |request:&Value|{
        let lua=factory();
        let raw=serde_json::to_string(request).unwrap_or_else(|_|"{}".into());
        match lua.call_string("wa_binding_serve",&[&raw]){
            Ok(text)=>match serde_json::from_str::<Value>(&text){
                Ok(view)=>{
                    let status=view["status"].as_u64().unwrap_or(500) as u16;
                    let body=view["body"].as_str().unwrap_or("{\"error\":\"binding_serve_invalid\"}").to_string();
                    (status,body)
                }
                Err(error)=>(500,json!({"error":"binding_serve_invalid","detail":error.to_string()}).to_string()),
            },
            Err(error)=>(500,json!({"error":"binding_serve_failed","detail":error}).to_string()),
        }
    })
}

/// The production `Respond`: this node's own signed `POST /relay/respond`, the same call the legacy
/// poller makes (`relay_client::respond`), so both transports answer in one shape.
pub fn relay_respond(service:&str,node_id:&str,rid:&str,status:u16,body:&str)->Result<(),String>{
    static IDENTITY:OnceLock<Result<crate::node::Identity,String>>=OnceLock::new();
    let identity=IDENTITY.get_or_init(crate::node::Identity::load).as_ref().map_err(|error|error.clone())?;
    if identity.node_id!=node_id{
        eprintln!("[relay] answer signed as {} for the binding of {node_id}",
            &identity.node_id[..identity.node_id.len().min(8)]);
    }
    crate::relay_client::respond(identity,service,rid,status,body)
}

#[cfg(test)]
mod lane_tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    /// One lane test at a time: the running count is process-wide.
    static LANE_LOCK:StdMutex<()>=StdMutex::new(());

    struct Recorder{
        answers:StdMutex<Vec<(String,u16,String)>>,
        contexts:StdMutex<Vec<(bool,Option<u64>,String)>>,
    }

    fn recorder()->Arc<Recorder>{
        Arc::new(Recorder{answers:StdMutex::new(Vec::new()),contexts:StdMutex::new(Vec::new())})
    }

    fn lane(record:Arc<Recorder>,serve:Serve)->RelayLane{
        let answers=record.clone();
        let contexts=record.clone();
        RelayLane{
            serve,
            context:Arc::new(move |cancel,deadline,owner|{
                contexts.contexts.lock().unwrap().push((cancel.is_some(),deadline,owner));
            }),
            respond:Arc::new(move |_service,_node,rid,status,body|{
                answers.answers.lock().unwrap().push((rid.to_string(),status,body.to_string()));
                Ok(())
            }),
        }
    }

    fn request(rid:&str,budget_ms:u64)->Value{
        json!({"id":rid,"method":"POST","path":"/node/call","headers":{},"body":"{}",
            "budget_ms":budget_ms,"deadline_ms":crate::node::now_ms()+budget_ms})
    }

    fn dispatch(rid:&str,budget_ms:u64)->Value{
        json!({"service":"http://127.0.0.1:1","node_id":"node-a","request":request(rid,budget_ms)})
    }

    fn await_answers(record:&Arc<Recorder>,count:usize){
        let deadline=std::time::Instant::now()+Duration::from_secs(10);
        while record.answers.lock().unwrap().len()<count{
            assert!(std::time::Instant::now()<deadline,"answers did not arrive: {}",record.answers.lock().unwrap().len());
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The whole defect in one measurement: a call that would run 120 s does not stop the poll lane,
    /// a second call is dispatched beside it, and both answers come back from the workers.
    #[test]
    fn a_120_second_call_does_not_stop_the_poll_lane(){
        let _lock=LANE_LOCK.lock().unwrap();
        RELAY_RUNNING.store(0,Ordering::SeqCst);
        let record=recorder();
        let (release_tx,release_rx)=std::sync::mpsc::channel::<()>();
        let gate=Arc::new(Mutex::new(release_rx));
        let serve:Serve={
            let gate=gate.clone();
            Arc::new(move |request:&Value|{
                let rid=request["id"].as_str().unwrap_or_default().to_string();
                if rid=="rid-slow"{
                    // Stands in for a 120 s relayed call: it is still running when everything below
                    // is asserted, and it only ends when the test releases it.
                    let gate=gate.lock().unwrap();
                    let _=gate.recv_timeout(Duration::from_secs(120));
                }
                (200,json!({"ok":true,"rid":rid}).to_string())
            })
        };
        let lane=lane(record.clone(),serve);
        let started=std::time::Instant::now();
        lane.dispatch(&dispatch("rid-slow",120_000));
        lane.dispatch(&dispatch("rid-status",120_000));
        assert!(started.elapsed()<Duration::from_secs(1),"dispatch must never wait for the call");
        assert_eq!(RELAY_RUNNING.load(Ordering::SeqCst),2,"both calls run at once");
        assert!(record.answers.lock().unwrap().is_empty(),"nothing answers before it settles");
        let _=release_tx.send(());
        let _=release_tx.send(());
        await_answers(&record,2);
        assert!(record.answers.lock().unwrap().iter().all(|(_,status,_)|*status==200));
        let contexts=record.contexts.lock().unwrap().clone();
        assert!(contexts.iter().filter(|(cancel,_,_)|*cancel).count()==2,"each call installed its bound");
        assert!(contexts.iter().filter(|(cancel,_,_)|!*cancel).count()==2,"and cleared it");
        assert!(contexts.iter().any(|(_,deadline,owner)|deadline.is_some()&&owner.starts_with("relay:")));
    }

    /// The caller was told how long it waits: at that bound the node answers a named timeout, exactly
    /// once, and the call's own (later) answer is discarded rather than delivered as fresh.
    #[test]
    fn the_bound_answers_a_named_timeout_and_discards_the_late_answer(){
        let _lock=LANE_LOCK.lock().unwrap();
        RELAY_RUNNING.store(0,Ordering::SeqCst);
        let record=recorder();
        let serve:Serve=Arc::new(|_request:&Value|{
            std::thread::sleep(Duration::from_millis(700));
            (200,"{\"ok\":true}".into())
        });
        let lane=lane(record.clone(),serve);
        lane.dispatch(&dispatch("rid-bound",150));
        await_answers(&record,1);
        let answers=record.answers.lock().unwrap().clone();
        assert_eq!(answers.len(),1,"one answer, at the bound");
        assert_eq!(answers[0].0,"rid-bound");
        assert_eq!(answers[0].1,504);
        assert!(answers[0].2.contains("relay_request_timeout"),"{}",answers[0].2);
        assert!(answers[0].2.contains("\"budget_ms\":150"),"{}",answers[0].2);
        // The call finishes 550 ms after the bound: its answer is not delivered.
        std::thread::sleep(Duration::from_millis(900));
        assert_eq!(record.answers.lock().unwrap().len(),1,"a late answer is never posted as fresh");
        assert_eq!(RELAY_RUNNING.load(Ordering::SeqCst),0,"the bound released the slot");
    }

    /// Over the limit: an immediate, explicit refusal that did not start anything.
    #[test]
    fn over_the_limit_the_answer_is_busy_and_not_started(){
        let _lock=LANE_LOCK.lock().unwrap();
        let limit=relay_concurrency();
        RELAY_RUNNING.store(limit,Ordering::SeqCst);
        let record=recorder();
        let served=Arc::new(AtomicUsize::new(0));
        let serve:Serve={let served=served.clone();Arc::new(move |_r:&Value|{(served.fetch_add(1,Ordering::SeqCst));(200,"{}".into())})};
        let lane=lane(record.clone(),serve);
        lane.dispatch(&dispatch("rid-over",60_000));
        await_answers(&record,1);
        let answers=record.answers.lock().unwrap().clone();
        assert_eq!(answers[0].1,503);
        assert!(answers[0].2.contains("relay_busy")&&answers[0].2.contains("\"not_started\":true"),"{}",answers[0].2);
        assert_eq!(served.load(Ordering::SeqCst),0,"nothing ran");
        RELAY_RUNNING.store(0,Ordering::SeqCst);
    }
}
