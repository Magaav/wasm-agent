use super::*;
#[test]
fn busy_protocol_ack_is_persistent_but_never_completion() {
    let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let home=std::env::temp_dir().join(format!("wa-protocol-{}",std::process::id()));
    let previous=std::env::var_os("WASM_AGENT_HOME");
    std::env::set_var("WASM_AGENT_HOME",&home);
    let request=json!({"verb":"deploy","id":"private-1","expected_sha":"a".repeat(40),"queued_at":now_epoch(),"session":"parent","prompt":"verify"});
    assert!(deploy_protocol::validate(&request,"private-1").unwrap_err().to_string().contains("protocol_quarantined"));
    assert!(perform(&request).unwrap_err().to_string().contains("protocol_quarantined"));
    let started=Instant::now();
    deploy_protocol::record(&request,"private-1","accepted","not complete").unwrap();
    deploy_protocol::record(&request,"private-1","held","busy").unwrap();
    assert!(started.elapsed()<Duration::from_secs(5));
    let dir=sentinel_dir().join("deploy-protocol/private-1");
    let ack:Value=serde_json::from_slice(&std::fs::read(dir.join("ack.json")).unwrap()).unwrap();
    assert_eq!(ack["phase"],"accepted");
    let state:Value=serde_json::from_slice(&std::fs::read(dir.join("state.json")).unwrap()).unwrap();
    assert_eq!(state["phase"],"held");
    assert!(!dir.join("result.json").exists());
    assert!(deploy_protocol::validate(&request,"wrong-id").is_err());
    let mut missing=request.clone();missing.as_object_mut().unwrap().remove("queued_at");
    assert!(deploy_protocol::validate(&missing,"private-1").is_err());
    match previous {Some(v)=>std::env::set_var("WASM_AGENT_HOME",v),None=>std::env::remove_var("WASM_AGENT_HOME")};
    std::fs::remove_dir_all(home).unwrap();
}

#[test]
fn canonical_selection_revalidates_exact_remote_main_without_spawning() {
    let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let home=std::env::temp_dir().join(format!("wa-canonical-{}",std::process::id()));
    std::fs::create_dir_all(home.join("install")).unwrap();
    let root=home.join("repo");std::fs::create_dir_all(root.join("scripts")).unwrap();
    let git=|args:&[&str]| {let out=std::process::Command::new("git").arg("-C").arg(&root).args(args).output().unwrap();assert!(out.status.success(),"{}",String::from_utf8_lossy(&out.stderr));String::from_utf8_lossy(&out.stdout).trim().to_owned()};
    git(&["init","-b","main"]);git(&["config","user.email","fixture@example.invalid"]);git(&["config","user.name","fixture"]);
    std::fs::write(root.join("scripts/deploy.sh"),"never execute fixture selection\n").unwrap();git(&["add","."]);git(&["commit","-m","fixture"]);
    let sha=git(&["rev-parse","HEAD"]);
    git(&["remote","add","origin",root.to_str().unwrap()]);git(&["fetch","origin"]);
    std::fs::write(home.join("install/runtime-worktree.txt"),root.display().to_string()).unwrap();
    let previous=std::env::var_os("WA_INSTALL_DIR");std::env::set_var("WA_INSTALL_DIR",home.join("install"));
    assert_eq!(deploy_protocol::canonical_script(&sha).unwrap(),root.join("scripts/deploy.sh"));
    assert!(deploy_protocol::canonical_script(&"b".repeat(40)).is_err());
    std::fs::write(root.join("dirty"),"changed").unwrap();assert!(deploy_protocol::canonical_script(&sha).is_err());
    std::fs::remove_file(root.join("dirty")).unwrap();git(&["checkout","-b","wrong"]);assert!(deploy_protocol::canonical_script(&sha).is_err());
    match previous {Some(v)=>std::env::set_var("WA_INSTALL_DIR",v),None=>std::env::remove_var("WA_INSTALL_DIR")};
    std::fs::remove_dir_all(home).unwrap();
}
