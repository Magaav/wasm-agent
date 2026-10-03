//! Durable exclusive claims. Lua chooses resource names and policy; this module
//! supplies atomic ownership, process liveness and compare-and-release primitives.
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::Duration,
};

struct State {
    db: Connection,
    live: HashSet<String>,
    _lease: Connection,
    targets: HashMap<String, HeldTarget>,
}
struct HeldTarget {
    receipt: Value,
    _lease: Connection,
}
// A successful session claim is the existing trusted Lua resource admission.
// Target callers cannot create this context by passing identity/receipt fields.
thread_local! {
    static OWNER: std::cell::RefCell<Option<Value>> = const { std::cell::RefCell::new(None) };
}
pub struct Store {
    root: PathBuf,
    boot: String,
    state: Mutex<State>,
}
type Result<T> = std::result::Result<T, String>;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn field<'a>(value: &'a Value, key: &str) -> Result<&'a str> {
    value[key]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("{key}_required"))
}
fn valid_boot(boot: &str) -> bool {
    boot.len() == 36 && boot.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}
fn target_scope(args: &Value) -> Result<(Value, String)> {
    let common = std::fs::canonicalize(field(args, "git_common_dir")?).map_err(err)?;
    if !common.is_dir() { return Err("target_directory_required".into()); }
    let reference = field(args, "ref")?;
    // An exact full ref, never a Git revision expression or a wildcard.
    if !reference.starts_with("refs/") || reference.ends_with('/') || reference.ends_with('.')
        || reference.contains("..") || reference.contains("@{") || reference.contains("//")
        || reference.split('/').any(|part| part.starts_with('.') || part.ends_with(".lock"))
        || reference.bytes().any(|b| b <= b' ' || b == 127 || b"~^:?*[\\".contains(&b)) {
        return Err("invalid_target_ref".into());
    }
    let mut common = common.to_string_lossy().replace('\\', "/");
    #[cfg(windows)] { common = common.to_lowercase(); }
    let scope = json!({"git_common_dir":common,"ref":reference});
    // Refs can alias by Windows case or Git symbolic-ref indirection. Exclude
    // the entire canonical common directory instead of guessing lexical ref
    // equality. Retain the requested exact ref in the checked receipt.
    let digest = ring::digest::digest(&ring::digest::SHA256, scope["git_common_dir"].to_string().as_bytes());
    let key = format!("target:{}", digest.as_ref().iter().map(|b| format!("{b:02x}")).collect::<String>());
    Ok((scope,key))
}

fn creation_stamp() -> Result<String> {
    #[cfg(windows)] {
        use windows_sys::Win32::{Foundation::FILETIME, System::Threading::{GetCurrentProcess, GetProcessTimes}};
        let mut creation: FILETIME = unsafe { std::mem::zeroed() };
        let mut exit = creation;
        let mut kernel = creation;
        let mut user = creation;
        if unsafe { GetProcessTimes(GetCurrentProcess(), &mut creation, &mut exit, &mut kernel, &mut user) } == 0 {
            return Err(err(std::io::Error::last_os_error()));
        }
        Ok(format!("windows-filetime:{}", ((creation.dwHighDateTime as u64) << 32) | creation.dwLowDateTime as u64))
    }
    #[cfg(target_os="linux")] {
        let stat = std::fs::read_to_string(format!("/proc/{}/stat", std::process::id())).map_err(err)?;
        let ticks = stat.rsplit_once(')').and_then(|(_, rest)| rest.split_whitespace().nth(19)).ok_or("process_creation_unverifiable")?;
        let boot = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").map_err(err)?;
        Ok(format!("linux:{}:{ticks}", boot.trim()))
    }
    #[cfg(not(any(windows, target_os="linux")))] {
        Err("process_creation_unavailable".into())
    }
}

fn child_observation(pid: u32) -> Result<Value> {
    #[cfg(windows)] {
        use windows_sys::Win32::{Foundation::{CloseHandle, FILETIME}, System::Threading::{OpenProcess, GetProcessTimes, WaitForSingleObject, PROCESS_QUERY_LIMITED_INFORMATION}};
        #[repr(C)]
        struct Basic { reserved: *mut std::ffi::c_void, peb: *mut std::ffi::c_void, reserved2: [*mut std::ffi::c_void;2], unique_pid: usize, parent_pid: usize }
        #[link(name="ntdll")]
        extern "system" { fn NtQueryInformationProcess(handle: *mut std::ffi::c_void, class: u32, info: *mut std::ffi::c_void, size: u32, returned: *mut u32) -> i32; }
        let handle=unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | 0x00100000,0,pid) };
        if handle.is_null() { return Err("child_creation_unverifiable".into()); }
        let mut basic: Basic=unsafe { std::mem::zeroed() };
        let mut creation: FILETIME=unsafe { std::mem::zeroed() };let mut exit=creation;let mut kernel=creation;let mut user=creation;
        let times=unsafe { GetProcessTimes(handle,&mut creation,&mut exit,&mut kernel,&mut user) };
        let status=unsafe { NtQueryInformationProcess(handle,0,(&mut basic as *mut Basic).cast(),std::mem::size_of::<Basic>() as u32,std::ptr::null_mut()) };
        let live=unsafe { WaitForSingleObject(handle,0) };unsafe { CloseHandle(handle) };
        if times==0 || status!=0 || live!=0x102 || basic.unique_pid!=pid as usize { return Err("child_creation_unverifiable".into()); }
        if basic.parent_pid!=std::process::id() as usize { return Err("child_not_this_native_parent".into()); }
        Ok(json!({"process_id":pid,"parent_process_id":std::process::id(),"creation_stamp":format!("windows-filetime:{}",((creation.dwHighDateTime as u64)<<32)|creation.dwLowDateTime as u64),"parent_creation_stamp":creation_stamp()?}))
    }
    #[cfg(target_os="linux")] {
        let stat=std::fs::read_to_string(format!("/proc/{pid}/stat")).map_err(err)?;
        let fields=stat.rsplit_once(')').ok_or("child_creation_unverifiable")?.1.split_whitespace().collect::<Vec<_>>();
        if fields.get(1).and_then(|s|s.parse::<u32>().ok())!=Some(std::process::id()) || fields.first()==Some(&"Z") { return Err("child_not_this_native_parent".into()); }
        let stamp=format!("linux:{}:{}",std::fs::read_to_string("/proc/sys/kernel/random/boot_id").map_err(err)?.trim(),fields.get(19).ok_or("child_creation_unverifiable")?);
        Ok(json!({"process_id":pid,"parent_process_id":std::process::id(),"creation_stamp":stamp,"parent_creation_stamp":creation_stamp()?}))
    }
    #[cfg(not(any(windows,target_os="linux")))] { let _=pid;Err("child_creation_unavailable".into()) }
}

