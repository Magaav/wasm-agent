//! Durable acknowledgement is not an installation result. Legacy requests retain legacy behavior.
use super::*;
#[cfg(test)]
#[path="protocol_reconcile_tests.rs"]
mod reconcile_tests;

pub(crate) fn reserved(id: &str) -> bool {
    !id.is_empty() && id.bytes().all(|b|b.is_ascii_alphanumeric() || b==b'-') && sentinel_dir().join("deploy-protocol").join(id).join("intent.json").exists()
}
pub(crate) fn fence(request: &Value,id: &str) -> Result<()> {
    if reserved(id) {
        let original:Value=serde_json::from_slice(&std::fs::read(sentinel_dir().join("deploy-protocol").join(id).join("intent.json"))?)?;
        if original != *request { bail!("immutable_intent_mismatch"); }
    }
    Ok(())
}
pub(crate) fn validate(request: &Value, id: &str) -> Result<()> {
    fence(request,id)?;
    if request.get("expected_sha").is_none() { return Ok(()); }
    let sha = request["expected_sha"].as_str().unwrap_or("");
    if request["verb"] != "deploy" || sha.len() != 40 || !sha.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("expected_sha requires deploy and a full 40-character source SHA");
    }
    if request["id"].as_str() != Some(id) { bail!("request id does not match durable filename"); }
    if request["queued_at"].as_u64().filter(|n| *n > 0).is_none() { bail!("missing queued_at"); }
    if request["queued_at"].as_u64().unwrap_or(0) > now_epoch() { bail!("future_queued_at"); }
    if request["session"].as_str().unwrap_or("").is_empty() { bail!("protocol deploy requires parent session"); }
    if request.get("owner").is_some() && request["owner"].as_str().filter(|s|!s.is_empty()).is_none() { bail!("invalid_owner_scope"); }
    for field in ["prompt","reason"] { if request.get(field).is_some() && !request[field].is_string() { bail!("invalid_text_field:{field}"); } }
    let object=request.as_object().context("request_not_object")?;
    if object.keys().any(|k| !["verb","id","expected_sha","queued_at","session","owner","prompt","reason"].contains(&k.as_str())) { bail!("unknown_intent_field"); }
    if id.is_empty() || !id.bytes().all(|b|b.is_ascii_alphanumeric() || b==b'-') { bail!("unsafe_request_id"); }
    Ok(())
}

pub(crate) fn record(request: &Value, id: &str, phase: &str, detail: &str) -> Result<()> {
    if request.get("expected_sha").is_none() { return Ok(()); }
    if id.is_empty() || !id.bytes().all(|b|b.is_ascii_alphanumeric() || b == b'-') { bail!("unsafe request filename identity"); }
    let dir = sentinel_dir().join("deploy-protocol").join(id);
    std::fs::create_dir_all(&dir)?;
    let lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join("intake.lock"))?;
    lock.lock()?;
    // First observation remains immutable, including across watcher replacement.
    let intent = dir.join("intent.json");
    if intent.exists() {
        let original:Value=serde_json::from_slice(&std::fs::read(&intent)?)?;
        if original != *request { bail!("immutable_intent_mismatch"); }
    } else { wa_operation::atomic_json(&intent, request)?; }
    let ack = dir.join("ack.json");
    if !ack.exists() {
        wa_operation::atomic_json(&ack, &json!({"schema":1,"id":id,"expected_sha":request["expected_sha"],
            "session":request["session"],"owner":request["owner"],"queued_at":request["queued_at"],"phase":phase,
            "detail":detail,"at":now_epoch()}))?;
    }
    if phase=="held" && dir.join("state.json").exists() {
        let state:Value=serde_json::from_slice(&std::fs::read(dir.join("state.json"))?)?;
        if ["spawned","failed","verified","unknown"].contains(&state["phase"].as_str().unwrap_or("")) {return Ok(());}
    }
    wa_operation::atomic_json(&dir.join("state.json"), &json!({"schema":1,"id":id,
        "expected_sha":request["expected_sha"],"session":request["session"],
        "queued_at":request["queued_at"],"phase":phase,"detail":detail,"at":now_epoch()}))?;
    Ok(())
}

