//! Transactional install and upgrade of a service component (`docs/KERNEL.md`, lesson 5).
//!
//! One order, and every failure leaves the node exactly as it was found:
//!
//! ```text
//! stage the files        -> <components>/.stage-<name>-<pid>/ (nothing installed yet)
//! verify the pin         -> the staged bytes must match a declared sha256, exactly
//! check imported versions-> every interface it imports must be served (kernel or a running provider)
//! migrate state          -> wa-state migration on a *snapshot copy* (services::spawn_instance does it)
//! start the new instance -> beside the old one, same name, same grants, same state
//! health                 -> lifecycle.report(ready) or a running instance that never reports
//! switch                 -> the staged files replace the installed ones, pin file last
//! stop the old instance  -> per generation, so the new instance's registrations survive
//! ```
//!
//! Two properties are the point of the order, and both are tested:
//!
//! * a candidate that cannot start, does not become healthy, or imports an interface nobody serves
//!   costs nothing: the old instance keeps running, the installed files are untouched, and the
//!   staging directory is removed;
//! * a candidate that does take over has its files committed **before** the switch, so a crash between
//!   the switch and the next start still finds a consistent installation on disk.
//!
//! What this reuses rather than reimplements: `services::spawn_instance` (grants, state migration,
//! contract detection, log, supervision), `dev::wait_ready` (the health rule the dev loop already
//! proved), `services::replace` (per-generation revocation), `imports` (what the artifact needs) and
//! `supervisor` (what is served). A second copy of any of those is how two paths come to disagree
//! about what "healthy" or "served" means.

use crate::components::{self, load, Grant, Installed};
use crate::imports;
use crate::services;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How long a candidate gets to report health when the caller does not say.
const DEFAULT_READY_MS: u64 = 10_000;

/// One staged installation: three files in a directory of their own, and what was verified about them.
struct Staged {
    dir: PathBuf,
    bytes: Vec<u8>,
    manifest: Value,
    sha256: String,
}

