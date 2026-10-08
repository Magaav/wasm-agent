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
    let target=verify_target(node_port(),true).context("protocol_native_target_not_owned")?;
    let dir=sentinel_dir().join("deploy-protocol").join(id);
    let install_lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(sentinel_dir().join("protocol-effect.lock"))?;
    install_lock.lock()?;
    let active_file=sentinel_dir().join("protocol-effect.json");
    if active_file.exists() {
        let active:Value=serde_json::from_slice(&std::fs::read(&active_file)?)?;
        if active["phase"]!="verified" {bail!("prior_protocol_effect_unsettled:{}; reconcile, never replay",active["id"]);}
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
    verify_install_inner(id, None)
}

// Compare the full admitted generation, not just a request id/source. A reused
// or replaced reservation cannot be settled by an earlier request's proof.
fn same_effect(active:&Value,effect:&Value)->bool {
    let (Some(mut active),Some(mut effect))=(active.as_object().cloned(),effect.as_object().cloned()) else {return false;};
    for key in ["phase","verified_at"] {active.remove(key);effect.remove(key);}
    active==effect
}

/// Explicit verification-only recovery after a terminal failed return. Never
/// reset observer/delivery cursors or call the installer. Original evidence stays.
pub(crate) fn reconcile(id:&str,reason:&str)->Result<Value> {
    if std::env::var("WASM_AGENT_IN_TURN").as_deref()==Ok("1") {bail!("protocol_reconcile_requires_external_executor");}
    if reason.trim().is_empty() || reason.len()>600 || reason.contains(['\n','\r','\0']) {bail!("protocol_reconcile_reason_required");}
    verify_install_inner(id,Some(reason))
}

fn verify_install_inner(id:&str,reconcile_reason:Option<&str>) -> Result<Value> {
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
        for name in ["intent.json","binding.json","ack.json","effect.json","result.json","state.json","observation.json"] {
            let file=dir.join(name);
            if file.exists(){std::fs::copy(file,generation.join(name))?;}
        }
        std::fs::copy(&active_file,generation.join("reservation.json"))?;
        wa_operation::atomic_json(&generation.join("intent.json.reconcile"),&json!({"id":id,"reason":reason,"at":now_epoch(),"effect_replayed":false}))?;
    }
    let intent:Value=serde_json::from_slice(&std::fs::read(dir.join("intent.json"))?)?;
    validate(&intent,id)?;
    let binding=sentinel_return::bind_parent(id)?;
    if binding["owner"]!=intent["owner"] {bail!("verification_owner_mismatch");}
    let script=canonical_script(intent["expected_sha"].as_str().context("expected_sha_missing")?)?;
    let root=script.parent().and_then(Path::parent).context("verification_root_missing")?;
    let install=installed_binary().parent().context("install_parent_missing")?.to_path_buf();
    let output=std::process::Command::new("node").arg(root.join("scripts/sentinel-install-proof.mjs"))
        .arg("verify").arg(root).arg(&install).arg(dir.join("intent.json")).arg(dir.join("binding.json")).arg(&dir)
        .env("WA_PORT",node_port().to_string()).env("WA_DEPLOY_ROOT",root).output()?;
    let nonce=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos();
    std::fs::write(dir.join(format!("proof-{nonce}.stdout")),&output.stdout)?;
    std::fs::write(dir.join(format!("proof-{nonce}.stderr")),&output.stderr)?;
    if !output.status.success() {bail!("actual_verification_failed:{}",String::from_utf8_lossy(&output.stderr));}
    let proof:Value=serde_json::from_slice(&output.stdout)?;
    if proof["ok"]!=true || proof["request_id"]!=id || proof["expected_sha"]!=intent["expected_sha"]
        || proof["owner"]!=binding["owner"] || proof["parent"]!=binding["parent"] {bail!("actual_verification_identity_mismatch");}
    wa_operation::atomic_json(&dir.join("verification.json"),&proof)?;
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
    let output = std::process::Command::new("git").arg("-C").arg(root).args(args).output()?;
    if !output.status.success() { bail!("canonical source git check failed: {}", String::from_utf8_lossy(&output.stderr)); }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Select only the configured runtime repository's PRIMARY checkout. No request-supplied path.
/// Revalidate at dispatch; deploy.sh revalidates the source SHA before building and before swapping.
pub(crate) fn canonical_script(expected: &str) -> Result<PathBuf> {
    let record = installed_binary().parent().context("install parent")?.join("runtime-worktree.txt");
    let runtime = PathBuf::from(std::fs::read_to_string(&record).context("configured runtime-worktree missing")?.trim());
    let common = PathBuf::from(git(&runtime, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?);
    let canonical = common.parent().context("canonical git parent")?;
    if canonical.join(".git").is_dir() == false { bail!("runtime shared Git has no canonical primary checkout"); }
    let canonical_common = PathBuf::from(git(canonical, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?);
    if std::fs::canonicalize(&common)? != std::fs::canonicalize(canonical_common)? { bail!("runtime root identity changed"); }
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