/// Cheap durable observation. No health, source lookup or effect admission.
pub(crate) fn intake(request: &Value, id: &str) -> Result<()> {
    if request.get("expected_sha").is_none() && !reserved(id) { return Ok(()); }
    let result=validate(request,id).and_then(|_|record(request,id,"held","acknowledged; effect awaits owner/source/target/hook admission"));
    if let Err(error)=result {
        let safe=id.bytes().map(|b|format!("{b:02x}")).collect::<String>();
        let dir=sentinel_dir().join("intake-problems").join(safe);
        std::fs::create_dir_all(&dir)?;
        let evidence=json!({"id":id,"observed":request,"phase":"problem","detail":error.to_string(),"at":now_epoch()});
        let name=format!("{}-{}.json",now_epoch(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos());
        wa_operation::atomic_json(&dir.join(name),&evidence)?;
        // Preserve original ack/intent. Latest problem is separately discoverable.
        wa_operation::atomic_json(&dir.join("latest.json"),&evidence)?;
        bail!("{error}");
    }
    Ok(())
}

pub(crate) fn ready() -> bool {
    installed_binary().parent().map(|p|p.join("runtime-worktree.txt").is_file()).unwrap_or(false)
        && jobs::store().get("onSentinelReturn").map(|j|hook_ready(&j)).unwrap_or(false)
}

pub(crate) fn hook_ready(job:&Value) -> bool {
    job["enabled"]==true && job["trigger"]["kind"]=="event"
        && job["trigger"]["topic"]=="sentinel.return" && job["action"]["kind"]=="wake"
        && job["action"]["dedupe_key"]=="event_key"
}

/// Validate every privileged input again in the effect worker. Reservations survive replacement;
/// even a spawn error is uncertain and never an automatic second effect.
pub(crate) fn admit(request:&Value) -> Result<PathBuf> {
    let id=request["id"].as_str().context("protocol_id_missing")?;
    validate(request,id)?;
    let owner=request["owner"].as_str().filter(|s|!s.is_empty()).context("protocol_owner_required")?;
    let binding=sentinel_return::bind_parent(id)?;
    if binding["owner"]!=owner {bail!("protocol_owner_mismatch");}
    let job=jobs::store().get("onSentinelReturn").map_err(|e|anyhow::anyhow!(e.to_string()))?;
    if !hook_ready(&job) {bail!("return_hook_not_ready");}
    let script=canonical_script(request["expected_sha"].as_str().context("protocol_sha_missing")?)?;
    let target=verify_target(node_port(),true).map_err(|error|anyhow::anyhow!("protocol_native_target_not_owned: {error:#}"))?;
    let dir=sentinel_dir().join("deploy-protocol").join(id);
    let install_lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(sentinel_dir().join("protocol-effect.lock"))?;
    install_lock.lock()?;
    let active_file=sentinel_dir().join("protocol-effect.json");
    if active_file.exists() {
        let active:Value=serde_json::from_slice(&std::fs::read(&active_file)?)?;
        if !reservation_released(&active)? {bail!("prior_protocol_effect_unsettled:{}; reconcile, never replay",active["id"]);}
    }
    let lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join("effect.lock"))?;
    lock.lock()?;
    if dir.join("effect.json").exists() {bail!("effect_already_reserved; reconcile, never replay");}
    fence(request,id)?;
    let source=script.parent().and_then(Path::parent).context("source_parent_missing")?;
    let digest=ring::digest::digest(&ring::digest::SHA256,&std::fs::read(&script)?).as_ref().iter().map(|b|format!("{b:02x}")).collect::<String>();
    let facts=json!({"id":id,"expected_sha":request["expected_sha"],"tree":git(source,&["rev-parse","HEAD^{tree}"])?,
        "parent":binding["parent"],"owner":binding["owner"],"source":source,"script":script,"script_sha256":digest,
        "target_pid":target,"target_created":instance::process_start(target),"watcher_pid":std::process::id(),"at":now_epoch(),"phase":"admitted"});
    wa_operation::atomic_json(&dir.join("effect.json"),&facts)?;
    wa_operation::atomic_json(&active_file,&facts)?;
    record(request,id,"spawned","effect reserved before spawn; outcome requires fresh actual installer verification")?;
    Ok(script)
}

