use super::*;

#[test]
fn run_script_interpreter_is_explicit_and_allowlist_precedes_it() {
    let _lock=ENV_LOCK.lock().unwrap_or_else(|e|e.into_inner());
    let home=std::env::temp_dir().join(format!("wa-run-script-{}-{}",std::process::id(),now_epoch()));
    std::fs::create_dir_all(home.join("allowed with space")).unwrap();
    let allowed=home.join("allowed with space");let script=allowed.join("probe.PS1");
    std::fs::write(&script,"Write-Output 'native PowerShell fixture'\n").unwrap();
    let outside=home.join("outside.ps1");std::fs::write(&outside,"throw 'must never execute'\n").unwrap();
    let oldhome=std::env::var_os("WASM_AGENT_HOME");let oldallow=std::env::var_os("WA_SENTINEL_SCRIPTS");
    std::env::set_var("WASM_AGENT_HOME",&home);std::env::set_var("WA_SENTINEL_SCRIPTS",&allowed);
    assert!(verb_run(outside.to_str().unwrap(),"private refusal").unwrap_err().to_string().contains("not inside"));
    let canonical=approved_script(script.to_str().unwrap()).unwrap();
    #[cfg(windows)] {
        let (program,args)=run_script_command(&canonical).unwrap();
        assert!(program.ends_with("powershell.exe"));
        assert_eq!(&args[..3],["-NoProfile","-NonInteractive","-File"]);
        assert!(!args[3].starts_with("\\\\?\\"));
        assert!(args[3].contains("allowed with space"));
        assert!(verb_run(script.to_str().unwrap(),"private successful effect").unwrap().contains("completed"));
        std::fs::write(&script,"throw 'fixture execution failure'\n").unwrap();
        assert!(verb_run(script.to_str().unwrap(),"private failed effect").is_err());
    }
    #[cfg(not(windows))] {assert!(run_script_command(&canonical).unwrap_err().to_string().contains("requires_windows"));}
    let (_,args)=run_script_command(&allowed.join("ordinary.sh")).unwrap();assert_eq!(args.len(),1);
    std::fs::create_dir_all(sentinel_dir().join("done")).unwrap();
    std::fs::create_dir_all(sentinel_dir().join("requests")).unwrap();
    let claim=sentinel_dir().join("claimed/private-run.json");
    let request=json!({"verb":"run","session":"private-parent","prompt":"collect exact result","reason":"private one shot"});
    let record=json!({"request":request,"ok":true,"detail":"operation private completed","phase":"completed","at":now_epoch()});
    assert!(queue_run_continuation(&claim,&request,&record).is_err(),"no early wake before original result");
    assert_eq!(std::fs::read_dir(sentinel_dir().join("requests")).unwrap().count(),0);
    wa_operation::atomic_json(&sentinel_dir().join("done/private-run.json"),&record).unwrap();
    queue_run_continuation(&claim,&request,&record).unwrap();
    let wake_file=sentinel_dir().join("requests/run-return-private-run.json");
    let wake:Value=serde_json::from_slice(&std::fs::read(&wake_file).unwrap()).unwrap();
    assert_eq!(wake["session"],"private-parent");assert!(wake["prompt"].as_str().unwrap().contains("receipt="));
    queue_run_continuation(&claim,&request,&record).unwrap();
    assert_eq!(std::fs::read_dir(sentinel_dir().join("requests")).unwrap().count(),1,"same identity cannot queue twice");
    std::fs::remove_file(&wake_file).unwrap();
    wa_operation::atomic_json(&sentinel_dir().join("done/run-return-private-run.json"),&json!({"request":wake,"ok":true})).unwrap();
    queue_run_continuation(&claim,&request,&record).unwrap();
    assert_eq!(std::fs::read_dir(sentinel_dir().join("requests")).unwrap().count(),0,"consumed wake never replayed");
    assert!(queue_run_continuation(&claim,&request,&json!({"detail":"outcome unknown"})).unwrap_err().to_string().contains("unknown"));
    // Execute an actual private script through finish_request, not a synthetic green result.
    std::fs::create_dir_all(sentinel_dir().join("claimed")).unwrap();
    std::fs::create_dir_all(sentinel_dir().join("failed")).unwrap();
    for (name,code) in [("actual-success",0),("actual-failure",7)] {
        let script=allowed.join(format!("{name}.sh"));
        std::fs::write(&script,format!("printf 'private retained output\\n'\nexit {code}\n")).unwrap();
        let claim=sentinel_dir().join("claimed").join(format!("{name}.json"));
        let request=json!({"verb":"run","script":script,"session":"private-parent","prompt":"inspect original","reason":name});
        wa_operation::atomic_json(&claim,&request).unwrap();
        let return_file=sentinel_dir().join("requests").join(format!("run-return-{name}.json"));
        assert!(!return_file.exists());
        finish_request(&claim,&request);
        let original=sentinel_dir().join(if code==0{"done"}else{"failed"}).join(format!("{name}.json"));
        let record:Value=serde_json::from_slice(&std::fs::read(&original).unwrap()).unwrap();
        assert_eq!(record["ok"],code==0);
        assert!(return_file.exists(),"known script failure also collects original evidence");
        assert!(!claim.exists());
        let returned:Value=serde_json::from_slice(&std::fs::read(return_file).unwrap()).unwrap();
        assert!(returned["prompt"].as_str().unwrap().contains(&original.display().to_string()));
    }
    let count=std::fs::read_dir(sentinel_dir().join("requests")).unwrap().count();
    assert!(super::request(&["run".into(),"--script".into(),"not-a-script".into(),"--session".into(),"private".into()]).is_err());
    assert_eq!(std::fs::read_dir(sentinel_dir().join("requests")).unwrap().count(),count,"half continuation stores no request");
    for(key,value)in[("WASM_AGENT_HOME",oldhome),("WA_SENTINEL_SCRIPTS",oldallow)]{match value{Some(v)=>std::env::set_var(key,v),None=>std::env::remove_var(key)}}
    eprintln!("private script runner evidence retained {}",home.display());
}