impl Drop for Staged {
    fn drop(&mut self) {
        // Staging is never evidence: it is either committed or refused, and a refused staging
        // directory left behind is a directory the next stage would have to guess about.
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn hex(bytes: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, bytes).as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

/// `services upgrade {name, source:{wasm, manifest|manifest_path, pin}}`.
///
/// `source.wasm` is a path to the built `.wasm` (the artifact itself, not a directory), `source.manifest`
/// is the manifest object or `source.manifest_path` its file, and the pin is `source.pin` (a sha256, or
/// a path to a `.sha256` file) - a component without a pin is refused, exactly as the loader refuses one.
pub fn upgrade(request: &Value) -> Value {
    let started = Instant::now();
    let Some(name) = request.get("name").and_then(Value::as_str) else {
        return json!({"ok": false, "error": "service_name_required"});
    };
    let Some(source) = request.get("source").and_then(Value::as_object) else {
        return json!({"ok": false, "name": name, "error": "upgrade_source_required"});
    };
    // The old installation, read (and pin-verified) before anything is written: a node whose installed
    // component does not match its own pin is a node to look at, not one to upgrade over.
    let previous = match load(name) {
        Ok(installed) => Some(installed),
        Err(error) if error.to_string().starts_with("component_not_installed") => None,
        Err(error) => return json!({"ok": false, "name": name, "error": error.to_string(), "mode": "kept_previous"}),
    };
    let mode = if previous.is_some() { "upgrade" } else { "install" };

    // 1. Stage. Everything from here to the switch happens in a directory of its own.
    let staged = match stage(name, source) {
        Ok(staged) => staged,
        Err(error) => return json!({"ok": false, "name": name, "mode": mode, "stage": "staged", "error": error}),
    };
    if staged.manifest.get("kind").and_then(Value::as_str) != Some("service") {
        return json!({"ok": false, "name": name, "mode": mode, "stage": "manifest", "error": "component_is_not_a_service"});
    }
    // 2. The interfaces it imports, and whether this node serves them right now.
    let interfaces = match imports::of_bytes(&staged.bytes) {
        Ok(interfaces) => interfaces,
        Err(error) => return json!({"ok": false, "name": name, "mode": mode, "stage": "imports", "error": error.to_string()}),
    };
    let served = crate::supervisor::served();
    let waiting = interfaces.waiting_for(&served.interfaces());
    if !waiting.is_empty() {
        return json!({
            "ok": false,
            "name": name,
            "mode": mode,
            "stage": "imports",
            "error": format!("imports_not_served:{}", waiting.join(",")),
            "waiting_for": waiting,
            "contract": interfaces.contract.as_str(),
        });
    }
    // 3. A grant is checked against the manifest before anything runs; a request that grants what this
    //    manifest does not declare is refused here, not by a call that quietly fails later.
    let mut grant_request = request.clone();
    if grant_request.get("config").is_none() {
        // 4. Profiles as layers: the effective `config` a component starts with comes from the stack
        //    unless the caller named one (`profiles::config_for`).
        let (effective, _) = crate::profiles::load();
        let config = effective.config_for(name);
        if config.as_object().is_some_and(|object| !object.is_empty()) {
            grant_request["config"] = config;
        }
    }
    let grant = match Grant::from_request(&grant_request).and_then(|grant| grant.check(&staged.manifest).map(|_| grant)) {
        Ok(grant) => grant,
        Err(error) => return json!({"ok": false, "name": name, "mode": mode, "stage": "grant", "error": error.to_string()}),
    };
    let installed = Installed { name: name.to_string(), sha256: staged.sha256.clone(), bytes: staged.bytes.clone(), manifest: staged.manifest.clone() };
    // 5. Start the candidate beside the old instance: same name, same grants, same state directory -
    //    and the state migration (on a snapshot copy) inside, before anything runs.
    let spawned = match services::spawn_instance(installed, grant) {
        Ok(spawned) => spawned,
        Err(mut error) => {
            if let Some(object) = error.as_object_mut() {
                object.insert("mode".into(), json!(mode));
                object.insert("stage".into(), json!("started"));
            }
            return error;
        }
    };
    let instance = spawned.instance.clone();
    let previous_sha256 = previous.as_ref().map(|installed| installed.sha256.clone());
    // 6. Health. The rule is `dev::wait_ready`'s: a report of `ready`/`degraded` is health, an exit is a
    //    failure, and an instance that runs for the whole window without reporting is accepted *and
    //    said to be unreported* - `lifecycle.report` is optional in the WIT and absent in a wasip1
    //    module, so inventing health would be worse than naming its absence.
    let ready = Duration::from_millis(request.get("ready_ms").and_then(Value::as_u64).unwrap_or(DEFAULT_READY_MS));
    let health = match crate::dev::wait_ready(&spawned.shared, spawned.thread.as_ref(), ready) {
        Ok(health) => health,
        // A component that stays up without ever reporting is accepted, and the answer says so: the
        // report is optional in the WIT and absent in a wasip1 module (`dev::wait_ready`).
        Err(crate::dev::Wait::Unreported(health)) => format!("unreported:{health}"),
        Err(why) => {
            let last_exit = services::stop_spawned(spawned);
            return json!({
                "ok": false,
                "name": name,
                "mode": mode,
                "stage": "health",
                "error": format!("candidate_not_healthy:{why:?}"),
                "last_exit": last_exit,
                "previous": previous_sha256,
                "elapsed_ms": started.elapsed().as_millis() as u64,
            });
        }
    };
    // 7. Commit the files (wasm, manifest, pin last) and switch the instance.
    if let Err(error) = commit(name, &staged) {
        let last_exit = services::stop_spawned(spawned);
        return json!({
            "ok": false,
            "name": name,
            "mode": mode,
            "stage": "commit",
            "error": error,
            "last_exit": last_exit,
            "previous": previous_sha256,
        });
    }
    let switched = services::replace(name, spawned);
    json!({
        "ok": true,
        "name": name,
        "mode": mode,
        "sha256": staged.sha256,
        "previous": previous_sha256,
        "health": health,
        "contract": interfaces.contract.as_str(),
        "imports": interfaces.imports.iter().cloned().collect::<Vec<_>>(),
        "instance": instance.to_json(),
        "switch": switched,
        "elapsed_ms": started.elapsed().as_millis() as u64,
    })
}

/// Read, verify and stage the three files. The pin is checked here, before anything is started - a
/// mismatch is a refusal that costs nothing.
fn stage(name: &str, source: &serde_json::Map<String, Value>) -> Result<Staged, String> {
    let wasm_path = source.get("wasm").and_then(Value::as_str).ok_or("upgrade_source_wasm_required")?;
    let bytes = std::fs::read(wasm_path).map_err(|error| format!("upgrade_source_unreadable:{error}"))?;
    if bytes.len() < 8 || &bytes[0..4] != b"\0asm" {
        return Err("upgrade_source_not_wasm".into());
    }
    if bytes.len() > 64 << 20 {
        return Err("upgrade_source_too_large".into());
    }
    let manifest = match (source.get("manifest"), source.get("manifest_path")) {
        (Some(Value::Object(object)), _) => Value::Object(object.clone()),
        (None, Some(Value::String(path))) => {
            let text = std::fs::read_to_string(path).map_err(|error| format!("upgrade_manifest_unreadable:{error}"))?;
            serde_json::from_str(&text).map_err(|error| format!("upgrade_manifest_invalid:{error}"))?
        }
        (Some(_), _) => return Err("upgrade_manifest_invalid".into()),
        (None, Some(_)) => return Err("upgrade_manifest_unreadable:not_a_path".into()),
        (None, None) => {
            // Beside the artifact, where `build-components.sh` leaves it.
            let beside = Path::new(wasm_path).with_extension("json");
            let text = std::fs::read_to_string(&beside).map_err(|_| "upgrade_manifest_required".to_string())?;
            serde_json::from_str(&text).map_err(|error| format!("upgrade_manifest_invalid:{error}"))?
        }
    };
    let actual = hex(&bytes);
    let declared = match source.get("pin") {
        Some(Value::String(pin)) if pin.ends_with(".sha256") || pin.contains('/') || pin.contains('\\') => {
            let text = std::fs::read_to_string(pin).map_err(|error| format!("upgrade_pin_unreadable:{error}"))?;
            text.split_whitespace().next().unwrap_or_default().to_ascii_lowercase()
        }
        Some(Value::String(pin)) => pin.trim().to_ascii_lowercase(),
        Some(_) => return Err("upgrade_pin_invalid".into()),
        None => match manifest.get("pin").and_then(Value::as_str) {
            Some(pin) => pin.trim().to_ascii_lowercase(),
            // No pin anywhere: an unpinned component is refused by the loader, so it is refused here,
            // where nothing has been installed yet.
            None => return Err("upgrade_pin_required".into()),
        },
    };
    if declared != actual {
        return Err(format!("upgrade_pin_mismatch:declared={declared},actual={actual}"));
    }
    let dir = components::component_dir().join(format!(".stage-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).map_err(|error| format!("upgrade_stage_failed:{error}"))?;
    std::fs::write(dir.join(format!("{name}.wasm")), &bytes).map_err(|error| format!("upgrade_stage_failed:{error}"))?;
    std::fs::write(dir.join(format!("{name}.json")), manifest.to_string()).map_err(|error| format!("upgrade_stage_failed:{error}"))?;
    std::fs::write(dir.join(format!("{name}.wasm.sha256")), format!("{actual}\n")).map_err(|error| format!("upgrade_stage_failed:{error}"))?;
    Ok(Staged { dir, bytes, manifest, sha256: actual })
}

/// Put the staged files where the loader reads them, atomically, pin file last.
///
/// The order is the contract: the pin is what makes the pair (bytes, manifest) a verified installation,
/// so it moves last. A process killed between the wasm and the pin leaves the *old* pin beside new
/// bytes, which `load()` refuses loudly (`component_hash_mismatch`) instead of running unverified bytes
/// - and the next upgrade repairs it.
fn commit(name: &str, staged: &Staged) -> Result<(), String> {
    let target = components::component_dir();
    std::fs::create_dir_all(&target).map_err(|error| format!("upgrade_commit_failed:{error}"))?;
    let moves = [
        (format!("{name}.wasm"), format!("{name}.wasm")),
        (format!("{name}.json"), format!("{name}.json")),
        (format!("{name}.wasm.sha256"), format!("{name}.wasm.sha256")),
    ];
    for (from, to) in moves {
        let temporary = target.join(format!(".{to}.commit-{}", std::process::id()));
        std::fs::copy(staged.dir.join(&from), &temporary).map_err(|error| format!("upgrade_commit_failed:{error}"))?;
        std::fs::rename(&temporary, target.join(&to)).map_err(|error| format!("upgrade_commit_failed:{error}"))?;
    }
    // Prove the installation the loader will see is the one that was started.
    match load(name) {
        Ok(installed) if installed.sha256 == staged.sha256 => Ok(()),
        Ok(installed) => Err(format!("upgrade_commit_mismatch:{}", installed.sha256)),
        Err(error) => Err(format!("upgrade_commit_unreadable:{error}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::components::TEST_DIR_LOCK;

    fn manifest() -> Value {
        json!({"kind": "service", "target": "wasm32-wasip1", "capabilities": {}})
    }

    fn write(dir: &Path, tag: u32) -> (PathBuf, String) {
        let path = dir.join(format!("candidate-{tag}.wasm"));
        let bytes = crate::test_wasm::silent_module(tag);
        std::fs::write(&path, &bytes).unwrap();
        (path, hex(&bytes))
    }

    /// Install, then upgrade, then refuse two candidates - the whole transactional contract in one
    /// test because `WA_COMPONENTS_DIR` and the services registry are process-wide.
    #[test]
    fn an_upgrade_switches_only_when_the_candidate_is_good() {
        let _dir = TEST_DIR_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = std::env::temp_dir().join(format!("wa-install-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        // Two directories on purpose: the component directory is the node's, the candidates are what a
        // build produced somewhere else - and a refused upgrade must not depend on either being clean.
        let installed_dir = root.join("components");
        let work = root.join("candidates");
        std::fs::create_dir_all(&installed_dir).unwrap();
        std::fs::create_dir_all(&work).unwrap();
        std::env::set_var("WA_COMPONENTS_DIR", &installed_dir);
        let name = "inst-svc";
        let (wasm_a, pin_a) = write(&work, 1);

        // The first install has nothing to keep: same stages, `mode: install`.
        let installed = upgrade(&json!({
            "name": name,
            "source": {"wasm": wasm_a.to_string_lossy(), "manifest": manifest(), "pin": pin_a},
            "ready_ms": 150,
        }));
        assert_eq!(installed["ok"], true, "{installed}");
        assert_eq!(installed["mode"], "install");
        assert_eq!(installed["sha256"], pin_a.as_str());
        assert_eq!(load(name).unwrap().sha256, pin_a, "the files on disk are the candidate that started");
        let first = services::status(Some(name));
        assert_eq!(first["generation"], 1, "{first}");
        assert_eq!(services::stop(name)["was_running"], true);

        // Start it again, so the upgrade has a *running* old instance to keep (the install committed
        // the files, so this is the ordinary cold-start path).
        let started = services::start(&json!({"name": name}));
        assert_eq!(started["ok"], true, "{started}");
        assert_eq!(started["instance"]["generation"], 2, "a restart is a new instance of the same name");
        let (wasm_b, pin_b) = write(&work, 2);

        // A pin that does not match the bytes: refused, nothing installed, the old instance running.
        let wrong = upgrade(&json!({
            "name": name,
            "source": {"wasm": wasm_b.to_string_lossy(), "manifest": manifest(), "pin": pin_a},
            "ready_ms": 100,
        }));
        assert_eq!(wrong["ok"], false, "{wrong}");
        assert!(wrong["error"].as_str().unwrap_or_default().starts_with("upgrade_pin_mismatch"), "{wrong}");
        assert_eq!(load(name).unwrap().sha256, pin_a, "the installed files did not move");
        // The stand-in artifact has nothing to run, so the supervisor cycles it through `backoff`; what
        // matters is that it is the *same* instance and not a retired one.
        assert_eq!(services::status(Some(name))["instance"], format!("{name}#2"), "the old instance was not stopped");

        // A source that is not a wasm at all: refused before anything is staged for real.
        let junk = work.join("junk.wasm");
        std::fs::write(&junk, b"not wasm at all").unwrap();
        let refused = upgrade(&json!({"name": name, "source": {"wasm": junk.to_string_lossy(), "manifest": manifest(), "pin": pin_a}}));
        assert_eq!(refused["error"], "upgrade_source_not_wasm", "{refused}");

        // A candidate whose imports nobody serves: refused, with the interface named.
        let unserved_path = work.join("needs-vision.wasm");
        let unserved_bytes = crate::test_wasm::core_module(&[("wa_vision", "read")], true);
        std::fs::write(&unserved_path, &unserved_bytes).unwrap();
        let unserved = upgrade(&json!({
            "name": name,
            "source": {"wasm": unserved_path.to_string_lossy(), "manifest": manifest(), "pin": hex(&unserved_bytes)},
        }));
        assert_eq!(unserved["ok"], false, "{unserved}");
        assert!(unserved["error"].as_str().unwrap_or_default().starts_with("imports_not_served"), "{unserved}");
        assert_eq!(unserved["waiting_for"], json!(["wa_vision"]), "{unserved}");
        assert_eq!(load(name).unwrap().sha256, pin_a);
        assert_eq!(services::status(Some(name))["instance"], format!("{name}#2"), "the old instance was not stopped");

        // The good candidate: staged, verified, started beside, then switched, and the old instance
        // retired with its registrations revoked - the new one's are untouched.
        let registrations_before = crate::registrations::node().count_owner(name);
        let upgraded = upgrade(&json!({
            "name": name,
            "source": {"wasm": wasm_b.to_string_lossy(), "manifest": manifest(), "pin": pin_b},
            "ready_ms": 150,
        }));
        assert_eq!(upgraded["ok"], true, "{upgraded}");
        assert_eq!(upgraded["mode"], "upgrade");
        assert_eq!(upgraded["sha256"], pin_b.as_str());
        assert_eq!(upgraded["previous"], pin_a.as_str());
        assert_eq!(load(name).unwrap().sha256, pin_b, "the new files are installed");
        let after = services::status(Some(name));
        assert_eq!(after["generation"], 3, "the upgrade is the third instance of this name");
        assert_eq!(after["instance"], format!("{name}#3"), "{after}");
        assert_ne!(after["state"], "not_running", "{after}");
        assert_eq!(after["sha256"], pin_b.as_str());
        assert!(after["registrations"].as_u64().unwrap() >= 1, "the new instance holds its own rows: {after}");
        assert_eq!(
            crate::registrations::node().count_generation(name, 2),
            0,
            "nothing of the retired instance lingers in the ledger"
        );
        assert_eq!(crate::bus_host::node().instances(name), vec![format!("{name}#3")], "the old bus token was detached");
        assert_eq!(crate::queue_host::node().instance_count(name), 1, "the old queue grant was revoked");
        assert_eq!(crate::registrations::node().count_owner(name), registrations_before, "one instance's worth of rows");
        assert_eq!(upgraded["switch"]["retired"]["generation"], 2, "{upgraded}");
        services::stop(name);
        let _ = std::fs::remove_dir_all(&root);
    }
}
