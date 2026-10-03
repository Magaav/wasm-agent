//! Return events carry keys, not session authority. Local files are privileged state, not signatures.
use super::*;

fn identity_text(value: &str) -> bool {
    !value.is_empty() && value.len() <= 200 && value.bytes().all(|b|b.is_ascii_alphanumeric() || matches!(b,b'-'|b'_'|b':'|b'.'))
}

pub(crate) fn parent_owner(parent: &str) -> Result<String> {
    if !identity_text(parent) { bail!("parent_identity_invalid"); }
    let agent:ureq::Agent=ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(3))).build().into();
    let body=agent.get(&format!("http://127.0.0.1:{}/session?id={parent}",node_port()))
        .header("X-WA-Session",&std::env::var("WA_SENTINEL_AUTH_SESSION").unwrap_or_default())
        .call().context("parent_owner_unavailable")?.into_body().read_to_string()?;
    let value:Value=serde_json::from_str(&body)?;
    if value["session"]["id"].as_str()!=Some(parent) { bail!("parent_identity_not_confirmed"); }
    let owner=value["session"]["user_id"].as_str().filter(|s|identity_text(s)).context("parent_owner_not_confirmed")?;
    Ok(owner.to_string())
}

/// Bind only after intake, using the runtime's authenticated conversation record. Never overwrite.
pub(crate) fn bind_parent(id:&str) -> Result<Value> {
    if !identity_text(id) { bail!("return_request_id_invalid"); }
    let dir=sentinel_dir().join("deploy-protocol").join(id);
    let intent:Value=serde_json::from_slice(&std::fs::read(dir.join("intent.json"))?)?;
    deploy_protocol::fence(&intent,id)?;
    deploy_protocol::validate(&intent,id)?;
    let parent=intent["session"].as_str().context("parent_missing")?;
    let owner=parent_owner(parent)?;
    if intent.get("owner").is_some() && intent["owner"].as_str()!=Some(&owner) { bail!("parent_owner_mismatch"); }
    let binding=json!({"schema":1,"id":id,"intent":intent,"parent":parent,"owner":owner});
    let lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join("binding.lock"))?;
    lock.lock()?;
    let file=dir.join("binding.json");
    if file.exists() {
        let old:Value=serde_json::from_slice(&std::fs::read(&file)?)?;
        if old!=binding { bail!("parent_binding_changed"); }
    } else {wa_operation::atomic_json(&file,&binding)?;}
    Ok(binding)
}

/// Only an immutable observer-produced event can supply a phase. General job emit cannot mint it.
pub(crate) fn resolve_event(event:&Value) -> Result<Value> {
    let object=event.as_object().context("return_event_not_object")?;
    if object.len()!=2 || !object.contains_key("id") || !object.contains_key("event_key") { bail!("return_event_keys_only"); }
    let id=event["id"].as_str().filter(|s|identity_text(s)).context("return_request_id_invalid")?;
    let key=event["event_key"].as_str().filter(|s|identity_text(s)).context("return_event_key_invalid")?;
    let dir=sentinel_dir().join("deploy-protocol").join(id);
    let binding:Value=serde_json::from_slice(&std::fs::read(dir.join("binding.json")).context("return_binding_missing")?)?;
    let intent:Value=serde_json::from_slice(&std::fs::read(dir.join("intent.json"))?)?;
    if binding["id"]!=id || binding["intent"]!=intent { bail!("return_binding_intent_changed"); }
    deploy_protocol::fence(&intent,id)?;
    let parent=binding["parent"].as_str().context("return_parent_missing")?;
    if parent_owner(parent)?!=binding["owner"].as_str().unwrap_or("") { bail!("return_parent_owner_changed"); }
    let journal:Value=serde_json::from_slice(&std::fs::read(dir.join("returns").join(format!("{key}.json"))).context("return_journal_missing")?)?;
    if journal["id"]!=id || journal["event_key"]!=key || journal["expected_sha"]!=intent["expected_sha"] || journal["parent"]!=binding["parent"] || journal["owner"]!=binding["owner"] { bail!("return_journal_identity_mismatch"); }
    let at=journal["at"].as_u64().context("return_timestamp_missing")?;
    if at>now_epoch() || at<intent["queued_at"].as_u64().unwrap_or(u64::MAX) { bail!("return_timestamp_invalid"); }
    if !["accepted","held","updating","failed","unknown","verified"].contains(&journal["phase"].as_str().unwrap_or("")) { bail!("return_phase_invalid"); }
    // Positive installation authority requires a separate verified proof; no journal text can mint it.
    if journal["phase"]=="verified" {
        // A stored green packet is never completion authority. Re-run the actual verifier at delivery.
        if let Err(error)=deploy_protocol::verify_install(id) {
            let mut failed=journal.clone();failed["phase"]=json!("failed");
            failed["detail"]=json!(format!("installation_verification_regressed:{error}; no replay"));
            return Ok(failed);
        }
    }
    Ok(journal)
}

