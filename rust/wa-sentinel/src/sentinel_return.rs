//! Return events carry keys, not session authority. Local files are privileged state, not signatures.
use super::*;

fn identity_text(value: &str) -> bool {
    !value.is_empty() && value.len() <= 200 && value.bytes().all(|b|b.is_ascii_alphanumeric() || matches!(b,b'-'|b'_'|b':'|b'.'))
}

pub(crate) fn parent_owner(parent: &str) -> Result<String> {
    if !identity_text(parent) { bail!("parent_identity_invalid"); }
    let agent:ureq::Agent=ureq::Agent::config_builder().timeout_global(Some(Duration::from_secs(3))).build().into();
    let credential=std::env::var("WA_SENTINEL_AUTH_SESSION").unwrap_or_default();
    if credential.is_empty() { bail!("parent_owner_invalid_session"); }
    let response=agent.get(&format!("http://127.0.0.1:{}/session/owner?id={parent}",node_port()))
        .header("X-WA-Session",&credential)
        .call().map_err(|error|anyhow::anyhow!("parent_owner_upstream:{error}"))?;
    let body=response.into_body().read_to_string().context("parent_owner_body_unavailable")?;
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
    if validated_ack(&binding,now_epoch())?.2.is_none() {bail!("check_ack_binding_missing; unknown, never replay");}
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

/// Intake's immutable acknowledgement, never a queue receipt or a guessed clock.
fn validated_ack(binding:&Value,now:u64) -> Result<(Value,u64,Option<Value>)> {
    let intent=&binding["intent"];
    let dir=sentinel_dir().join("deploy-protocol").join(binding["id"].as_str().context("ack_id_missing")?);
    let ack:Value=serde_json::from_slice(&std::fs::read(dir.join("ack.json")).context("ack_missing; unknown, never replay")?)
        .context("ack_corrupt; unknown, never replay")?;
    let object=ack.as_object().context("ack_not_object; unknown, never replay")?;
    if object.len()!=9 || object.keys().any(|k| !["schema","id","expected_sha","session","owner","queued_at","phase","detail","at"].contains(&k.as_str()))
        || ack["schema"]!=1 || ack["id"]!=binding["id"] || ack["expected_sha"]!=intent["expected_sha"]
        || ack["session"]!=intent["session"] || ack["session"]!=binding["parent"]
        || ack["owner"]!=intent["owner"] || (intent.get("owner").is_some() && ack["owner"]!=binding["owner"])
        || ack["queued_at"]!=intent["queued_at"] || !ack["detail"].is_string()
        || !["held","spawned","failed","unknown","verified"].contains(&ack["phase"].as_str().unwrap_or("")) {
        bail!("ack_identity_or_revision_mismatch; unknown, never replay");
    }
    let at=ack["at"].as_u64().context("ack_timestamp_unsupported; unknown, never replay")?;
    if at<intent["queued_at"].as_u64().unwrap_or(u64::MAX) || at>now {bail!("ack_timestamp_invalid; unknown, never replay");}
    let check=match std::fs::read(dir.join("check.json")) {
        Ok(bytes)=>{
            let saved:Value=serde_json::from_slice(&bytes).context("check_ack_binding_corrupt; unknown, never replay")?;
            bound_check(&saved,binding,&ack,at,now)?;
            Some(saved)
        },
        Err(error) if error.kind()==std::io::ErrorKind::NotFound=>{
            // Initial missing-ack UNKNOWN evidence may precede genuine intake. An established
            // check cannot be reset by deleting it, even while its first return is still pending.
            if dir.join("pending-return.json").exists() || dir.join("observation.json").exists() {
                bail!("check_ack_binding_missing; unknown, never replay");
            }
            if dir.join("returns").exists() {
                for entry in std::fs::read_dir(dir.join("returns"))? {
                    let bytes=std::fs::read(entry?.path()).context("check_ack_binding_missing; prior return unreadable")?;
                    let journal:Value=serde_json::from_slice(&bytes).context("check_ack_binding_missing; prior return corrupt")?;
                    if journal["phase"]!="unknown" || !journal["detail"].as_str().unwrap_or("").starts_with("ack_") {
                        bail!("check_ack_binding_missing; unknown, never replay");
                    }
                }
            }
            None
        },
        Err(error)=>return Err(error).context("check_ack_binding_unreadable; unknown, never replay"),
    };
    Ok((ack,at,check))
}

/// One current-check contract for observation, resolution and composed wake instructions.
/// A missing check may be initialized by observation only; malformed state is never replaced.
fn bound_check(saved:&Value,binding:&Value,ack:&Value,ack_at:u64,now:u64) -> Result<()> {
    if saved.as_object().map(|o|o.keys().any(|k|!["id","expected_sha","parent","ack","at","next_at","due_at","coalesced"].contains(&k.as_str()))).unwrap_or(true) {
        bail!("check_ack_binding_unknown; unsupported check revision");
    }
    if saved["ack"]!=*ack {bail!("check_ack_binding_changed_or_legacy; unknown, never replay");}
    let first=ack_at.checked_add(10).context("check_ack_binding_unknown; timestamp overflow")?;
    let at=saved["at"].as_u64();
    let next=saved["next_at"].as_u64();
    if saved["id"]!=binding["id"] || saved["expected_sha"]!=binding["intent"]["expected_sha"] || saved["parent"]!=binding["parent"]
        || at.map(|t|t<ack_at||t>now).unwrap_or(true)
        || next.map(|t|t<first||(t-ack_at)%10!=0).unwrap_or(true) {
        bail!("check_ack_binding_unknown; no queue-time fallback or replay");
    }
    if saved.get("due_at").is_some() || saved.get("coalesced").is_some() {
        let due=saved["due_at"].as_u64().context("check_ack_binding_unknown; due timestamp unsupported")?;
        let at=at.unwrap();
        if due<first || (due-ack_at)%10!=0 || due>at {bail!("check_ack_binding_unknown; due timestamp invalid");}
        let missed=(at-due)/10;
        let expected=missed.checked_add(1).and_then(|n|n.checked_mul(10)).and_then(|n|due.checked_add(n));
        if saved["coalesced"].as_u64()!=Some(missed) || next!=expected {bail!("check_ack_binding_unknown; due revision mismatch");}
    } else if next!=Some(first) {bail!("check_ack_binding_unknown; initial deadline mismatch");}
    Ok(())
}

fn observed_phase(binding:&Value,state:&Value,now:u64) -> (String,String) {
    if let Err(error)=validated_ack(binding,now) {return ("unknown".into(),error.to_string());}
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
        let at=result["at"].as_str().and_then(parse_iso);
        if result["request_id"]!=id || result["expected_sha"]!=intent["expected_sha"] || at.map(|at|at<queued||at>now).unwrap_or(true) {
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

// The deployer emits this exact UTC format. Accept no ambiguous locale or partial timestamp.
fn parse_iso(value:&str) -> Option<u64> {
    let b=value.as_bytes();
    if b.len()!=20 || b[4]!=b'-'||b[7]!=b'-'||b[10]!=b'T'||b[13]!=b':'||b[16]!=b':'||b[19]!=b'Z' {return None;}
    let part=|a:usize,z:usize|{if !b[a..z].iter().all(u8::is_ascii_digit){return None;}std::str::from_utf8(&b[a..z]).ok()?.parse::<i64>().ok()};
    let (mut y,m,d,h,min,s)=(part(0,4)?,part(5,7)?,part(8,10)?,part(11,13)?,part(14,16)?,part(17,19)?);
    if !(1970..=9999).contains(&y)||!(1..=12).contains(&m)||h>23||min>59||s>59 {return None;}
    let leap=y%4==0&&(y%100!=0||y%400==0);
    let days=[31,if leap{29}else{28},31,30,31,30,31,31,30,31,30,31];
    if d<1||d>days[(m-1) as usize] {return None;}
    y-=if m<=2{1}else{0};let era=y/400;let year=y-era*400;
    let mp=m+if m>2{-3}else{9};let doy=(153*mp+2)/5+d-1;
    let epoch=(era*146097+year*365+year/4-year/100+doy-719468)*86400+h*3600+min*60+s;
    u64::try_from(epoch).ok()
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

/// Watch-loop retry metadata is separate from authority/effect evidence. Persist before reporting
/// an error so restarting cannot turn an unavailable owner route into a one-second request storm.
pub(crate) fn observe_backoff(id:&str) -> Result<()> {
    if !identity_text(id) { bail!("return_request_id_invalid"); }
    let dir=sentinel_dir().join("deploy-protocol").join(id);
    let lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true)
        .open(dir.join("observer-retry.lock"))?;
    lock.lock()?;
    let file=dir.join("observer-retry.json");
    let saved=match std::fs::read(&file) {
        Ok(bytes)=>Some(serde_json::from_slice::<Value>(&bytes).context("observer_retry_corrupt; no replay")?),
        Err(error) if error.kind()==std::io::ErrorKind::NotFound=>None,
        Err(error)=>return Err(error).context("observer_retry_unreadable; no replay"),
    };
    let now=now_epoch();
    let mut failures=0;
    if let Some(saved)=saved {
        failures=saved["failures"].as_u64().filter(|n|*n>0 && *n<=6).context("observer_retry_invalid")?;
        let at=saved["at"].as_u64().context("observer_retry_timestamp_invalid")?;
        let next=saved["next_at"].as_u64().context("observer_retry_deadline_invalid")?;
        if saved["id"]!=id || next<at || next-at>300 {bail!("observer_retry_identity_or_deadline_invalid");}
        // Clock rollback cannot impose an unbounded wait: rebase only retry metadata.
        if at>now {
            wa_operation::atomic_json(&file,&json!({"id":id,"failures":failures,"at":now,"next_at":now.saturating_add(300)}))?;
            return Ok(());
        }
        if next>now {return Ok(());}
    }
    match observe(id) {
        Ok(())=>{
            if file.exists(){std::fs::remove_file(&file).context("observer_retry_reset_failed")?;}
            Ok(())
        },
        Err(error)=>{
            failures=(failures+1).min(6);
            let delay=(10u64 << (failures-1)).min(300);
            wa_operation::atomic_json(&file,&json!({"id":id,"failures":failures,"at":now,"next_at":now.saturating_add(delay)}))?;
            Err(error)
        },
    }
}

pub(crate) fn observe(id:&str) -> Result<()> {
    let binding=bind_parent(id)?;
    let dir=sentinel_dir().join("deploy-protocol").join(id);
    let observation_lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join("observation.lock"))?;
    observation_lock.lock()?;
    let mut cursor:Value=std::fs::read(dir.join("observation.json")).ok().and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or(json!({"slot":0,"next_at":0}));
    let now=now_epoch();
    let ack=validated_ack(&binding,now);
    if let Err(error)=&ack {
        // Preserve any prior immutable return, but revoke its delivery authority.
        let key=format!("{id}-{}",cursor["slot"].as_u64().unwrap_or(0));
        let problem=json!({"id":id,"event_key":key,"expected_sha":binding["intent"]["expected_sha"],"parent":binding["parent"],"owner":binding["owner"],"phase":"unknown","at":now,"detail":error.to_string()});
        std::fs::create_dir_all(dir.join("returns"))?;
        let file=dir.join("returns").join(format!("{key}.json"));
        if !file.exists(){wa_operation::atomic_json(&file,&problem)?;}
        wa_operation::atomic_json(&dir.join("ack-problem.json"),&problem)?;
        bail!("{error}");
    }
    let (ack,ack_at,checks)=ack?;
    if cursor["next_at"].as_u64().unwrap_or(0)>now {return Ok(());}
    // Check deadlines exist independently of parent delivery. A busy parent owns one pending event;
    // missed ten-second checks coalesce into the latest durable observation, without extra wakes.
    let checks=checks.unwrap_or(Value::Null);
    let due=checks["next_at"].as_u64().unwrap_or(ack_at+10);
    if checks.is_null(){wa_operation::atomic_json(&dir.join("check.json"),&json!({"id":id,"expected_sha":binding["intent"]["expected_sha"],"ack":ack,"next_at":due,"parent":binding["parent"],"at":now}))?;}
    if now>=due {
        let missed=(now-due)/10;
        let check=json!({"id":id,"expected_sha":binding["intent"]["expected_sha"],"ack":ack,"due_at":due,"at":now,"coalesced":missed,"next_at":due+(missed+1)*10,"parent":binding["parent"]});
        wa_operation::atomic_json(&dir.join(format!("check-{due}.json")),&check)?;
        wa_operation::atomic_json(&dir.join("check.json"),&check)?;
    }
    let slot=cursor["slot"].as_u64().unwrap_or(0);
    let key=format!("{id}-{slot}");
    let file=dir.join("returns").join(format!("{key}.json"));
    let state:Value=std::fs::read(dir.join("state.json")).ok().and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
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

#[cfg(test)]
mod completion_boundary_tests {
    use super::*;
    #[test]
    fn utc_outcomes_refuse_partial_locale_future_and_invalid_calendar_values() {
        let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
        assert_eq!(parse_iso("1970-01-01T00:00:00Z"),Some(0));
        assert_eq!(parse_iso("2026-10-03T00:00:00Z"),Some(1790985600));
        for at in ["", "2026-02-30T00:00:00Z", "2026-10-03T-1:00:00Z", "2026-10-03T00:00:00", "2026-10-03T00:00:00+00:00"] {assert_eq!(parse_iso(at),None,"{at}");}
        let previous=std::env::var_os("WASM_AGENT_HOME");
        let home=std::env::temp_dir().join(format!("wa-return-time-{}-{}",std::process::id(),now_epoch()));
        std::env::set_var("WASM_AGENT_HOME",&home);
        let intent=json!({"id":"private","verb":"deploy","session":"parent","owner":"owner","queued_at":now_epoch(),"expected_sha":"a".repeat(40)});
        deploy_protocol::intake(&intent,"private").unwrap();
        let binding=json!({"id":"private","intent":intent,"parent":"parent","owner":"owner"});
        assert!(validated_ack(&binding,now_epoch()).is_ok());
        let future=json!({"id":"private","expected_sha":"a".repeat(40),"phase":"spawned","at":now_epoch()+1});
        assert_eq!(observed_phase(&binding,&future,now_epoch()).0,"unknown");
        let missing=json!({"id":"private","expected_sha":"a".repeat(40),"phase":"spawned"});
        assert_eq!(observed_phase(&binding,&missing,now_epoch()).0,"unknown");
        match previous{Some(v)=>std::env::set_var("WASM_AGENT_HOME",v),None=>std::env::remove_var("WASM_AGENT_HOME")};
    }
    #[test]
    fn interrupted_submission_never_earns_a_second_http_attempt() {
        let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
        let old=std::env::var_os("WASM_AGENT_HOME");
        let home=std::env::temp_dir().join(format!("wa-sentinel-submit-{}-{}",std::process::id(),now_epoch()));
        std::env::set_var("WASM_AGENT_HOME",&home);
        std::fs::create_dir_all(sentinel_dir().join("deploy-protocol/private")).unwrap();
        let journal=json!({"id":"private","event_key":"private-0"});
        let file=begin_delivery(&journal).unwrap();
        let original=std::fs::read(&file).unwrap();
        assert!(begin_delivery(&journal).unwrap_err().to_string().contains("never replay"));
        assert_eq!(std::fs::read(&file).unwrap(),original);
        eprintln!("unknown submission evidence retained {}",home.display());
        match old{Some(v)=>std::env::set_var("WASM_AGENT_HOME",v),None=>std::env::remove_var("WASM_AGENT_HOME")};
    }
}
