//! One-shot external exact-source bootstrap when the installed observer predates admission fixes.
//! Same native admission and supported detached installer; never replay an existing intent.
use super::*;

pub(crate) fn execute(expected:&str,owner:&str,parent:&str,reason:&str)->Result<Value> {
    require_external_watcher_lifecycle()?;
    if reason.trim().is_empty() || reason.len()>600 || reason.contains(['\n','\r','\0']) {bail!("bootstrap_reason_required");}
    // Hold participating bootstrap executors while waiting, without changing the observer's lifetime.
    let lock=open_lock(&sentinel_dir().join("bootstrap.lock"))?;
    lock.try_lock().map_err(|_|anyhow::anyhow!("bootstrap_already_owned; no second effect"))?;
    deploy_protocol::canonical_script(expected)?;
    let until=Instant::now()+Duration::from_secs(900);
    loop {
        match sentinel_return::parent_owner(parent) {
            Ok(actual)=>{if actual!=owner {bail!("bootstrap_parent_owner_mismatch");}break;},
            Err(error) if admission_read_contention(&error.to_string()) && Instant::now()<until=>std::thread::sleep(Duration::from_secs(1)),
            Err(error)=>return Err(error),
        }
    }
    if watcher_state()?!=WatcherState::Running || stop_path().exists() {bail!("bootstrap_watcher_not_ready");}
    for lane in ["requests","claimed"] {
        if !deploy_requests_in(&sentinel_dir().join(lane))?.is_empty() {bail!("bootstrap_existing_deploy; inspect original");}
    }
    let active=sentinel_dir().join("protocol-effect.json");
    if active.exists() {
        let prior:Value=serde_json::from_slice(&std::fs::read(active)?)?;
        if !deploy_protocol::reservation_released(&prior)? {bail!("prior_protocol_effect_unsettled; no bootstrap");}
    }
    // In particular, run requests are NOT considered idle just because the requesting model ended.
    // There is no idle override, flag removal, process stop or loop of installer attempts here.
    while node_activity()!=Some(true) {
        if Instant::now()>=until {bail!("bootstrap_idle_unconfirmed; no intent or effect");}
        if stop_path().exists() || watcher_state()?!=WatcherState::Running {bail!("bootstrap_watcher_changed; no effect");}
        std::thread::sleep(Duration::from_millis(500));
    }
    for lane in ["requests","claimed"] {
        if !deploy_requests_in(&sentinel_dir().join(lane))?.is_empty() {bail!("bootstrap_existing_deploy; no effect");}
    }
    let nonce=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos();
    let id=format!("{nonce}-{}-bootstrap",std::process::id());
    let request=json!({"verb":"deploy","id":id,"expected_sha":expected,"owner":owner,"session":parent,"queued_at":now_epoch(),"reason":reason});
    let dir=sentinel_dir().join("deploy-protocol").join(&id);
    std::fs::create_dir_all(&dir)?;
    // Do not let the old observer wake the parent mid-admission for a mere held
    // acknowledgement. Notification resumes once admission settles; no slot reset.
    let observation=open_lock(&dir.join("observation.lock"))?;observation.lock()?;
    deploy_protocol::intake(&request,&id)?;
    // Only proven read refusals before reservation can repeat. All iterations
    // retain one immutable intent and revalidate source/owner/target/positive idle.
    let outcome=loop {
        if stop_path().exists() || watcher_state()?!=WatcherState::Running {break Err(anyhow::anyhow!("bootstrap_watcher_changed; no effect"));}
        if Instant::now()>=until {break Err(anyhow::anyhow!("bootstrap_admission_deadline; no automatic replay"));}
        if node_activity()!=Some(true) {std::thread::sleep(Duration::from_millis(500));continue;}
        let next=perform(&request);
        if let Err(error)=&next {
            let detail=format!("{error:#}");
            if admission_read_contention(&detail) && !dir.join("effect.json").exists() {
                deploy_protocol::record(&request,&id,"held",&detail)?;
                std::thread::sleep(Duration::from_secs(1));continue;
            }
        }
        break next;
    };
    match outcome {
        Ok(detail)=>{
            deploy_protocol::record(&request,&id,"spawned",&detail)?;
            let receipt=json!({"request":request,"ok":true,"phase":"spawned","detail":detail,"at":now_epoch(),"bootstrap":true});
            wa_operation::atomic_json(&sentinel_dir().join("done").join(format!("{id}.json")),&receipt)?;
            audit("bootstrap-deploy",&id,"ordinary native admission; canonical detached installer; not installed yet");
            Ok(json!({"ok":true,"request_id":id,"expected_sha":expected,"phase":"spawned","installation_complete":false,"effect_replayed":false}))
        },
        Err(error)=>{
            let detail=format!("{error:#}");
            deploy_protocol::record(&request,&id,"failed",&detail)?;
            wa_operation::atomic_json(&sentinel_dir().join("failed").join(format!("{id}.json")),&json!({"request":request,"ok":false,"phase":"failed","detail":detail,"at":now_epoch(),"bootstrap":true}))?;
            bail!("bootstrap_admission_failed:{detail}; no automatic second attempt")
        }
    }
}