impl Store {
    fn owner(&self, state: &State) -> Result<Value> {
        let owner = OWNER.with(|slot| slot.borrow().clone()).ok_or("resource_context_required")?;
        if owner["boot"] != self.boot { return Err("resource_context_foreign_boot".into()); }
        let claim = state.db.query_row("SELECT key,principal,session,run,boot,uncertain FROM claims WHERE key=?",
            [format!("session:{}", field(&owner,"session")?)], row).optional().map_err(err)?.ok_or("resource_context_missing")?;
        if ["principal","session","run","boot"].iter().any(|key| owner[key] != claim[key]) {
            return Err("resource_owner_changed".into());
        }
        let raw: Option<String> = state.db.query_row("SELECT identity FROM claim_identity WHERE key=? AND boot=?",
            params![claim["key"].as_str().unwrap(),self.boot], |r| r.get(0)).optional().map_err(err)?;
        let identity = raw.and_then(|raw| serde_json::from_str::<Value>(&raw).ok()).ok_or("resource_context_identity_missing")?;
        if field(&owner,"claim_id")? != field(&identity,"claim_id")? {
            return Err("resource_context_generation_changed".into());
        }
        if claim["uncertain"] == true || !state.live.contains(field(&owner,"run")?) {
            return Err("resource_owner_uncertain_or_inactive".into());
        }
        Ok(owner)
    }

    fn target_inventory(&self, db: &Connection, scope: &Value, owner: &Value, held: Option<&Value>) -> Result<Value> {
        let mut inventory = self.inventory(db)?;
        // Revalidate the registered generation inside this very snapshot, not
        // just the context lookup before acquiring the database transaction.
        let registered = inventory["claims"].as_array().ok_or("resource_inventory_incomplete")?.iter()
            .find(|claim| claim["key"] == format!("session:{}",owner["session"].as_str().unwrap_or("")))
            .ok_or("resource_context_missing")?;
        if ["principal","session","run","boot"].iter().any(|name| registered[name] != owner[name]) {
            return Err("resource_owner_changed".into());
        }
        if registered["identity"]["claim_id"] != owner["claim_id"] {
            return Err("resource_context_generation_changed".into());
        }
        let mut conflicts = Vec::new();
        for claim in inventory["claims"].as_array().ok_or("resource_inventory_incomplete")? {
            let identity = &claim["identity"];
            let own = ["principal","session","run","boot"].iter().all(|key| claim[key] == owner[key]);
            let retained = own && held.is_some_and(|receipt| {
                let mut expected = receipt.clone(); expected["kind"] = json!("target");
                receipt["key"] == claim["key"] && receipt["session_claim_id"] == owner["claim_id"] && *identity == expected
            });
            let reason = if claim["identity_complete"] != true { Some("owner_identity_missing") }
                else if claim["uncertain"] == true { Some("owner_uncertain") }
                else if claim["liveness"] == "unverifiable" { Some("owner_liveness_unverifiable") }
                else if identity["kind"] == "session" { None }
                else if identity["kind"] != "target" || identity["scope"].is_null() { Some("target_scope_unknown") }
                else if identity["scope"]["git_common_dir"] == scope["git_common_dir"] && !retained { Some("target_owned") }
                else { None };
            if let Some(reason) = reason { conflicts.push(json!({"reason":reason,"claim":claim})); }
        }
        inventory["kind"] = json!("target-resource-inventory");
        inventory["scope"] = scope.clone();
        inventory["conflicts"] = json!(conflicts);
        inventory["admissible"] = json!(inventory["complete"] == true && inventory["identities_complete"] == true && conflicts.is_empty());
        Ok(inventory)
    }

