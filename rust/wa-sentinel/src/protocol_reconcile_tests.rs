use super::*;

#[test]
fn reservation_settlement_binds_full_effect_generation() {
    let effect=json!({"id":"fixture","expected_sha":"a".repeat(40),"tree":"b".repeat(40),"owner":"owner","parent":"parent",
        "source":"source","script":"source/scripts/deploy.sh","script_sha256":"c".repeat(64),"target_pid":7,"target_created":"generation",
        "watcher_pid":9,"at":123,"phase":"admitted"});
    assert!(same_effect(&effect,&effect));
    let mut verified=effect.clone();verified["phase"]=json!("verified");verified["verified_at"]=json!("2026-10-07T00:00:00Z");
    assert!(same_effect(&verified,&effect));
    for key in ["id","expected_sha","tree","owner","parent","source","script","script_sha256","target_pid","target_created","watcher_pid","at"] {
        let mut changed=effect.clone();changed[key]=json!("other");assert!(!same_effect(&changed,&effect),"{key}");
    }
    assert!(!same_effect(&Value::Null,&effect));
    let mut changed=effect.clone();changed["unknown_field"]=json!(true);assert!(!same_effect(&changed,&effect));
}

#[test]
fn preinstall_capture_requires_exact_early_failure_and_refuses_partial_install() {
    let intent=json!({"reason":"fixture"});let effect=json!({"script":"C:/source/scripts/deploy.sh","at":123});
    let state=json!({"detail":"pid 7, output appended"});
    let header=deploy_capture_header(Path::new("C:/source/scripts/deploy.sh"),"fixture","detached",123);
    let errors="dirname: command not found\ndate: command not found\ndeploy: the tree has  uncommitted change(s); commit or stash them first\n";
    let text=format!("{header}{errors}--- deploy pid 7 exited with exit code: 1 after 0.4s\n");
    assert!(preinstall_capture(&intent,&effect,&state,&text).is_ok());
    for bad in [text.replace("pid 7 exited","pid 8 exited"),text.replace("exit code: 1","exit code: 0"),
        text.replace(errors,&format!("{errors}deploy: installing through upgrade.sh\n")),format!("{text}{text}"),text.replace("dirname: command not found", "unknown error")] {
        assert!(preinstall_capture(&intent,&effect,&state,&bad).is_err(),"{bad}");
    }
}

#[test]
fn reconciliation_inside_turn_refuses_before_touching_runtime_state() {
    let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let original=std::env::var_os("WASM_AGENT_IN_TURN");std::env::set_var("WASM_AGENT_IN_TURN","1");
    assert!(reconcile("fixture","explicit test").unwrap_err().to_string().contains("external_executor"));
    assert!(reconcile_historical("fixture","explicit test").unwrap_err().to_string().contains("external_executor"));
    assert!(retire_preinstall("fixture","explicit test").unwrap_err().to_string().contains("external_executor"));
    assert!(deploy_bootstrap::execute(&"a".repeat(40),"owner","parent","explicit test").unwrap_err().to_string().contains("external_executor"));
    match original {Some(v)=>std::env::set_var("WASM_AGENT_IN_TURN",v),None=>std::env::remove_var("WASM_AGENT_IN_TURN")}
}
