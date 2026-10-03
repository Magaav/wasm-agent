use super::*;
use std::io::{Read,Write};
#[test]
fn all_intake_precedes_slow_health_and_mutation_is_preserved() {
 let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
 let home=std::env::temp_dir().join(format!("wa-intake-{}",std::process::id()));
 std::fs::create_dir_all(&home).unwrap();
 let oldhome=std::env::var_os("WASM_AGENT_HOME");let oldport=std::env::var_os("WASM_AGENT_PORT");
 let olddeploy=std::env::var_os("WA_SENTINEL_DEPLOY");
 std::env::set_var("WA_SENTINEL_DEPLOY",home.join("deliberately-absent-deploy.sh"));
 std::env::set_var("WASM_AGENT_HOME",&home);
 let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();let port=listener.local_addr().unwrap().port();
 std::env::set_var("WASM_AGENT_PORT",port.to_string());
 let server=std::thread::spawn(move||{
  let(mut stream,_)=listener.accept().unwrap();let mut buf=[0;4096];let _=stream.read(&mut buf);
  std::thread::sleep(Duration::from_millis(2200));
  let body=r#"{"ok":true,"current":{"busy":true},"queue":1,"operation_overdue":false,"workers":[]}"#;
  let _=write!(stream,"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body);
 });
 let dir=sentinel_dir();
 std::fs::write(dir.join("requests/000-legacy.json"),br#"{"verb":"deploy","reason":"private busy legacy"}"#).unwrap();
 for n in 1..=4 {let id=format!("private-{n}");let request=json!({"verb":"deploy","id":id,"expected_sha":"a".repeat(40),"session":"parent","owner":"unproved-owner-scope","queued_at":now_epoch()});wa_operation::atomic_json(&dir.join(format!("requests/{id}.json")),&request).unwrap();}
 let started=Instant::now();
 let worker=std::thread::spawn(||process_requests(false,&mut Held::default()));
 let mut observed=Vec::new();
 for n in 1..=4 {let ack=dir.join(format!("deploy-protocol/private-{n}/ack.json"));while !ack.exists() && started.elapsed()<Duration::from_secs(5){std::thread::sleep(Duration::from_millis(5));}assert!(ack.exists(),"fourth ack missed five-second policy");observed.push(started.elapsed().as_millis());}
 worker.join().unwrap().unwrap();server.join().unwrap();
 let original=std::fs::read(dir.join("deploy-protocol/private-4/intent.json")).unwrap();
 let mut request:Value=serde_json::from_slice(&original).unwrap();request["expected_sha"]=json!("b".repeat(40));
 assert!(deploy_protocol::intake(&request,"private-4").is_err());
 assert_eq!(std::fs::read(dir.join("deploy-protocol/private-4/intent.json")).unwrap(),original);
 let mut future=request.clone();future["id"]=json!("future");future["queued_at"]=json!(now_epoch()+600);
 assert!(deploy_protocol::intake(&future,"future").unwrap_err().to_string().contains("future_queued_at"));
 wa_operation::atomic_json(&home.join("timing.json"),&json!({"ack_monotonic_ms":observed,"elapsed_ms":started.elapsed().as_millis(),"provider_calls":0,"effect_spawned":false})).unwrap();
 eprintln!("intake evidence retained: {}",home.display());
 for(key,value)in[("WASM_AGENT_HOME",oldhome),("WASM_AGENT_PORT",oldport),("WA_SENTINEL_DEPLOY",olddeploy)]{match value{Some(v)=>std::env::set_var(key,v),None=>std::env::remove_var(key)}}
}