    fn target_control(&self, state: &mut State, action: &str, args: &Value) -> Result<Value> {
        // Identity is read from successful resource admission on this native thread.
        // Even a byte-identical exported receipt never creates a held capability.
        for key in ["principal","session","run","boot","process_id","creation_stamp","owner"] {
            if !args[key].is_null() { return Err("target_caller_identity_forbidden".into()); }
        }
        let fields = args.as_object().ok_or("target_arguments_required")?;
        if fields.keys().any(|key| !matches!(key.as_str(), "git_common_dir" | "ref" | "receipt" | "evidence") && !(action=="target_child_observe" && key=="child_process_id")) {
            return Err("target_unknown_or_partial_query_argument".into());
        }
        if action == "target_inspect" && (!args["receipt"].is_null() || !args["evidence"].is_null()) {
            return Err("target_inspection_arguments_invalid".into());
        }
        let owner = self.owner(state)?;
        let (scope,key) = target_scope(args)?;
        if action == "target_inspect" {
            let tx = state.db.transaction().map_err(err)?;
            let held = state.targets.get(&key).map(|held| &held.receipt);
            let inventory = self.target_inventory(&tx,&scope,&owner,held)?;
            tx.commit().map_err(err)?;
            return Ok(inventory);
        }
        if action == "target_hold" {
            if state.targets.contains_key(&key) { return Err("target_already_held".into()); }
            if !args["receipt"].is_null() { return Err("target_caller_receipt_forbidden".into()); }
            let lease = Connection::open(self.root.join(format!("target-{}.lease.sqlite", &key[7..]))).map_err(err)?;
            lease.busy_timeout(Duration::ZERO).map_err(err)?;
            lease.execute_batch("BEGIN EXCLUSIVE").map_err(|_| "target_lease_held_or_unavailable".to_string())?;
            let tx = state.db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(err)?;
            let inventory = self.target_inventory(&tx,&scope,&owner,None)?;
            if inventory["admissible"] != true {
                return Ok(json!({"ok":false,"error":"target_conflicts_or_incomplete","inventory":inventory}));
            }
            let receipt = json!({"schema":1,"kind":"held-target-resource","key":key,
                "exclusion_scope":"git-common-directory",
                "receipt_id":crate::host::new_uuid(),"principal":owner["principal"],"session":owner["session"],
                "run":owner["run"],"boot":self.boot,"session_claim_id":owner["claim_id"],"process_id":std::process::id(),
                "creation_stamp":creation_stamp()?,"scope":scope});
            tx.execute("INSERT INTO claims(key,principal,session,run,boot) VALUES(?,?,?,?,?)",
                params![key,field(&owner,"principal")?,field(&owner,"session")?,field(&owner,"run")?,self.boot]).map_err(err)?;
            let mut identity = receipt.clone();
            identity["kind"] = json!("target");
            tx.execute("INSERT OR REPLACE INTO claim_identity VALUES(?,?,?)", params![key,self.boot,identity.to_string()]).map_err(err)?;
            tx.execute("INSERT INTO history(action,evidence,claim) VALUES('target_hold','native OS-held reservation',?)", [receipt.to_string()]).map_err(err)?;
            tx.commit().map_err(err)?;
            state.targets.insert(key, HeldTarget { receipt:receipt.clone(), _lease:lease });
            return Ok(json!({"ok":true,"receipt":receipt,"inventory":inventory}));
        }
        if !matches!(action,"target_check" | "target_release" | "target_child_observe") { return Err("unknown_resource_action".into()); }
        let held = state.targets.get(&key).ok_or("target_not_held")?;
        if held.receipt != args["receipt"] || held.receipt["scope"] != scope
            || held.receipt["session_claim_id"] != owner["claim_id"]
            || ["principal","session","run","boot"].iter().any(|name| held.receipt[name] != owner[name]) {
            return Err("target_receipt_or_owner_changed".into());
        }
        let receipt = held.receipt.clone();
        let tx = state.db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(err)?;
        let inventory = self.target_inventory(&tx,&scope,&owner,Some(&receipt))?;
        let mut expected_identity = receipt.clone();
        expected_identity["kind"] = json!("target");
        let exact = inventory["claims"].as_array().ok_or("resource_inventory_incomplete")?.iter().any(|claim|
            claim["key"] == key && ["principal","session","run","boot"].iter().all(|name| claim[name] == receipt[name])
                && claim["identity"] == expected_identity);
        if !exact || inventory["admissible"] != true {
            return Ok(json!({"ok":false,"error":"target_conflicts_or_owner_changed","inventory":inventory}));
        }
        if action == "target_release" {
            let evidence = field(args,"evidence")?;
            if evidence.trim().is_empty() { return Err("target_release_evidence_required".into()); }
            tx.execute("INSERT INTO history(action,evidence,claim) VALUES('target_release',?,?)", params![evidence,receipt.to_string()]).map_err(err)?;
            tx.execute("DELETE FROM claims WHERE key=?", [&key]).map_err(err)?;
        }
        let child=if action=="target_child_observe" {
            let pid=args["child_process_id"].as_u64().and_then(|pid|u32::try_from(pid).ok()).ok_or("child_process_id_required")?;
            Some(child_observation(pid)?)
        } else {None};
        tx.commit().map_err(err)?;
        if action == "target_release" { state.targets.remove(&key); }
        Ok(json!({"ok":true,"held":action!="target_release","receipt":receipt,"inventory":inventory,"child":child}))
    }

    fn inventory(&self, db: &Connection) -> Result<Value> {
        Self::inventory_at(db, &self.root, &self.boot, false)
    }

