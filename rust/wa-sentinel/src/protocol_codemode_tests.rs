// Pure/native proof surfaces: no CLI privilege bypass, installer or live state mutation.
use super::*;
use codemode_preinstall as cm;
fn fixture()->(Value,Value,Value,Value,Value,Value,String) {
    let intent=json!({"id":"private","verb":"deploy","expected_sha":cm::SOURCE,"session":"parent","owner":"owner","queued_at":120,"reason":"private"});
    let effect=json!({"id":"private","expected_sha":cm::SOURCE,"tree":cm::TREE,"owner":"owner","parent":"parent","source":"C:/fixture","script":"C:/fixture/scripts/deploy.sh","script_sha256":cm::SCRIPT,"target_pid":11,"target_created":134366169264516753_u64,"watcher_pid":9,"at":123,"phase":"admitted"});
    let state=json!({"schema":1,"id":"private","expected_sha":cm::SOURCE,"session":"parent","queued_at":120,"phase":"spawned","detail":"pid 7, output appended"});
    let node=json!({"pid":11,"process_start":134366169264516753_u64,"binary_sha256":"f".repeat(64)});
    let result=json!({"ok":false,"request_id":"private","expected_sha":cm::SOURCE,"commit":"acde06f0","branch":"main","reason":"private","detail":"native code-mode shipping build/readiness failed; nothing installed","node_sha256":"","sentinel_sha256":"","watcher_pid":""});
    let exit=json!({"schema":1,"id":"private","expected_sha":cm::SOURCE,"effect":effect,"pid":7,"at":128,"elapsed_ms":4781,"effect_replayed":false,"installation_verified":false,"exit":{"wait_ok":true,"success":false,"code":1,"status":"exit code: 1"}});
    let header=deploy_capture_header(Path::new("C:/fixture/scripts/deploy.sh"),"private","detached",123);
    let text=format!("{header}deploy: building\nError: codemode_build:ripgrep_unavailable:prepare_offline_before_build\ndeploy: native code-mode shipping build/readiness failed; nothing installed\n--- deploy pid 7 exited with exit code: 1 after 4.8s\n");
    (intent,effect,state,node,result,exit,text)
}
#[test]
fn codemode_positive_and_complete_native_negative_matrix() {
    let (intent,effect,state,node,result,exit,text)=fixture();
    let binding=json!({"owner":"owner","parent":"parent"});let hash="f".repeat(64);let created=Some(134366169264516753_u64);
    cm::generation(&intent,&effect,&effect,&binding,&state,&node,11,created,&hash).unwrap();
    cm::capture(&intent,&effect,&state,&text,&result,&exit,cm::HELPER).unwrap();
    assert!(embedded_preinstall_capture(&intent,&effect,&state,&text,&result,&exit).is_err(),"old class is not weakened/reused");
    let root=Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().parent().unwrap();
    assert_eq!(hex_digest(&cm::source(root,&intent,&effect).unwrap()),cm::HELPER,"actual retained Git helper blob");
    assert!(cm::capture(&intent,&effect,&state,&text,&result,&exit,&"0".repeat(64)).is_err());
    for key in ["ok","request_id","expected_sha","detail","reason","commit","branch","node_sha256","sentinel_sha256","watcher_pid"] {
        for value in [Value::Null,json!("foreign")] {let mut bad=result.clone();bad[key]=value;assert!(cm::capture(&intent,&effect,&state,&text,&bad,&exit,cm::HELPER).is_err(),"result {key}");}
    }
    for key in ["schema","id","expected_sha","effect","pid","at","elapsed_ms","effect_replayed","installation_verified","exit"] {
        let mut bad=exit.clone();bad[key]=Value::Null;assert!(cm::capture(&intent,&effect,&state,&text,&result,&bad,cm::HELPER).is_err(),"exit {key}");
    }
    for key in ["wait_ok","success","code","status"] {let mut bad=exit.clone();bad["exit"][key]=Value::Null;assert!(cm::capture(&intent,&effect,&state,&text,&result,&bad,cm::HELPER).is_err());}
    for key in ["id","expected_sha","tree","owner","parent","source","script","script_sha256","target_pid","target_created","watcher_pid","at"] {
        let mut bad=effect.clone();bad[key]=json!("foreign");
        assert!(cm::generation(&intent,&bad,&effect,&binding,&state,&node,11,created,&hash).is_err(),"effect {key}");
        let mut changed_exit=exit.clone();changed_exit["effect"]=bad;
        assert!(cm::capture(&intent,&effect,&state,&text,&result,&changed_exit,cm::HELPER).is_err(),"foreign exit effect {key}");
    }
    for key in ["owner","parent"] {let mut bad=effect.clone();bad[key]=json!("foreign");assert!(cm::generation(&intent,&bad,&bad,&binding,&state,&node,11,created,&hash).is_err(),"aligned but foreign {key}");}
    for key in ["pid","process_start","binary_sha256"] {let mut bad=node.clone();bad[key]=json!("foreign");assert!(cm::generation(&intent,&effect,&effect,&binding,&state,&bad,11,created,&hash).is_err());}
    assert!(cm::generation(&intent,&effect,&effect,&binding,&state,&node,12,created,&hash).is_err());
    assert!(cm::generation(&intent,&effect,&effect,&binding,&state,&node,11,Some(created.unwrap()+1),&hash).is_err(),"u64 creation precision preserved");
    assert!(cm::generation(&intent,&effect,&effect,&binding,&state,&node,11,created,&"0".repeat(64)).is_err(),"installed bytes changed");
    for key in ["schema","id","expected_sha","session","queued_at","phase"] {let mut bad=state.clone();bad[key]=Value::Null;assert!(cm::generation(&intent,&effect,&effect,&binding,&bad,&node,11,created,&hash).is_err());}
    let mut drift=intent.clone();drift["expected_sha"]=json!("a".repeat(40));assert!(cm::source(root,&drift,&effect).is_err());
    let mut drift=effect.clone();drift["tree"]=json!("a".repeat(40));assert!(cm::source(root,&intent,&drift).is_err());
    for marker in ["upgrade: started","deploy: installing through upgrade.sh","deploy: the new binary answers on a scratch port","node installed,","deploy: sentinel pid 7 -> 8","source_provenance=clean-built-by-deploy"] {
        let bad=text.replace("deploy: building",&format!("{marker}\ndeploy: building"));assert!(cm::capture(&intent,&effect,&state,&bad,&result,&exit,cm::HELPER).is_err(),"marker {marker}");
    }
    for bad in [format!("{text}{text}"),format!("{text}--- deploy pid 7 exited with exit code: 1 after 4.8s\n"),text.replace("4.8s","4.7s"),text.replace("4.8s","4.781s"),text.replace("4.8s","4.80s"),text.replace("pid 7 exited","pid 8 exited"),text.replace("Error: codemode_build:ripgrep_unavailable:prepare_offline_before_build","unknown failure; nothing installed")] {
        assert!(cm::capture(&intent,&effect,&state,&bad,&result,&exit,cm::HELPER).is_err(),"{bad}");
    }
    assert!(cm::capture(&intent,&effect,&state,&text,&Value::Null,&exit,cm::HELPER).is_err());
    assert!(cm::capture(&intent,&effect,&state,&text,&result,&Value::Null,cm::HELPER).is_err());
}
#[test]
fn codemode_retained_public_packet_is_read_only_and_exact_u64() {
    let Ok(dir)=std::env::var("WA_PREINSTALL_PUBLIC_PACKET") else {return;};let dir=Path::new(&dir);
    let read=|name:&str|->Value{serde_json::from_slice(&std::fs::read(dir.join(name)).unwrap()).unwrap()};
    let manifest=read("manifest.json");for file in manifest["files"].as_array().unwrap(){let p=dir.join(file["name"].as_str().unwrap());assert_eq!(hex_digest(&std::fs::read(p).unwrap()),file["sha256"].as_str().unwrap());}
    let intent=read("intent.json");let effect=read("effect.json");let state=read("state.json");let result=read("result.json");let exit=read("process-exit.json");
    assert_eq!(effect["target_created"].as_u64(),Some(134366169264516753_u64));
    let text=std::fs::read_to_string(dir.join("deploy.out")).unwrap();
    let root=Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().parent().unwrap();
    let current=git(root,&["rev-parse","HEAD"]).unwrap();git(root,&["merge-base","--is-ancestor",cm::SOURCE,&current]).unwrap();
    let target=&manifest["target"];let created=target["process_start"].as_str().unwrap().parse::<u64>().unwrap();
    let node=json!({"pid":target["pid"],"process_start":created,"binary_sha256":target["binary_sha256"]});
    let binding=json!({"owner":intent["owner"],"parent":intent["session"]});
    cm::generation(&intent,&effect,&effect,&binding,&state,&node,target["pid"].as_u64().unwrap() as u32,Some(created),target["binary_sha256"].as_str().unwrap()).unwrap();
    let helper=cm::source(root,&intent,&effect).unwrap();
    let stanza=cm::capture(&intent,&effect,&state,&text,&result,&exit,&hex_digest(&helper)).unwrap();
    assert_eq!(format!("{:.1}",4781_f32/1000.0),"4.8");assert!(stanza.ends_with("after 4.8s\n"));
    // owned_preinstall_stanza excludes the header; the preserved packet includes it.
    assert!(std::fs::read_to_string(dir.join("exact-stanza.txt")).unwrap().ends_with(stanza));
}
#[test]
fn codemode_archive_preserves_notification_unknowns_and_cursors() {
    let base=std::env::var_os("WA_PREINSTALL_TEST_SCRATCH").map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let dir=base.join(format!("codemode-archive-{}",std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
    let out=dir.join("archive");std::fs::create_dir_all(dir.join("returns")).unwrap();std::fs::create_dir(&out).unwrap();
    let bytes=b"{\"phase\":\"unknown\",\"cursor\":7}";
    for name in ["ack.json","return-status.json","observation.json","delivery-key.json","returns/key.json"]{std::fs::write(dir.join(name),bytes).unwrap();}
    cm::archive_json(&dir,&out).unwrap();
    for name in ["ack.json","return-status.json","observation.json","delivery-key.json","returns/key.json"]{assert_eq!(std::fs::read(dir.join(name)).unwrap(),bytes);assert_eq!(std::fs::read(out.join(name)).unwrap(),bytes);}
}
#[test]
fn codemode_child_refusal_precedes_all_live_state_access() {
    let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());let old=std::env::var_os("WASM_AGENT_PROVENANCE");
    std::env::set_var("WASM_AGENT_PROVENANCE","child");
    let error=retire_preinstall("private","test refusal").unwrap_err().to_string();
    assert!(error.contains("external_executor")||error.contains("coordinator_only"));
    match old{Some(v)=>std::env::set_var("WASM_AGENT_PROVENANCE",v),None=>std::env::remove_var("WASM_AGENT_PROVENANCE")}
}