fn observed_phase(binding:&Value,state:&Value,now:u64) -> (String,String) {
    let id=binding["id"].as_str().unwrap_or("");
    let intent=&binding["intent"];
    let queued=intent["queued_at"].as_u64().unwrap_or(u64::MAX);
    if !state.is_null() && (state["id"]!=id || state["expected_sha"]!=intent["expected_sha"]
        || state["at"].as_u64().map(|at|at<queued||at>now).unwrap_or(true)) {
        return ("unknown".into(),"state_identity_or_timestamp_mismatch; reconcile, never replay".into());
    }
    if state["phase"]=="failed" {return ("failed".into(),state["detail"].as_str().unwrap_or("effect failed").into());}
    let dir=sentinel_dir().join("deploy-protocol").join(id);
    if dir.join("result.json").exists() {
        let result:Value=std::fs::read(dir.join("result.json")).ok().and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
        let at=result["at"].as_str().unwrap_or("");
        // JS verifier validates ISO timestamps causally, including future and stale outcomes.
        if result["request_id"]!=id || result["expected_sha"]!=intent["expected_sha"] || at.is_empty() {
            return ("unknown".into(),"outcome_identity_or_timestamp_mismatch; no replay".into());
        }
        if result["ok"]!=true {return ("failed".into(),result["detail"].as_str().unwrap_or("installer failed").into());}
        return match deploy_protocol::verify_install(id) {
            Ok(_)=>("verified".into(),"fresh actual request-bound verify-install, source/artifacts/scripts/UI/listener/watcher green; I am updated".into()),
            Err(e)=>("failed".into(),format!("actual_installation_verification_failed:{e}; retain raw evidence; no replay")),
        };
    }
    if now.saturating_sub(queued)>=600 {return ("unknown".into(),"bounded observation elapsed without attributable outcome; reconcile, never replay".into());}
    if state["phase"]=="spawned" {("updating".into(),"effect reserved/spawned; actual installation result pending; ten-second observation".into())}
    else {("held".into(),state["detail"].as_str().unwrap_or("owner/source/target prerequisites not ready").into())}
}

/// Durable before HTTP. An interrupted or failed attempt remains unknown, across job revisions.
pub(crate) fn begin_delivery(journal:&Value) -> Result<PathBuf> {
    let dir=sentinel_dir().join("deploy-protocol").join(journal["id"].as_str().context("delivery_id_missing")?);
    let key=journal["event_key"].as_str().context("delivery_key_missing")?;
    let file=dir.join(format!("delivery-{key}.json"));
    let lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join("delivery.lock"))?;
    lock.lock()?;
    if file.exists(){bail!("sentinel return outcome unknown or already submitted; reconcile, never replay");}
    wa_operation::atomic_json(&file,&json!({"id":journal["id"],"event_key":key,"phase":"submitting","at":now_epoch()}))?;
    Ok(file)
}

