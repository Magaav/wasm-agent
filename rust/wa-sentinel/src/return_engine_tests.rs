use super::*;
use std::io::{Read,Write};
use std::sync::{Arc,atomic::{AtomicBool,AtomicUsize,Ordering}};
#[test]
fn connected_observation_uses_real_engine_queue_and_original_parent(){
 let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
 let home=std::env::temp_dir().join(format!("wa-return-engine-{}",std::process::id()));
 let previous=std::env::var_os("WASM_AGENT_HOME");let oldport=std::env::var_os("WASM_AGENT_PORT");
 let _=std::fs::remove_dir_all(&home); // unique process fixture; no prior run state reused
 std::env::set_var("WASM_AGENT_HOME",&home);
 let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();listener.set_nonblocking(true).unwrap();std::env::set_var("WASM_AGENT_PORT",listener.local_addr().unwrap().port().to_string());
 let stop=Arc::new(AtomicBool::new(false));let posts=Arc::new(AtomicUsize::new(0));let stopped=stop.clone();let count=posts.clone();
 let server=std::thread::spawn(move||{while !stopped.load(Ordering::SeqCst){match listener.accept(){Ok((mut stream,_))=>{stream.set_nonblocking(false).unwrap();stream.set_read_timeout(Some(Duration::from_secs(2))).unwrap();let mut buf=[0;16384];let mut n=0;while n<buf.len(){let got=stream.read(&mut buf[n..]).unwrap_or(0);if got==0{break;}n+=got;if buf[..n].windows(4).any(|w|w==b"\r\n\r\n"){break;}}let header_end=buf[..n].windows(4).position(|w|w==b"\r\n\r\n").map(|p|p+4).unwrap_or(n);let headers=String::from_utf8_lossy(&buf[..header_end]).to_ascii_lowercase();let content_length=headers.lines().find_map(|l|l.strip_prefix("content-length:").and_then(|s|s.trim().parse::<usize>().ok())).unwrap_or(0);while n<header_end+content_length && n<buf.len(){let got=stream.read(&mut buf[n..]).unwrap_or(0);if got==0{break;}n+=got;}let request=String::from_utf8_lossy(&buf[..n]);let body=if request.starts_with("POST /chat") {assert!(request.contains("parent"));assert!(!request.contains("victim"));count.fetch_add(1,Ordering::SeqCst);"data: {\"type\":\"done\"}\n\n"}else if request.starts_with("GET /session") {"{\"session\":{\"id\":\"parent\",\"user_id\":\"owner\"}}"}else{"{\"ok\":true}"};eprintln!("PRIVATE HTTP: {request:?} => {body:?}");let _=write!(stream,"HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len());let _=stream.flush();let _=stream.shutdown(std::net::Shutdown::Write);let mut drain=[0;16384];let _=stream.read(&mut drain);},Err(_)=>std::thread::sleep(Duration::from_millis(5))}}});
 let intent=json!({"id":"engine-1","verb":"deploy","expected_sha":"a".repeat(40),"session":"parent","owner":"owner","queued_at":now_epoch()});deploy_protocol::intake(&intent,"engine-1").unwrap();
 let store=jobs::store();let definition:Value=serde_json::from_str(include_str!("../../../jobs/on-sentinel-return.json")).unwrap();store.put(&definition).unwrap();
 let error=sentinel_return::observe("engine-1").unwrap_err();assert!(error.to_string().contains("disabled"),"{error:#}");
 assert_eq!(posts.load(Ordering::SeqCst),0);
 store.enable("onSentinelReturn",true).unwrap();sentinel_return::observe("engine-1").unwrap();
 assert!(store.claim_next(now_epoch() as i64,6,false).unwrap().is_none(),"busy inference lane leaves durable delivery queued");
 let delivery=store.claim_next(now_epoch() as i64,6,true).unwrap().unwrap();let detail=jobs::execute(&store,&delivery).unwrap();store.finish(delivery["id"].as_i64().unwrap(),"completed",&detail,now_epoch() as i64).unwrap();
 assert_eq!(posts.load(Ordering::SeqCst),1);
 assert!(jobs::execute(&store,&delivery).unwrap().contains("already_woken"));assert_eq!(posts.load(Ordering::SeqCst),1);
 sentinel_return::observe("engine-1").unwrap();
 let dir=sentinel_dir().join("deploy-protocol/engine-1");let observation:Value=serde_json::from_slice(&std::fs::read(dir.join("observation.json")).unwrap()).unwrap();assert!(observation["next_at"].as_u64().unwrap()>=now_epoch()+9);
 let mut forged=delivery.clone();forged["event"]["session"]=json!("victim");forged["event"]["event_key"]=json!("forged-new");assert!(jobs::execute(&store,&forged).is_err());
 stop.store(true,Ordering::SeqCst);server.join().unwrap();
 for(key,value)in[("WASM_AGENT_HOME",previous),("WASM_AGENT_PORT",oldport)]{match value{Some(v)=>std::env::set_var(key,v),None=>std::env::remove_var(key)}}
 eprintln!("Engine return raw state retained {}",home.display());
}
