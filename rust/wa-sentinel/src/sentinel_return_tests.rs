use super::*;
use std::io::{Read,Write};
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