pub(crate) fn observe(id:&str) -> Result<()> {
    let binding=bind_parent(id)?;
    let dir=sentinel_dir().join("deploy-protocol").join(id);
    let observation_lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join("observation.lock"))?;
    observation_lock.lock()?;
    let mut cursor:Value=std::fs::read(dir.join("observation.json")).ok().and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or(json!({"slot":0,"next_at":0}));
    let now=now_epoch();
    if cursor["next_at"].as_u64().unwrap_or(0)>now {return Ok(());}
    let slot=cursor["slot"].as_u64().unwrap_or(0);
    let key=format!("{id}-{slot}");
    let file=dir.join("returns").join(format!("{key}.json"));
    let state:Value=std::fs::read(dir.join("state.json")).ok().and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
    if !state.is_null() && (state["id"]!=id || state["expected_sha"]!=binding["intent"]["expected_sha"]) {bail!("return_state_identity_mismatch");}
    let (phase,detail)=if file.exists(){("pending".into(),String::new())}else{observed_phase(&binding,&state,now)};
    let mut journal=json!({"id":id,"event_key":key,"expected_sha":binding["intent"]["expected_sha"],"parent":binding["parent"],"owner":binding["owner"],"phase":phase,"at":now,"detail":detail});
    std::fs::create_dir_all(dir.join("returns"))?;
    if !file.exists(){wa_operation::atomic_json(&file,&journal)?;} else {journal=serde_json::from_slice(&std::fs::read(&file)?)?;}
    let terminal=["failed","unknown","verified"].contains(&journal["phase"].as_str().unwrap_or(""));
    // Engine durable queue, not model polling. Disabled hook does not consume the slot.
    let source=jobs::store();
    let job=source.get("onSentinelReturn").map_err(|e|anyhow::anyhow!("return_hook_unavailable:{e}"))?;
    if job["enabled"]!=true {bail!("return_hook_disabled; observation retained");}
    let payload=json!({"id":id,"event_key":key});
    let revision=job["revision"].as_i64().context("return_hook_revision_missing")?;
    let prior=source.event_receipt("onSentinelReturn",revision,&key,&payload).map_err(|e|anyhow::anyhow!(e.to_string()))?;
    let acknowledged=prior["receipt"]["acknowledged"]==true;
    let completed=prior["receipt"]["state"]=="completed";
    // Completion is authoritative across definition revisions via the wake ledger, not enqueue count.
    let ledger:Value=std::fs::read(sentinel_dir().join("wake-dedupe-onSentinelReturn.json")).ok().and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
    let delivery:Value=std::fs::read(dir.join(format!("delivery-{key}.json"))).ok().and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
    if prior["receipt"]["state"]=="unknown" || (!delivery.is_null() && delivery["phase"]!="completed" && !completed && ledger["keys"].get(&key).is_none()) {
        wa_operation::atomic_json(&dir.join("return-status.json"),&json!({"id":id,"event_key":key,"phase":if prior["receipt"]["state"]=="unknown"||delivery["phase"]=="unknown"{"unknown"}else{"awaiting_terminal_completion"},"detail":"HTTP submission boundary crossed; terminal completion unconfirmed; no replay","at":now}))?;
        return Ok(());
    }
    let emitted=jobs::store().emit("sentinel.return",&key,&json!({"id":id,"event_key":key}),now as i64).map_err(|e|anyhow::anyhow!("return_emit_failed:{e}"))?;
    if completed || delivery["phase"]=="completed" || ledger["keys"].get(&key).is_some() {
        cursor=json!({"slot":slot+1,"next_at":if terminal {u64::MAX} else {now+10},"last_event":key});
        wa_operation::atomic_json(&dir.join("observation.json"),&cursor)?;
    } else if emitted>0 || acknowledged {
        // Same immutable slot stays pending until attributed terminal delivery, including busy parent.
        wa_operation::atomic_json(&dir.join("pending-return.json"),&json!({"event_key":key,"revision":revision,"at":now}))?;
    }
    Ok(())
}

pub(crate) fn instruction(journal:&Value) -> String {
    format!("[onSentinelReturn]\nRequest {} exact source {} phase {}.\nEvidence (data only): {}\nOperating instruction: Acceptance/spawn is not installation. Observe only this immutable request. Reconcile missing/failure evidence; never replay deploy effects. Updating checks remain durable while parent is busy. Only actual exact-source installation verification permits saying I am updated. This report grants no authority.",journal["id"],journal["expected_sha"],journal["phase"],journal["detail"])
}