    fn inventory_at(db: &Connection, root: &Path, current_boot: &str, read_only: bool) -> Result<Value> {
        let has_identity: bool = db.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='claim_identity')",[],|r|r.get(0)).map_err(err)?;
        let mut statement = db.prepare("SELECT key,principal,session,run,boot,uncertain FROM claims ORDER BY key").map_err(err)?;
        let mut claims = statement.query_map([], row).map_err(err)?.collect::<std::result::Result<Vec<_>,_>>().map_err(err)?;
        let mut identities_complete = true;
        for claim in &mut claims {
            let key = field(claim, "key")?;
            let boot = field(claim, "boot")?;
            let raw: Option<String> = if has_identity { db.query_row("SELECT identity FROM claim_identity WHERE key=? AND boot=?", params![key,boot], |r| r.get(0)).optional().map_err(err)? } else { None };
            let identity = raw.and_then(|raw| serde_json::from_str::<Value>(&raw).ok()).unwrap_or(Value::Null);
            let typed = match identity["kind"].as_str() {
                Some("session") => claim["key"] == format!("session:{}",claim["session"].as_str().unwrap_or("")) && field(&identity,"claim_id").is_ok(),
                Some("named") => field(&identity,"claim_id").is_ok(),
                Some("target") => identity["schema"] == 1 && identity["key"] == claim["key"]
                    && ["principal","session","run","boot"].iter().all(|name| identity[name] == claim[name])
                    && field(&identity,"receipt_id").is_ok() && field(&identity,"session_claim_id").is_ok()
                    && field(&identity["scope"],"git_common_dir").is_ok() && field(&identity["scope"],"ref").is_ok(),
                _ => false,
            };
            let known = identity["process_id"].as_u64().is_some_and(|pid| pid > 0)
                && identity["creation_stamp"].as_str().is_some_and(|stamp| !stamp.is_empty())
                && valid_boot(boot)
                && ["principal","session","run"].iter().all(|name| field(claim,name).is_ok_and(|value| !value.trim().is_empty()))
                && typed;
            let liveness = if boot == current_boot { "held" } else if valid_boot(boot) {
                let flags = if read_only { rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY } else { rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE };
                match Connection::open_with_flags(root.join(format!("{boot}.lease.sqlite")), flags) {
                    Ok(lease) => {
                        lease.busy_timeout(Duration::ZERO).map_err(err)?;
                        match lease.execute_batch("BEGIN EXCLUSIVE") {
                            Ok(()) => "lease_released",
                            Err(rusqlite::Error::SqliteFailure(e,_)) if matches!(e.code, rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked) => "held_or_unavailable",
                            Err(_) => "unverifiable",
                        }
                    }
                    Err(_) => "unverifiable",
                }
            } else { "unverifiable" };
            identities_complete &= known && liveness != "unverifiable";
            claim["identity"] = identity;
            claim["identity_complete"] = json!(known);
            claim["liveness"] = json!(liveness);
        }
        Ok(json!({"ok":true,"schema":1,"kind":"resource-inventory","complete":true,"identities_complete":identities_complete,"claims":claims}))
    }

    fn open(root: &Path) -> Result<Self> {
        std::fs::create_dir_all(root).map_err(err)?;
        let boot = crate::host::new_uuid();
        let lease = Connection::open(root.join(format!("{boot}.lease.sqlite"))).map_err(err)?;
        lease
            .execute_batch("PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE")
            .map_err(err)?;
        let db = Connection::open(root.join("claims.sqlite")).map_err(err)?;
        db.busy_timeout(Duration::from_secs(5)).map_err(err)?;
        db.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS claims (
              key TEXT PRIMARY KEY, principal TEXT NOT NULL, session TEXT NOT NULL,
              run TEXT NOT NULL, boot TEXT NOT NULL, uncertain INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS history (
              id INTEGER PRIMARY KEY, at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
              action TEXT NOT NULL, evidence TEXT NOT NULL, claim TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS claim_identity (
              key TEXT PRIMARY KEY, boot TEXT NOT NULL, identity TEXT NOT NULL);",
        )
        .map_err(err)?;
        Ok(Self {
            root: root.into(),
            boot,
            state: Mutex::new(State {
                db,
                live: HashSet::new(),
                _lease: lease,
                targets: HashMap::new(),
            }),
        })
    }

    fn control(&self, action: &str, args: &Value) -> Result<Value> {
        let mut state = self.state.lock().map_err(err)?;
        if action == "current_executor_observe" {
            // The shared Lua encoder represents an empty table as []; both
            // empty encodings mean no arguments, never caller identity.
            let empty=serde_json::Map::new();
            let fields=if args.as_array().is_some_and(|items|items.is_empty()){&empty}
                else{args.as_object().ok_or("current_executor_arguments_required")?};
            if fields.keys().any(|key| !matches!(key.as_str(),"child_process_id"|"operation_id")) {
                return Err("current_executor_identity_arguments_forbidden".into());
            }
            if args.get("operation_id").is_some()!=args.get("child_process_id").is_some(){
                return Err("current_executor_partial_child_query".into());
            }
            // Observation only: the successful session claim on THIS native thread
            // is authority for its context, never for unknown historical effects.
            let owner = self.owner(&state)?;
            let identity:String=state.db.query_row("SELECT identity FROM claim_identity WHERE key=? AND boot=?",
                params![format!("session:{}",field(&owner,"session")?),self.boot],|r|r.get(0)).map_err(err)?;
            let identity:Value=serde_json::from_str(&identity).map_err(err)?;
            if identity["kind"]!="session" || identity["process_id"]!=std::process::id() || identity["creation_stamp"]!=creation_stamp()? {
                return Err("current_executor_generation_changed".into());
            }
            let child = if let Some(value) = args.get("child_process_id") {
                let pid = value.as_u64().and_then(|v| u32::try_from(v).ok())
                    .ok_or("child_process_id_required")?;
                let operation_id=field(args,"operation_id")?;
                let operation=crate::operations::manager().observe_owned_child(operation_id,pid,field(&owner,"run")?).map_err(err)?;
                let mut child=child_observation(pid)?;
                if child["creation_stamp"]!=operation["child"]["creation_stamp"] {return Err("current_executor_operation_generation_changed".into());}
                child["operation_id"]=json!(operation_id);Some(child)
            } else { None };
            return Ok(json!({"ok":true,"schema":1,"kind":"current-native-executor-observation","read_only":true,
                "context":owner,"process_id":std::process::id(),"creation_stamp":creation_stamp()?,
                "resource_root":std::fs::canonicalize(&self.root).map_err(err)?,"child":child,
                "global_identity_safety":false,"production_registry_admission":false,"effect_authorized":false}));
        }
        if action.starts_with("target_") {
            return self.target_control(&mut state, action, args);
        }
        if action == "list" {
            let tx = state.db.transaction().map_err(err)?;
            let inventory = self.inventory(&tx)?;
            tx.commit().map_err(err)?;
            return Ok(inventory);
        }
        let run = field(args, "run")?;
        let principal = field(args, "principal")?;
        if action == "claim" {
            let session = field(args, "session")?;
            let keys = args["keys"].as_array().ok_or("keys_required")?;
            if keys.is_empty() || keys.len() > 64 {
                return Err("invalid_resource_count".into());
            }
            let keys = keys
                .iter()
                .map(|key| {
                    key.as_str()
                        .filter(|key| !key.is_empty() && key.len() <= 512)
                        .ok_or_else(|| "invalid_resource_key".to_string())
                })
                .collect::<Result<Vec<_>>>()?;
            let tx = state
                .db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(err)?;
            for key in &keys {
                let previous = tx
                    .query_row(
                        "SELECT key,principal,session,run,boot,uncertain FROM claims WHERE key=?",
                        [key],
                        row,
                    )
                    .optional()
                    .map_err(err)?;
                if let Some(previous) = previous {
                    if previous["run"] != run
                        || previous["principal"] != principal
                        || previous["boot"] != self.boot
                        || previous["uncertain"] == true
                    {
                        return Ok(json!({"ok":false,"error":"resource_busy","claim":previous}));
                    }
                }
            }
            for key in &keys {
                let inserted = tx.execute("INSERT OR IGNORE INTO claims(key,principal,session,run,boot) VALUES(?,?,?,?,?)",
                    params![key,principal,session,run,self.boot]).map_err(err)?;
                // Never backfill identity onto an existing historical claim.
                if inserted == 1 {
                    let creation = creation_stamp();
                    let identity = json!({"kind":if *key == format!("session:{session}") {"session"} else {"named"},
                        "claim_id":crate::host::new_uuid(),"process_id":std::process::id(), "creation_stamp":creation.as_ref().ok(),
                        "identity_error":creation.err(), "scope":null});
                    tx.execute("INSERT OR REPLACE INTO claim_identity VALUES(?,?,?)", params![key,self.boot,identity.to_string()]).map_err(err)?;
                }
            }
            let granted = keys.iter().map(|key| tx.query_row(
                "SELECT key,principal,session,run,boot,uncertain FROM claims WHERE key=?",[key],row).map_err(err))
                .collect::<Result<Vec<_>>>()?;
            tx.commit().map_err(err)?;
            state.live.insert(run.into());
            if let Some(claim) = granted.iter().find(|claim| claim["key"] == format!("session:{session}") && claim["session"] == session) {
                let raw: Option<String> = state.db.query_row("SELECT identity FROM claim_identity WHERE key=? AND boot=?",
                    params![claim["key"].as_str().unwrap(),self.boot], |r| r.get(0)).optional().map_err(err)?;
                let identity = raw.and_then(|raw| serde_json::from_str::<Value>(&raw).ok()).unwrap_or(Value::Null);
                let owner = identity["claim_id"].as_str().filter(|id| !id.is_empty()).map(|id|
                    json!({"principal":claim["principal"],"session":claim["session"],"run":claim["run"],"boot":claim["boot"],"claim_id":id}));
                OWNER.with(|slot| *slot.borrow_mut() = owner);
            }
            return Ok(json!({"ok":true,"claims":granted}));
        }
        if action == "uncertain" {
            state
                .db
                .execute(
                    "UPDATE claims SET uncertain=1 WHERE run=? AND principal=? AND boot=?",
                    params![run, principal, self.boot],
                )
                .map_err(err)?;
            return Ok(json!({"ok":true}));
        }
        if action == "recover" {
            // Clearing one's *own* uncertainty is not a release. The claim, its owner
            // and its durability are unchanged; what changes is that the one run whose
            // call failed without a receipt - and which has since inspected the effect -
            // may use the resource it already holds again.
            //
            // Who may do it is deliberately narrow: the same run, the same principal,
            // and the same process that granted the claim (`boot`). A different process
            // never speaks for a live owner, so a crashed owner's claims still need the
            // operator's reconcile. Evidence is required and is recorded, because the
            // question this answers is "was the effect inspected?", not "does it matter?".
            let key = field(args, "key")?;
            let evidence = field(args, "evidence")?;
            if evidence.trim().is_empty() {
                return Err("recovery_evidence_required".into());
            }
            let tx = state
                .db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(err)?;
            let claim = tx
                .query_row(
                    "SELECT key,principal,session,run,boot,uncertain FROM claims WHERE key=?",
                    [key],
                    row,
                )
                .optional()
                .map_err(err)?
                .ok_or("resource_not_found")?;
            if claim["run"] != run || claim["principal"] != principal {
                return Err("resource_owner_changed".into());
            }
            if field(&claim, "boot")? != self.boot {
                return Err("resource_owner_not_this_process".into());
            }
            if claim["uncertain"] == true {
                tx.execute(
                    "INSERT INTO history(action,evidence,claim) VALUES('recover',?,?)",
                    params![evidence, claim.to_string()],
                )
                .map_err(err)?;
                tx.execute(
                    "UPDATE claims SET uncertain=0 WHERE key=? AND run=? AND principal=? AND boot=?",
                    params![key, run, principal, self.boot],
                )
                .map_err(err)?;
            }
            // Idempotent: recovering an already-settled claim is a no-op, not an error.
            tx.commit().map_err(err)?;
            return Ok(json!({"ok":true,"recovered":claim}));
        }
        if action == "finish" {
            if state.targets.values().any(|held| held.receipt["run"] == run && held.receipt["principal"] == principal) {
                return Err("target_release_or_reconciliation_required".into());
            }
            let tx = state
                .db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(err)?;
            tx.execute(
                "INSERT INTO history(action,evidence,claim) SELECT 'finish','run settled',
                json_object('key',key,'principal',principal,'session',session,'run',run,'boot',boot)
                FROM claims WHERE run=? AND principal=? AND boot=? AND uncertain=0",
                params![run, principal, self.boot],
            )
            .map_err(err)?;
            tx.execute(
                "DELETE FROM claims WHERE run=? AND principal=? AND boot=? AND uncertain=0",
                params![run, principal, self.boot],
            )
            .map_err(err)?;
            tx.commit().map_err(err)?;
            state.live.remove(run);
            return Ok(json!({"ok":true}));
        }
        if action == "reconcile" {
            let key = field(args, "key")?;
            let evidence = field(args, "evidence")?;
            if evidence.trim().is_empty() {
                return Err("reconciliation_evidence_required".into());
            }
            // Copy liveness before borrowing the database for the transaction.
            let live = state.live.contains(run);
            let tx = state
                .db
                .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
                .map_err(err)?;
            let claim = tx
                .query_row(
                    "SELECT key,principal,session,run,boot,uncertain FROM claims WHERE key=?",
                    [key],
                    row,
                )
                .optional()
                .map_err(err)?
                .ok_or("resource_not_found")?;
            if claim["run"] != run || claim["principal"] != principal {
                return Err("resource_owner_changed".into());
            }
            let boot = field(&claim, "boot")?;
            if boot == self.boot {
                if live {
                    return Err("resource_owner_active".into());
                }
            } else {
                // Never use a PID timeout as proof of death. An OS-held SQLite
                // lock distinguishes a live process from a crashed owner.
                if boot.len() != 36 || !boot.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
                    return Err("invalid_resource_boot".into());
                }
                let lease = Connection::open(self.root.join(format!("{boot}.lease.sqlite")))
                    .map_err(err)?;
                lease.busy_timeout(Duration::ZERO).map_err(err)?;
                lease
                    .execute_batch("BEGIN EXCLUSIVE")
                    .map_err(|_| "resource_owner_active_or_unavailable".to_string())?;
            }
            tx.execute(
                "INSERT INTO history(action,evidence,claim) VALUES('reconcile',?,?)",
                params![evidence, claim.to_string()],
            )
            .map_err(err)?;
            tx.execute("DELETE FROM claims WHERE key=?", [key])
                .map_err(err)?;
            tx.commit().map_err(err)?;
            return Ok(json!({"ok":true,"released":claim}));
        }
        Err("unknown_resource_action".into())
    }
}

fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    Ok(
        json!({"key":row.get::<_,String>(0)?,"principal":row.get::<_,String>(1)?,
        "session":row.get::<_,String>(2)?,"run":row.get::<_,String>(3)?,"boot":row.get::<_,String>(4)?,
        "uncertain":row.get::<_,i64>(5)?!=0}),
    )
}

pub fn control(action: &str, args: &Value) -> Result<Value> {
    if action == "source_binary_observe" {
        let path=std::fs::canonicalize(field(args,"path")?).map_err(err)?;
        let bytes=std::fs::read(&path).map_err(err)?;
        let digest=ring::digest::digest(&ring::digest::SHA256,&bytes);
        let sha256=digest.as_ref().iter().map(|b|format!("{b:02x}")).collect::<String>();
        return Ok(json!({"ok":true,"kind":"native-binary-observation","path":path,"bytes":bytes.len(),"sha256":sha256,"effect_authorized":false}));
    }
    if action == "target_registered_inspect" {
        return registered_inspect(args);
    }
    static STORE: OnceLock<Result<Store>> = OnceLock::new();
    if action=="current_executor_observe" {
        return STORE.get().ok_or("resource_context_required")?.as_ref().map_err(Clone::clone)?.control(action,args);
    }
    let store = STORE.get_or_init(|| {
        Store::open(&PathBuf::from(crate::resolve_home()).join(".wasm-agent/resources"))
    });
    store.as_ref().map_err(Clone::clone)?.control(action, args)
}

