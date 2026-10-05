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

pub fn transport(action:&str)->Result<Value,String>{
    if action=="preflight"{return attachment_preflight().map(|_|json!({"ok":true}));}
    if action=="status"{return Ok(STATUS.lock().map_err(|e|e.to_string())?.clone().unwrap_or(json!({"state":"stopped"})));}
    if action!="start"{return Err("binding_transport_action_invalid".into());}
    let mut started=STARTED.lock().map_err(|e|e.to_string())?;
    if *started{return Ok(json!({"ok":true,"state":"running","reused":true}));}
    attachment_preflight()?;
    let factory=FACTORY.get().cloned().ok_or("binding_runtime_unavailable")?;
    if read()?.is_none(){return Err("binding_not_configured".into());}
    // The SQLite exclusive lease is released by the OS. No PID/age based replacement.
    let lease=rusqlite::Connection::open(state_path().with_extension("transport.sqlite")).map_err(|e|e.to_string())?;
    lease.busy_timeout(Duration::ZERO).map_err(|e|e.to_string())?;
    lease.execute_batch("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE;").map_err(|_|"binding_transport_already_owned".to_string())?;
    *started=true;
    std::thread::Builder::new().name("wa-binding-transport".into()).spawn(move||{
        let _lease=lease;let lua=factory();
        loop{
            let result=lua.call_string("wa_binding_tick",&[]);
            let view=match result{Ok(text)=>serde_json::from_str(&text).unwrap_or(json!({"state":"unknown","error":"binding_tick_invalid"})),Err(e)=>json!({"state":"unknown","error":e})};
            if let Ok(mut status)=STATUS.lock(){*status=Some(view);}
            std::thread::sleep(Duration::from_secs(2));
        }
    }).map_err(|e|{*started=false;e.to_string()})?;
    Ok(json!({"ok":true,"state":"starting","note":"Transport receipt, not registration/attachment proof. Owned by this process until exit."}))
}