pub(crate) fn verify_install(id:&str) -> Result<Value> {
    verify_install_inner(id, None, false)
}

// Compare the full admitted generation, not just a request id/source. A reused
// or replaced reservation cannot be settled by an earlier request's proof.
fn same_effect(active:&Value,effect:&Value)->bool {
    let (Some(mut active),Some(mut effect))=(active.as_object().cloned(),effect.as_object().cloned()) else {return false;};
    for key in ["phase","verified_at","retired_at"] {active.remove(key);effect.remove(key);}
    active==effect
}

pub(crate) fn reservation_released(active:&Value)->Result<bool> {
    if active["phase"]=="verified" {return Ok(true);}
    if active["phase"]!="aborted_preinstall" {return Ok(false);}
    let id=active["id"].as_str().context("preinstall_receipt_id_missing")?;
    let receipt:Value=serde_json::from_slice(&std::fs::read(sentinel_dir().join("deploy-protocol").join(id).join("preinstall-retirement.json"))?)?;
    Ok(receipt["ok"]==true && receipt["installation_occurred"]==false && receipt["effect_replayed"]==false
        && receipt["reservation_released"]==true && same_effect(active,&receipt["effect"]))
}

/// Retire ONLY an installer positively known to have exited before replacement:
/// exact capture + unchanged live target creation generation + exact retained source.
/// This never calls the installer or claims installation verification.
pub(crate) fn retire_preinstall(id:&str,reason:&str)->Result<Value> {
    if std::env::var("WASM_AGENT_IN_TURN").as_deref()==Ok("1") {bail!("preinstall_retirement_requires_external_executor");}
    if reason.trim().is_empty() || reason.len()>600 || reason.contains(['\n','\r','\0']) {bail!("preinstall_reason_required");}
    if id.is_empty() || !id.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'-') {bail!("preinstall_id_invalid");}
    let lock=open_lock(&sentinel_dir().join("protocol-effect.lock"))?;lock.lock()?;
    let dir=sentinel_dir().join("deploy-protocol").join(id);
    let intent:Value=serde_json::from_slice(&std::fs::read(dir.join("intent.json"))?)?;validate(&intent,id)?;
    let binding=sentinel_return::bind_parent(id)?;
    if binding["owner"]!=intent["owner"] {bail!("preinstall_owner_mismatch");}
    let effect:Value=serde_json::from_slice(&std::fs::read(dir.join("effect.json"))?)?;
    let mut active:Value=serde_json::from_slice(&std::fs::read(sentinel_dir().join("protocol-effect.json"))?)?;
    if !same_effect(&active,&effect) || active["phase"]!="admitted" {bail!("preinstall_reservation_mismatch");}
    let root=canonical_root()?;let current=git(&root,&["rev-parse","HEAD"])?;canonical_script(&current)?;
    git(&root,&["merge-base","--is-ancestor",intent["expected_sha"].as_str().context("preinstall_sha_missing")?,&current])?;
    let script=git(&root,&["show",&format!("{}:scripts/deploy.sh",intent["expected_sha"].as_str().unwrap())])?;
    // Git stdout trim affects the final newline; digest the blob through output, not git()'s text view.
    let raw=quiet_command("git").arg("-C").arg(&root).args(["show",&format!("{}:scripts/deploy.sh",intent["expected_sha"].as_str().unwrap())]).output()?;
    if !raw.status.success() || hex_digest(&raw.stdout)!=effect["script_sha256"].as_str().unwrap_or("") {bail!("preinstall_script_identity_mismatch");}
    if !script.contains("# 1. Clean.") || !script.contains("installing through upgrade.sh") {bail!("preinstall_script_contract_unrecognized");}
    let target=verify_target(node_port(),true)?;
    if effect["target_pid"].as_u64()!=Some(target as u64) || effect["target_created"].as_u64()!=instance::process_start(target) {bail!("preinstall_target_generation_changed");}
    let node:Value=serde_json::from_slice(&std::fs::read(sentinel_dir().join("node.json"))?)?;
    let binary=installed_binary();
    if node["pid"]!=target || node["process_start"]!=effect["target_created"] || node["binary_sha256"].as_str()!=Some(hex_digest(&std::fs::read(&binary)?).as_str()) {bail!("preinstall_node_artifact_changed");}
    let state:Value=serde_json::from_slice(&std::fs::read(dir.join("state.json"))?)?;
    if state["id"]!=id || state["expected_sha"]!=intent["expected_sha"] || effect["id"]!=id
        || effect["expected_sha"]!=intent["expected_sha"] || !instance::same_path(&root,Path::new(effect["source"].as_str().unwrap_or(""))) {bail!("preinstall_source_or_state_mismatch");}
    if dir.join("result.json").exists() {bail!("preinstall_result_exists; use ordinary verification");}
    let capture=std::fs::read(deploy_capture_path())?;let text=std::str::from_utf8(&capture)?;
    let stanza=preinstall_capture(&intent,&effect,&state,text)?;
    if verify_target(node_port(),true)?!=target || instance::process_start(target)!=effect["target_created"].as_u64() {bail!("preinstall_target_changed_during_proof");}
    let evidence=dir.join(format!("preinstall-evidence-{}",std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos()));std::fs::create_dir_all(&evidence)?;
    for name in ["intent.json","binding.json","effect.json","state.json","return-status.json","observation.json"] {let file=dir.join(name);if file.exists(){std::fs::copy(file,evidence.join(name))?;}}
    std::fs::copy(sentinel_dir().join("protocol-effect.json"),evidence.join("reservation.json"))?;
    std::fs::write(evidence.join("deploy.out"),&capture)?;std::fs::write(evidence.join("exact-stanza.txt"),stanza)?;
    let receipt=json!({"ok":true,"id":id,"effect":effect,"reason":reason,"at":now_epoch(),"target_pid":target,
        "target_created":instance::process_start(target),"capture_sha256":hex_digest(&capture),"evidence":evidence,
        "installation_occurred":false,"effect_replayed":false,"reservation_released":true});
    wa_operation::atomic_json(&dir.join("preinstall-retirement.json"),&receipt)?;
    active["phase"]=json!("aborted_preinstall");active["retired_at"]=json!(now_epoch());
    wa_operation::atomic_json(&sentinel_dir().join("protocol-effect.json"),&active)?;
    record(&intent,id,"failed","explicit unchanged-target pre-install retirement; original failure preserved; no installation or replay")?;
    Ok(receipt)
}
fn hex_digest(bytes:&[u8])->String {ring::digest::digest(&ring::digest::SHA256,bytes).as_ref().iter().map(|b|format!("{b:02x}")).collect()}
fn preinstall_capture<'a>(intent:&Value,effect:&Value,state:&Value,text:&'a str)->Result<&'a str> {
    let header=deploy_capture_header(Path::new(effect["script"].as_str().context("preinstall_script_missing")?),intent["reason"].as_str().unwrap_or(""),"detached",effect["at"].as_u64().context("preinstall_at_missing")?);
    let positions=text.match_indices(&header).collect::<Vec<_>>();if positions.len()!=1 {bail!("preinstall_capture_not_unique");}
    let tail=&text[positions[0].0+header.len()..];
    let pid=state["detail"].as_str().and_then(|s|s.strip_prefix("pid ")).and_then(|s|s.split(',').next()).and_then(|s|s.parse::<u32>().ok()).context("preinstall_spawn_pid_missing")?;
    let ending=format!("--- deploy pid {pid} exited with exit code: 1 after ");
    let stop=tail.find(&ending).context("preinstall_owned_exit_missing")?;
    let end=tail[stop..].find('\n').map(|n|stop+n+1).context("preinstall_owned_exit_incomplete")?;
    let duration=&tail[stop+ending.len()..end-1];
    if !duration.ends_with('s') || duration[..duration.len()-1].parse::<f64>().ok().is_none_or(|v|!v.is_finite()||v<0.0) {bail!("preinstall_exit_duration_invalid");}
    let stanza=&tail[..end];
    if !stanza.contains("dirname: command not found") || !stanza.contains("date: command not found")
        || !stanza.contains("deploy: the tree has  uncommitted change(s); commit or stash them first")
        || stanza.contains("deploy: building") || stanza.contains("installing through upgrade.sh") || stanza.contains("upgrade:")
        || stanza[..stop].contains("--- deploy") {bail!("preinstall_capture_boundary_unproven");}
    Ok(stanza)
}

