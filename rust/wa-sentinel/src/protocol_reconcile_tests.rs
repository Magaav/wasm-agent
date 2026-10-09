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
fn reconciliation_inside_turn_refuses_before_touching_runtime_state() {
    let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let original=std::env::var_os("WASM_AGENT_IN_TURN");std::env::set_var("WASM_AGENT_IN_TURN","1");
    assert!(reconcile("fixture","explicit test").unwrap_err().to_string().contains("external_executor"));
    assert!(reconcile_historical("fixture","explicit test").unwrap_err().to_string().contains("external_executor"));
    assert!(deploy_bootstrap::execute(&"a".repeat(40),"owner","parent","explicit test").unwrap_err().to_string().contains("external_executor"));
    match original {Some(v)=>std::env::set_var("WASM_AGENT_IN_TURN",v),None=>std::env::remove_var("WASM_AGENT_IN_TURN")}
}
