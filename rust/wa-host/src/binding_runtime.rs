//! Private atomic enrollment state and one outbound runtime. All enrollment policy is Lua.
use crate::lua::Lua;
use serde_json::{json,Value};
use std::path::PathBuf;
use std::sync::{Arc,Mutex,OnceLock};
use std::time::Duration;

static FACTORY:OnceLock<Arc<dyn Fn()->Lua+Send+Sync>>=OnceLock::new();
static STARTED:Mutex<bool>=Mutex::new(false);
static STATUS:Mutex<Option<Value>>=Mutex::new(None);
pub fn set_factory(factory:Arc<dyn Fn()->Lua+Send+Sync>){let _=FACTORY.set(factory);}
pub fn state_path()->PathBuf{PathBuf::from(crate::resolve_home()).join(".wasm-agent/binding.json")}
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
    let server=action=="serve";
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
    std::thread::Builder::new().name("wa-binding-transport".into()).spawn(move||{
        let mut lease=lease;let lua=factory();
        loop{
            if !server {
                // A server wants it: let go now, the next server tick takes over.
                if lease.is_some() && yield_requested(){
                    lease=None;
                    if let Ok(mut status)=STATUS.lock(){*status=Some(json!({"state":"standby","owner":"the node","note":"yielded to the node that started"}));}
                }
                // Nobody serves this ledger any more (the node stopped or is restarting): take it back.
                if lease.is_none() && !yield_requested() && attachment_preflight().is_ok(){ lease=take_lease().ok(); }
            }
            if lease.is_some(){
                let result=lua.call_string("wa_binding_tick",&[]);
                let view=match result{Ok(text)=>serde_json::from_str(&text).unwrap_or(json!({"state":"unknown","error":"binding_tick_invalid"})),Err(e)=>json!({"state":"unknown","error":e})};
                if let Ok(mut status)=STATUS.lock(){*status=Some(view);}
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    }).map_err(|e|{*started=false;e.to_string()})?;
    Ok(json!({"ok":true,"state":state,"note":"Transport receipt, not registration/attachment proof. A CLI stands by while a node owns it."}))
}