/// Explicit verification-only recovery after a terminal failed return. Never
/// reset observer/delivery cursors or call the installer. Original evidence stays.
pub(crate) fn reconcile(id:&str,reason:&str)->Result<Value> {
    if std::env::var("WASM_AGENT_IN_TURN").as_deref()==Ok("1") {bail!("protocol_reconcile_requires_external_executor");}
    if reason.trim().is_empty() || reason.len()>600 || reason.contains(['\n','\r','\0']) {bail!("protocol_reconcile_reason_required");}
    verify_install_inner(id,Some(reason),false)
}

fn historical_native_identity()->Result<Value> {
    let node=verify_target(node_port(),true).context("historical_native_node_not_owned")?;
    if watcher_state()?!=WatcherState::Running {bail!("historical_watcher_lifetime_unconfirmed");}
    let watcher:u32=std::fs::read_to_string(pid_path())?.trim().parse()?;
    let installed=installed_binary();let sentinel=installed.parent().context("historical_install_parent")?.join(if cfg!(windows){"wa-sentinel.exe"}else{"wa-sentinel"});
    let image=instance::process_image(watcher).context("historical_watcher_image_missing")?;
    if !instance::same_path(&image,&sentinel) {bail!("historical_watcher_image_mismatch");}
    Ok(json!({"node":node,"node_created":instance::process_start(node).context("historical_node_creation_missing")?,
        "watcher":watcher,"watcher_created":instance::process_start(watcher).context("historical_watcher_creation_missing")?}))
}

