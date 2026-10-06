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
    for(key,value)in[("WASM_AGENT_HOME",oldhome),("WA_SENTINEL_SCRIPTS",oldallow)]{match value{Some(v)=>std::env::set_var(key,v),None=>std::env::remove_var(key)}}
    eprintln!("private script runner evidence retained {}",home.display());
}
