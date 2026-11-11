use super::*;
use std::io::{Read,Write};
#[test]
fn non_run_parent_fields_do_not_enter_run_continuation_validation() {
 let claim=Path::new("private-protocol-deploy.json");
 let request=json!({"verb":"deploy","session":"parent","expected_sha":"a".repeat(40)});
 assert!(validate_run_continuation(&request).is_err(),"legacy run validator would reject protocol shape");
 assert!(queue_run_continuation(claim,&request,&json!({"ok":false})).is_ok(),"non-run must return before filesystem/effect work");
 let run=json!({"verb":"run","session":"parent"});
 assert!(queue_run_continuation(claim,&run,&json!({"ok":false})).is_err(),"real run still requires prompt");
}
#[test]
fn owner_transport_refusal_retains_underlying_cause_without_effect() {
 let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
 let oldport=std::env::var_os("WASM_AGENT_PORT");
 let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();
 let port=listener.local_addr().unwrap().port();drop(listener);
 std::env::set_var("WASM_AGENT_PORT",port.to_string());
 let error=sentinel_return::parent_owner("private-parent").unwrap_err().to_string();
 match oldport {Some(v)=>std::env::set_var("WASM_AGENT_PORT",v),None=>std::env::remove_var("WASM_AGENT_PORT")}
 assert!(error.starts_with("parent_owner_unavailable: "),"{error}");
 assert!(error.len()>"parent_owner_unavailable: ".len(),"underlying cause discarded");
}
#[test]
fn returns_bind_runtime_owner_and_refuse_event_session_authority(){
 let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
 let home=std::env::temp_dir().join(format!("wa-return-owner-{}",std::process::id()));
 let oldhome=std::env::var_os("WASM_AGENT_HOME");let oldport=std::env::var_os("WASM_AGENT_PORT");
 std::env::set_var("WASM_AGENT_HOME",&home);
 let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();std::env::set_var("WASM_AGENT_PORT",listener.local_addr().unwrap().port().to_string());
 let server=std::thread::spawn(move||{for _ in 0..3 {let(mut stream,_)=listener.accept().unwrap();let mut buf=[0;4096];let n=stream.read(&mut buf).unwrap();assert!(String::from_utf8_lossy(&buf[..n]).starts_with("GET /session/owner?id=parent "));let body=r#"{"session":{"id":"parent","user_id":"owner"}}"#;write!(stream,"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();}});
 let intent=json!({"id":"private-1","verb":"deploy","expected_sha":"a".repeat(40),"session":"parent","owner":"owner","queued_at":now_epoch()});
 deploy_protocol::intake(&intent,"private-1").unwrap();
 let binding=sentinel_return::bind_parent("private-1").unwrap();assert_eq!(binding["owner"],"owner");
 assert!(sentinel_return::resolve_event(&json!({"id":"private-1","event_key":"private-1-0","session":"victim","phase":"verified"})).unwrap_err().to_string().contains("keys_only"));
 let dir=sentinel_dir().join("deploy-protocol/private-1/returns");std::fs::create_dir_all(&dir).unwrap();
 let journal=json!({"id":"private-1","event_key":"private-1-0","parent":"parent","owner":"owner","expected_sha":"a".repeat(40),"at":now_epoch(),"phase":"held","detail":"private causal event"});
 wa_operation::atomic_json(&dir.join("private-1-0.json"),&journal).unwrap();
 let ack:Value=serde_json::from_slice(&std::fs::read(dir.parent().unwrap().join("ack.json")).unwrap()).unwrap();
 wa_operation::atomic_json(&dir.parent().unwrap().join("check.json"),&json!({"id":"private-1","expected_sha":intent["expected_sha"],"parent":"parent","ack":ack,"at":now_epoch(),"next_at":ack["at"].as_u64().unwrap()+10})).unwrap();
 assert_eq!(sentinel_return::resolve_event(&json!({"id":"private-1","event_key":"private-1-0"})).unwrap(),journal);
 let mut wrong=journal.clone();wrong["parent"]=json!("victim");wa_operation::atomic_json(&dir.join("private-1-0.json"),&wrong).unwrap();
 assert!(sentinel_return::resolve_event(&json!({"id":"private-1","event_key":"private-1-0"})).is_err());
 server.join().unwrap();
 for(key,value)in[("WASM_AGENT_HOME",oldhome),("WASM_AGENT_PORT",oldport)]{match value{Some(v)=>std::env::set_var(key,v),None=>std::env::remove_var(key)}}
 eprintln!("return owner evidence retained {}",home.display());
}

/// A protocol directory that is not filled in yet is reported as missing its named files, and it does not
/// stop the other directories from being observed.
///
/// Measured on `work` (2026-11-10): five directories without `observation.json` made `protocol observe`
/// return an error on every pass, and the job that calls it retried the same five forever - a spin on a
/// missing file, reported as if the observer were broken.
#[test]
fn missing_observation_files_are_named_and_never_stop_the_pass() {
    let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let home=std::env::temp_dir().join(format!("wa-observe-missing-{}",std::process::id()));
    let _=std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join(".wasm-agent/sentinel/deploy-protocol/empty-one")).unwrap();
    std::fs::create_dir_all(home.join(".wasm-agent/sentinel/deploy-protocol/empty-two")).unwrap();
    let oldhome=std::env::var_os("WASM_AGENT_HOME");
    std::env::set_var("WASM_AGENT_HOME",&home);
    let report=sentinel_return::observe_all();
    match oldhome {Some(v)=>std::env::set_var("WASM_AGENT_HOME",v),None=>std::env::remove_var("WASM_AGENT_HOME")}
    assert_eq!(report["ok"],false,"a partial pass says so: {report}");
    assert_eq!(report["observed"],0,"nothing could be observed: {report}");
    let skipped=report["skipped"].as_array().expect("skipped list");
    assert_eq!(skipped.len(),2,"every incomplete directory is reported, not just the first: {report}");
    for record in skipped {
        let missing=record["missing"].as_array().expect("named files");
        assert!(missing.iter().any(|name|name=="binding.json"),"the missing file is named: {record}");
        assert!(record["detail"].as_str().unwrap_or("").contains("missing: "),"and the detail names them: {record}");
    }
    let _=std::fs::remove_dir_all(&home);
}