/// Explicit historical verification: current published main may have advanced,
/// but installed source/artifacts must still match the original admitted effect.
pub(crate) fn reconcile_historical(id:&str,reason:&str)->Result<Value> {
    if std::env::var("WASM_AGENT_IN_TURN").as_deref()==Ok("1") {bail!("protocol_reconcile_requires_external_executor");}
    if reason.trim().is_empty() || reason.len()>600 || reason.contains(['\n','\r','\0']) {bail!("protocol_reconcile_reason_required");}
    verify_install_inner(id,Some(reason),true)
}

fn verify_install_inner(id:&str,reconcile_reason:Option<&str>,historical:bool) -> Result<Value> {
    if id.is_empty() || id.len()>200 || !id.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'-') {bail!("protocol_id_invalid");}
    // Hold admission while observing and settling the exact current generation.
    // This is not an effect replay and grants no installation authority.
    let install_lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(sentinel_dir().join("protocol-effect.lock"))?;
    install_lock.lock()?;
    let dir=sentinel_dir().join("deploy-protocol").join(id);
    let active_file=sentinel_dir().join("protocol-effect.json");
    let effect:Value=serde_json::from_slice(&std::fs::read(dir.join("effect.json")).context("verification_effect_missing")?)?;
    let active=if active_file.exists(){Some(serde_json::from_slice::<Value>(&std::fs::read(&active_file)?)?)}else{None};
    if let Some(reason)=reconcile_reason {
        let active=active.as_ref().context("protocol_reconcile_reservation_missing")?;
        if !same_effect(active,&effect) || !["admitted","verified"].contains(&active["phase"].as_str().unwrap_or("")) {bail!("protocol_reconcile_reservation_mismatch");}
        let generation=dir.join("reconciliations").join(format!("{}-{}",now_epoch(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos()));
        std::fs::create_dir_all(&generation)?;
        let generation=std::fs::canonicalize(&generation)?;
        for name in ["intent.json","binding.json","ack.json","effect.json","result.json","state.json","observation.json","return-status.json","pending-return.json","installation-observation.json"] {
            let file=dir.join(name);
            if file.exists(){std::fs::copy(file,generation.join(name)).with_context(||format!("archive reconciliation evidence {name}"))?;}
        }
        std::fs::copy(&active_file,generation.join("reservation.json")).context("archive reconciliation reservation")?;
        wa_operation::atomic_json(&generation.join("intent.json.reconcile"),&json!({"id":id,"reason":reason,"at":now_epoch(),"effect_replayed":false}))?;
    }
    let intent:Value=serde_json::from_slice(&std::fs::read(dir.join("intent.json"))?)?;
    validate(&intent,id)?;
    let binding=sentinel_return::bind_parent(id)?;
    if binding["owner"]!=intent["owner"] {bail!("verification_owner_mismatch");}
    let canonical=canonical_root()?;
    let expected=if historical {git(&canonical,&["rev-parse","HEAD"])?}else{intent["expected_sha"].as_str().context("expected_sha_missing")?.to_owned()};
    let script=canonical_script(&expected)?;
    let root=script.parent().and_then(Path::parent).context("verification_root_missing")?;
    let install=installed_binary().parent().context("install_parent_missing")?.to_path_buf();
    if historical && (!instance::same_path(Path::new(effect["source"].as_str().unwrap_or("")),root)
        || !instance::same_path(Path::new(effect["script"].as_str().unwrap_or("")),&script)) {bail!("historical_effect_source_path_mismatch");}
    let native=if historical {Some(historical_native_identity()?)}else{None};
    let mut command=quiet_command("node");
    if historical {command.arg(root.join("scripts/sentinel-historical-proof.mjs"));}
    else {command.arg(root.join("scripts/sentinel-install-proof.mjs")).arg("verify");}
    let output=command.arg(root).arg(&install).arg(dir.join("intent.json")).arg(dir.join("binding.json")).arg(&dir)
        .env("WA_PORT",node_port().to_string()).env("WA_DEPLOY_ROOT",root).output()?;
    if let Some(native)=native {if historical_native_identity()?!=native {bail!("historical_native_generation_changed");}}
    let nonce=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos();
    std::fs::write(dir.join(format!("proof-{nonce}.stdout")),&output.stdout)?;
    std::fs::write(dir.join(format!("proof-{nonce}.stderr")),&output.stderr)?;
    if !output.status.success() {bail!("actual_verification_failed:{}",String::from_utf8_lossy(&output.stderr));}
    let proof:Value=serde_json::from_slice(&output.stdout)?;
    if proof["ok"]!=true || proof["request_id"]!=id || proof["expected_sha"]!=intent["expected_sha"]
        || proof["owner"]!=binding["owner"] || proof["parent"]!=binding["parent"] {bail!("actual_verification_identity_mismatch");}
    if historical && (proof["suite"]!="verify-historical-install" || proof["failed"]!=0 || proof["skipped"]!=0
        || proof["current_source"]!=expected || proof["tree"]!=effect["tree"]) {bail!("historical_verification_identity_mismatch");}
    wa_operation::atomic_json(&dir.join(if historical {"historical-verification.json"}else{"verification.json"}),&proof)?;
    if let Some(mut active)=active {
        if active["id"]==id && active["expected_sha"]==intent["expected_sha"] {
            if !same_effect(&active,&effect) {bail!("verification_reservation_generation_mismatch");}
            active["phase"]=json!("verified");active["verified_at"]=proof["at"].clone();
            wa_operation::atomic_json(&active_file,&active)?;
        }
    }
    if reconcile_reason.is_some() {
        audit("protocol-reconciled",id,"fresh actual installation proof settled reservation; no installer replay or return cursor reset");
        return Ok(json!({"ok":true,"id":id,"expected_sha":intent["expected_sha"],"reservation":"verified","effect_replayed":false,
            "original_returns_preserved":true,"proof":proof}));
    }
    Ok(proof)
}

