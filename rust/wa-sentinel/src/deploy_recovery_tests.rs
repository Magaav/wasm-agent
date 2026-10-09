use super::*;
use std::io::{Read,Write};
#[test]
fn typed_owner_capacity_is_held_before_reservation_but_other_refusals_fail(){
 let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
 let home=std::env::temp_dir().join(format!("wa-owner-contention-{}-{}",std::process::id(),now_epoch()));
 let previous=std::env::var_os("WASM_AGENT_HOME");let port_before=std::env::var_os("WASM_AGENT_PORT");
 std::env::set_var("WASM_AGENT_HOME",&home);
 for lane in ["requests","claimed","failed","done"]{std::fs::create_dir_all(sentinel_dir().join(lane)).unwrap();}
 let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();std::env::set_var("WASM_AGENT_PORT",listener.local_addr().unwrap().port().to_string());
 let worker=std::thread::spawn(move||{for body in [r#"{"error":"read_capacity_busy"}"#,r#"{"error":"different_503"}"#] {
  let(mut s,_)=listener.accept().unwrap();let mut buf=[0;4096];s.read(&mut buf).unwrap();write!(s,"HTTP/1.1 503 Busy\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).unwrap();
 }});
 let req=json!({"verb":"deploy","id":"capacity-fixture","expected_sha":"a".repeat(40),"queued_at":now_epoch(),"owner":"owner","session":"parent"});
 deploy_protocol::intake(&req,"capacity-fixture").unwrap();let claim=sentinel_dir().join("claimed/capacity-fixture.json");wa_operation::atomic_json(&claim,&req).unwrap();
 finish_request(&claim,&req);
 assert!(sentinel_dir().join("requests/capacity-fixture.json").exists());assert!(!sentinel_dir().join("failed/capacity-fixture.json").exists());
 let dir=sentinel_dir().join("deploy-protocol/capacity-fixture");assert!(!dir.join("effect.json").exists());assert!(!dir.join("binding.json").exists());
 let held:Value=serde_json::from_slice(&std::fs::read(dir.join("state.json")).unwrap()).unwrap();assert_eq!(held["phase"],"held");
 assert!(claim_request(&sentinel_dir().join("requests/capacity-fixture.json"),&claim).unwrap());finish_request(&claim,&req);
 assert!(sentinel_dir().join("failed/capacity-fixture.json").exists());assert!(!dir.join("effect.json").exists());
 worker.join().unwrap();
 for(key,value)in[("WASM_AGENT_HOME",previous),("WASM_AGENT_PORT",port_before)]{match value{Some(v)=>std::env::set_var(key,v),None=>std::env::remove_var(key)}}
 std::fs::remove_dir_all(home).unwrap();
}
