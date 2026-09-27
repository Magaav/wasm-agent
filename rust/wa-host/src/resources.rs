//! Durable exclusive claims. Lua chooses resource names and policy; this module
//! supplies atomic ownership, process liveness and compare-and-release primitives.
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::{Mutex, OnceLock},
    time::Duration,
};

struct State {
    db: Connection,
    live: HashSet<String>,
    _lease: Connection,
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

impl Store {
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
              action TEXT NOT NULL, evidence TEXT NOT NULL, claim TEXT NOT NULL);",
        )
        .map_err(err)?;
        Ok(Self {
            root: root.into(),
            boot,
            state: Mutex::new(State {
                db,
                live: HashSet::new(),
                _lease: lease,
            }),
        })
    }

    fn control(&self, action: &str, args: &Value) -> Result<Value> {
        let mut state = self.state.lock().map_err(err)?;
        if action == "list" {
            let mut statement = state
                .db
                .prepare("SELECT key,principal,session,run,boot,uncertain FROM claims ORDER BY key")
                .map_err(err)?;
            let rows = statement.query_map([], row).map_err(err)?;
            let claims = rows
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(err)?;
            return Ok(json!({"ok":true,"claims":claims}));
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
            for key in keys {
                tx.execute("INSERT OR IGNORE INTO claims(key,principal,session,run,boot) VALUES(?,?,?,?,?)",
                    params![key,principal,session,run,self.boot]).map_err(err)?;
            }
            tx.commit().map_err(err)?;
            state.live.insert(run.into());
            return Ok(json!({"ok":true}));
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
    static STORE: OnceLock<Result<Store>> = OnceLock::new();
    let store = STORE.get_or_init(|| {
        Store::open(&PathBuf::from(crate::resolve_home()).join(".wasm-agent/resources"))
    });
    store.as_ref().map_err(Clone::clone)?.control(action, args)
}

#[cfg(test)]
mod tests {
    use super::*;
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