/// Intake has its own read-only lane, so slow health/git/verifier work cannot delay new acknowledgements.
pub(crate) fn scan_intake() -> Result<()> {
    for entry in std::fs::read_dir(sentinel_dir().join("requests"))?.flatten() {
        let path=entry.path();if path.extension().and_then(|v|v.to_str())!=Some("json") {continue;}
        let id=path.file_stem().and_then(|s|s.to_str()).unwrap_or("");
        if let Ok(bytes)=std::fs::read(&path) {
            match serde_json::from_slice::<Value>(&bytes) {
                Ok(v)=>{if let Err(e)=intake(&v,id){audit("intake-problem",id,&e.to_string());}},
                Err(e)=>{let problems=sentinel_dir().join("intake-problems");std::fs::create_dir_all(&problems)?;
                    let safe=id.bytes().map(|b|format!("{b:02x}")).collect::<String>();
                    let hash=ring::digest::digest(&ring::digest::SHA256,&bytes).as_ref().iter().map(|b|format!("{b:02x}")).collect::<String>();
                    let file=problems.join(format!("malformed-{safe}-{hash}.json"));
                    if !file.exists(){wa_operation::atomic_json(&file,&json!({"id":id,"raw_bytes":bytes,"detail":e.to_string(),"at":now_epoch()}))?;}}
            }
        }
    }
    Ok(())
}