fn registered_inspect(args: &Value) -> Result<Value> {
    let fields = args.as_object().ok_or("registered_inspection_arguments_required")?;
    if fields.keys().any(|key| !matches!(key.as_str(),"resource_root" | "git_common_dir" | "ref")) {
        return Err("registered_inspection_unknown_argument".into());
    }
    let root = std::fs::canonicalize(field(args,"resource_root")?).map_err(err)?;
    let (scope,_) = target_scope(args)?;
    if root.join("claims.sqlite-wal").exists() && !root.join("claims.sqlite-shm").exists() {
        return Err("registered_store_read_lock_metadata_missing".into());
    }
    let mut db = Connection::open_with_flags(root.join("claims.sqlite"),rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(err)?;
    let tx = db.transaction().map_err(err)?;
    let mut inventory = Store::inventory_at(&tx,&root,"",true)?;
    let conflicts = inventory["claims"].as_array().ok_or("registered_inventory_incomplete")?.iter().filter_map(|claim| {
        let identity = &claim["identity"];
        let reason = if claim["identity_complete"] != true {Some("owner_identity_missing")}
            else if claim["uncertain"] == true {Some("owner_uncertain")}
            else if claim["liveness"] == "unverifiable" {Some("owner_liveness_unverifiable")}
            else if identity["kind"] == "session" {None}
            else if identity["kind"] != "target" || identity["scope"].is_null() {Some("target_scope_unknown")}
            else if identity["scope"]["git_common_dir"] == scope["git_common_dir"] {Some("target_owned")}
            else {None};
        reason.map(|reason|json!({"reason":reason,"claim":claim}))
    }).collect::<Vec<_>>();
    inventory["kind"] = json!("registered-target-observation");
    inventory["scope"] = scope;
    inventory["resource_root"] = json!(root);
    inventory["admissible"] = json!(inventory["identities_complete"] == true && conflicts.is_empty());
    inventory["conflicts"] = json!(conflicts);
    inventory["effect_authorized"] = json!(false);
    inventory["read_only"] = json!(true);
    tx.commit().map_err(err)?;
    Ok(inventory)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn current_executor_is_read_only_and_requires_current_generation() {
        let root=std::env::temp_dir().join(format!("wa-current-executor-{}",crate::host::new_uuid()));
        let store=Store::open(&root).unwrap();OWNER.with(|slot|*slot.borrow_mut()=None);
        assert_eq!(store.control("current_executor_observe",&json!({})).unwrap_err(),"resource_context_required");
        let session=crate::host::new_uuid();let run=crate::host::new_uuid();
        store.control("claim",&json!({"principal":"private-executor","session":session,"run":run,"keys":[format!("session:{session}")]})).unwrap();
        let before=store.control("list",&json!({})).unwrap();
        let observed=store.control("current_executor_observe",&json!([])).unwrap();
        assert_eq!(observed["process_id"],std::process::id());assert_eq!(observed["creation_stamp"],creation_stamp().unwrap());
        assert_eq!(observed["production_registry_admission"],false);assert_eq!(observed["global_identity_safety"],false);
        assert_eq!(store.control("list",&json!({})).unwrap(),before);
        assert!(store.control("current_executor_observe",&json!({"principal":"copied"})).is_err());
        assert!(store.control("current_executor_observe",&json!({"operation_id":"copied"})).is_err());
        assert!(store.control("current_executor_observe",&json!({"operation_id":"copied","child_process_id":std::process::id()})).is_err());
        store.control("uncertain",&json!({"principal":"private-executor","run":run})).unwrap();
        assert_eq!(store.control("current_executor_observe",&json!({})).unwrap_err(),"resource_owner_uncertain_or_inactive");
        OWNER.with(|slot|*slot.borrow_mut()=None);drop(store);std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn registered_observation_reads_unknown_claims_without_backfilling() {
        let root = std::env::temp_dir().join(format!("wa-resource-observe-{}",crate::host::new_uuid()));
        let store = Store::open(&root).unwrap();
        let owner=json!({"principal":"legacy","session":"33b4-fixture","run":"unknown","keys":["legacy"]});
        store.control("claim",&owner).unwrap();
        store.state.lock().unwrap().db.execute("DELETE FROM claim_identity",[]).unwrap();
        let before=store.control("list",&json!({})).unwrap()["claims"].clone();
        let result=registered_inspect(&json!({"resource_root":root,"git_common_dir":root,"ref":"refs/heads/main"})).unwrap();
        assert_eq!(result["complete"],true);
        assert_eq!(result["identities_complete"],false);
        assert_eq!(result["effect_authorized"],false);
        assert_eq!(result["admissible"],false);
        assert_eq!(result["claims"][0]["identity"],Value::Null);
        assert_eq!(store.control("list",&json!({})).unwrap()["claims"],before);
        drop(store);std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn held_target_checks_exact_context_scope_and_complete_inventory() {
        let root = std::env::temp_dir().join(format!("wa-held-target-{}", crate::host::new_uuid()));
        let store = Store::open(&root).unwrap();
        let args = json!({"git_common_dir":root,"ref":"refs/heads/main"});
        OWNER.with(|slot| *slot.borrow_mut() = None);
        assert_eq!(store.control("target_hold",&args).unwrap_err(), "resource_context_required");
        let owner = json!({"principal":"alice","session":"s","run":"r","keys":["session:s"]});
        store.control("claim",&owner).unwrap();
        assert_eq!(store.control("target_inspect",&args).unwrap()["admissible"],true);
        let held = store.control("target_hold",&args).unwrap();
        assert_eq!(held["ok"],true);
        assert_eq!(held["receipt"]["boot"],store.boot);
        assert_eq!(held["receipt"]["process_id"],std::process::id());
        assert_eq!(held["receipt"]["creation_stamp"],creation_stamp().unwrap());
        let mut check = args.clone(); check["receipt"] = held["receipt"].clone();
        assert_eq!(store.control("target_check",&check).unwrap()["held"],true);
        let mut alias = check.clone(); alias["git_common_dir"] = json!(root.join("."));
        assert_eq!(store.control("target_check",&alias).unwrap()["held"],true,"canonical equivalent scope retains exact receipt");
        for reference in ["main","refs/heads/../main","refs/heads/*","refs/heads/a.lock","refs/heads/a@{b}"] {
            let mut invalid = args.clone(); invalid["ref"] = json!(reference);
            assert_eq!(store.control("target_inspect",&invalid).unwrap_err(),"invalid_target_ref");
        }
        let foreign = json!({"principal":"bob","session":"other","run":"other","keys":["session:other"]});
        store.control("claim",&foreign).unwrap();
        assert_eq!(store.control("target_check",&check).unwrap_err(),"target_receipt_or_owner_changed");
        store.control("claim",&owner).unwrap();
        let mut wrong = check.clone(); wrong["receipt"]["process_id"] = json!(1);
        assert_eq!(store.control("target_check",&wrong).unwrap_err(),"target_receipt_or_owner_changed");
        wrong = check.clone(); wrong["ref"] = json!("refs/heads/other");
        assert_eq!(store.control("target_check",&wrong).unwrap_err(),"target_receipt_or_owner_changed");
        wrong = args.clone(); wrong["limit"] = json!(1);
        assert_eq!(store.control("target_inspect",&wrong).unwrap_err(),"target_unknown_or_partial_query_argument");
        assert_eq!(store.control("finish",&owner).unwrap_err(),"target_release_or_reconciliation_required");
        store.state.lock().unwrap().db.execute("UPDATE claims SET principal='foreign' WHERE key='session:s'",[]).unwrap();
        assert_eq!(store.control("target_check",&check).unwrap_err(),"resource_owner_changed");
        store.state.lock().unwrap().db.execute("UPDATE claims SET principal='alice' WHERE key='session:s'",[]).unwrap();
        store.state.lock().unwrap().db.execute("UPDATE claims SET principal='foreign' WHERE key=?",[held["receipt"]["key"].as_str().unwrap()]).unwrap();
        assert_eq!(store.control("target_check",&check).unwrap()["ok"],false,"replaced target owner refuses even with native held lease");
        store.state.lock().unwrap().db.execute("UPDATE claims SET principal='alice' WHERE key=?",[held["receipt"]["key"].as_str().unwrap()]).unwrap();
        let original_identity: String = store.state.lock().unwrap().db.query_row("SELECT identity FROM claim_identity WHERE key='session:s'",[],|r|r.get(0)).unwrap();
        let mut replaced: Value = serde_json::from_str(&original_identity).unwrap(); replaced["claim_id"] = json!(crate::host::new_uuid());
        store.state.lock().unwrap().db.execute("UPDATE claim_identity SET identity=? WHERE key='session:s'",[replaced.to_string()]).unwrap();
        assert_eq!(store.control("target_check",&check).unwrap_err(),"resource_context_generation_changed");
        store.state.lock().unwrap().db.execute("UPDATE claim_identity SET identity=? WHERE key='session:s'",[&original_identity]).unwrap();
        store.state.lock().unwrap().db.execute("DELETE FROM claim_identity WHERE key='session:s'",[]).unwrap();
        assert_eq!(store.control("target_check",&check).unwrap_err(),"resource_context_identity_missing");
        let incomplete = store.control("list",&json!({})).unwrap();
        assert_eq!(incomplete["complete"],true,"actual registry query completed");
        assert_eq!(incomplete["identities_complete"],false);
        // Restoring private test evidence is not a production migration.
        store.state.lock().unwrap().db.execute("INSERT INTO claim_identity VALUES('session:s',?,?)",params![store.boot,original_identity]).unwrap();
        store.control("uncertain",&owner).unwrap();
        assert_eq!(store.control("target_check",&check).unwrap_err(),"resource_owner_uncertain_or_inactive");
        store.control("recover",&json!({"principal":"alice","run":"r","key":"session:s","evidence":"private test uncertainty inspected"})).unwrap();
        assert_eq!(store.control("target_check",&check).unwrap()["ok"],false,"uncertain target remains refused after session recovery");
        store.state.lock().unwrap().db.execute("DROP TABLE claim_identity",[]).unwrap();
        assert!(store.control("target_check",&check).is_err(),"incomplete query is a visible error, never an empty passing inventory");
        let (_,key) = target_scope(&args).unwrap();
        let lease = Connection::open(root.join(format!("target-{}.lease.sqlite",&key[7..]))).unwrap();
        assert!(lease.execute_batch("BEGIN EXCLUSIVE").is_err(),"query failure retains the native exclusion");
        drop(lease);
        drop(store);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn inventory_preserves_unknown_historical_owners() {
        let root = std::env::temp_dir().join(format!("wa-resource-inventory-{}", crate::host::new_uuid()));
        let store = Store::open(&root).unwrap();
        let legacy = json!({"principal":"alice","session":"old","run":"33b4","keys":["historical"]});
        store.control("claim", &legacy).unwrap();
        store.state.lock().unwrap().db.execute("DELETE FROM claim_identity", []).unwrap();
        let before = store.control("list", &json!({})).unwrap();
        assert_eq!(before["complete"], true);
        assert_eq!(before["identities_complete"], false);
        assert_eq!(before["claims"][0]["identity"], Value::Null);
        store.control("claim", &legacy).unwrap();
        assert_eq!(store.control("list", &json!({})).unwrap(), before, "reentrant admission never migrates historical identity");
        store.state.lock().unwrap().db.execute("UPDATE claims SET uncertain=1", []).unwrap();
        assert_eq!(store.control("list", &json!({})).unwrap()["claims"][0]["uncertain"], true);
        drop(store);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn claims_are_atomic_survive_crashes_and_refuse_live_reconciliation() {
        let root = std::env::temp_dir().join(format!("wa-resources-{}", crate::host::new_uuid()));
        let first = Store::open(&root).unwrap();
        let second = Store::open(&root).unwrap();
        let a = json!({"principal":"alice","session":"a","run":"run-a","keys":["desktop"]});
        let b = json!({"principal":"bob","session":"b","run":"run-b","keys":["free","desktop"]});
        assert_eq!(first.control("claim", &a).unwrap()["ok"], true);
        assert_eq!(first.control("claim", &a).unwrap()["ok"], true);
        assert_eq!(
            second.control("claim", &b).unwrap()["error"],
            "resource_busy"
        );
        assert_eq!(
            second.control("list", &json!({})).unwrap()["claims"]
                .as_array()
                .unwrap()
                .len(),
            1,
            "multi-key refusal is atomic"
        );
        let recovery = json!({"principal":"alice","run":"run-a","key":"desktop","evidence":"checked desktop and no process remains"});
        assert_eq!(
            first.control("reconcile", &recovery).unwrap_err(),
            "resource_owner_active"
        );
        assert_eq!(
            second.control("reconcile", &recovery).unwrap_err(),
            "resource_owner_active_or_unavailable"
        );
        drop(first); // OS lease released, durable claim deliberately retained.
        assert_eq!(
            second.control("claim", &b).unwrap()["error"],
            "resource_busy"
        );
        let mut wrong = recovery.clone();
        wrong["run"] = json!("wrong");
        assert_eq!(
            second.control("reconcile", &wrong).unwrap_err(),
            "resource_owner_changed"
        );
        assert_eq!(second.control("reconcile", &recovery).unwrap()["ok"], true);
        assert_eq!(second.control("claim", &b).unwrap()["ok"], true);
        second.control("uncertain", &b).unwrap();
        second.control("finish", &b).unwrap();
        assert_eq!(
            second.control("list", &json!({})).unwrap()["claims"]
                .as_array()
                .unwrap()
                .len(),
            2,
            "uncertain effects retain their claims"
        );
        drop(second);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn only_the_live_owner_clears_its_own_uncertainty_with_stated_evidence() {
        let root = std::env::temp_dir().join(format!("wa-resources-recover-{}", crate::host::new_uuid()));
        let owner = Store::open(&root).unwrap();
        let other = Store::open(&root).unwrap();
        let claim = json!({"principal":"alice","session":"s-a","run":"run-a","keys":["client:local"]});
        assert_eq!(owner.control("claim", &claim).unwrap()["ok"], true);
        // A call of alice's failed without a receipt, so the claim stays - uncertain.
        owner
            .control("uncertain", &json!({"principal":"alice","run":"run-a"}))
            .unwrap();
        assert_eq!(
            owner.control("claim", &claim).unwrap()["error"],
            "resource_busy",
            "the very run that owns an uncertain claim cannot reuse it yet"
        );
        let no_evidence = json!({"principal":"alice","run":"run-a","key":"client:local","evidence":"  "});
        assert_eq!(
            owner.control("recover", &no_evidence).unwrap_err(),
            "recovery_evidence_required"
        );
        let wrong_run = json!({"principal":"alice","run":"run-b","key":"client:local","evidence":"inspected"});
        assert_eq!(
            owner.control("recover", &wrong_run).unwrap_err(),
            "resource_owner_changed"
        );
        let owned = json!({"principal":"alice","run":"run-a","key":"client:local","evidence":"client answered status: connected and idle"});
        assert_eq!(
            other.control("recover", &owned).unwrap_err(),
            "resource_owner_not_this_process",
            "a second process never clears a live owner's uncertainty"
        );
        assert_eq!(owner.control("recover", &owned).unwrap()["ok"], true);
        assert_eq!(
            owner.control("claim", &claim).unwrap()["ok"], true,
            "the owner may use the resource it still holds"
        );
        assert_eq!(
            owner.control("recover", &owned).unwrap()["ok"], true,
            "recovery is idempotent"
        );
        assert_eq!(
            other
                .control("claim", &json!({"principal":"bob","session":"s-b","run":"run-b","keys":["client:local"]}))
                .unwrap()["error"],
            "resource_busy",
            "recovery is not a release: another owner stays refused"
        );
        drop(owner);
        drop(other);
        std::fs::remove_dir_all(root).unwrap();
    }
}