fn git(root: &Path, args: &[&str]) -> Result<String> {
    let output = quiet_command("git").arg("-C").arg(root).args(args).output()?;
    if !output.status.success() { bail!("canonical source git check failed: {}", String::from_utf8_lossy(&output.stderr)); }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Select only the configured runtime repository's PRIMARY checkout. No request-supplied path.
/// Revalidate at dispatch; deploy.sh revalidates the source SHA before building and before swapping.
fn canonical_root() -> Result<PathBuf> {
    let record = installed_binary().parent().context("install parent")?.join("runtime-worktree.txt");
    let runtime = PathBuf::from(std::fs::read_to_string(&record).context("configured runtime-worktree missing")?.trim());
    let common = PathBuf::from(git(&runtime, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?);
    let canonical = common.parent().context("canonical git parent")?;
    if canonical.join(".git").is_dir() == false { bail!("runtime shared Git has no canonical primary checkout"); }
    let canonical_common = PathBuf::from(git(canonical, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?);
    if std::fs::canonicalize(&common)? != std::fs::canonicalize(canonical_common)? { bail!("runtime root identity changed"); }
    Ok(canonical.to_path_buf())
}

pub(crate) fn canonical_script(expected: &str) -> Result<PathBuf> {
    let root=canonical_root()?;let canonical=root.as_path();
    if git(canonical, &["symbolic-ref", "--short", "HEAD"])? != "main" { bail!("canonical checkout is not main"); }
    if !git(canonical, &["status", "--porcelain"])?.is_empty() { bail!("canonical checkout is dirty"); }
    if git(canonical, &["rev-parse", "HEAD"])? != expected || git(canonical, &["rev-parse", "origin/main"])? != expected {
        bail!("canonical source is not exact expected pushed origin/main SHA");
    }
    // A local tracking ref alone is not proof that this SHA is still published.
    let published = git(canonical, &["ls-remote", "origin", "refs/heads/main"])?;
    if published.split_whitespace().next() != Some(expected) { bail!("remote main does not name expected SHA"); }
    let script = canonical.join("scripts").join("deploy.sh");
    if !script.is_file() { bail!("canonical deploy.sh missing"); }
    Ok(script)
}
