use super::*;

struct Environment(Vec<(&'static str, Option<std::ffi::OsString>)>);
impl Environment {
    fn set(values: &[(&'static str, &std::ffi::OsStr)]) -> Self {
        let saved = values.iter().map(|(key, value)| {
            let old = std::env::var_os(key); std::env::set_var(key, value); (*key, old)
        }).collect();
        Self(saved)
    }
}
impl Drop for Environment {
    fn drop(&mut self) { for (key, value) in &self.0 { match value {
        Some(value) => std::env::set_var(key, value), None => std::env::remove_var(key),
    } } }
}

#[test]
fn javascript_requests_run_native_node_and_preflight_before_any_operation() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let node = script_runner::node_runtime().expect("Node is a declared requirement for this fixture");
    let home = std::env::temp_dir().join(format!("wa-node-scripts-{}-{}", std::process::id(), now_epoch()));
    let allowed = home.join("allowed space & ü");
    std::fs::create_dir_all(&allowed).unwrap();
    let _env = Environment::set(&[("WASM_AGENT_HOME", home.as_os_str()), ("WA_SENTINEL_SCRIPTS", allowed.as_os_str()), ("WA_SENTINEL_NODE", node.as_os_str()), ("PATH", std::ffi::OsStr::new(""))]);
    for dir in ["claimed", "done", "failed"] { std::fs::create_dir_all(sentinel_dir().join(dir)).unwrap(); }
    for (name, extension, code) in [("common", "CJS", 0), ("module", "mjs", 0), ("javascript", "js", 0), ("failure", "cjs", 7)] {
        let script = allowed.join(format!("{name} probe.{extension}"));
        let module = if extension == "mjs" { "import fs from 'node:fs';" } else { "const fs = require('node:fs');" };
        let marker = allowed.join(format!("{name}.effect"));
        let text = format!("{module}\nfs.writeFileSync({}, 'exact effect');\nconsole.log(JSON.stringify({{ok:true,runtime:'node',name:'{name}'}}));\nconsole.error('retained node stderr');\nprocess.exit({code});\n", serde_json::to_string(&marker.display().to_string()).unwrap());
        std::fs::write(&script, text).unwrap();
        let canonical = approved_script(script.to_str().unwrap()).unwrap();
        let (program, args) = run_script_command(&canonical).unwrap();
        assert_eq!(std::fs::canonicalize(program).unwrap(), node);
        assert_eq!(args.len(), 2); assert_eq!(args[0], "--");
        assert!(args[1].contains("space & ü")); assert!(!args[1].starts_with(r"\\?\"));
        let claim = sentinel_dir().join(format!("claimed/{name}.json"));
        let request = json!({"verb":"run","script":script,"reason":"private native Node dispatch"});
        wa_operation::atomic_json(&claim, &request).unwrap();
        finish_request(&claim, &request);
        let original = sentinel_dir().join(format!("{}/{name}.json", if code == 0 { "done" } else { "failed" }));
        let receipt: Value = serde_json::from_slice(&std::fs::read(original).unwrap()).unwrap();
        assert_eq!(receipt["ok"], code == 0); assert!(!claim.exists());
        assert_eq!(std::fs::read_to_string(marker).unwrap(), "exact effect");
    }
    let operations = sentinel_dir().join("operations");
    let states: Vec<Value> = std::fs::read_dir(&operations).unwrap().filter_map(|entry| {
        let file = entry.ok()?.path().join("state.json");
        serde_json::from_slice(&std::fs::read(file).ok()?).ok()
    }).collect();
    assert_eq!(states.len(), 4);
    assert_eq!(states.iter().filter(|state| state["code"] == 7).count(), 1);
    assert_eq!(states.iter().filter(|state| state["code"] == 0).count(), 3);
    for state in states {
        assert_eq!(state["settled"], true); assert_eq!(state["cleanup"], "terminated");
        assert!(state["stdout"].as_str().unwrap().contains("\"runtime\":\"node\""));
        assert!(state["stderr"].as_str().unwrap().contains("retained node stderr"));
    }
    let original_count = std::fs::read_dir(&operations).unwrap().count();
    std::env::set_var("WA_SENTINEL_NODE", home.join("missing-node"));
    let outside = home.join("outside.cjs"); std::fs::write(&outside, "throw Error('must not run');").unwrap();
    assert!(verb_run(outside.to_str().unwrap(), "allowlist first").unwrap_err().to_string().contains("not inside"));
    let script = allowed.join("missing-runtime.cjs");
    std::fs::write(&script, "throw Error('must not run');").unwrap();
    assert!(verb_run(script.to_str().unwrap(), "preflight").unwrap_err().to_string().contains("node_runtime_unavailable"));
    assert_eq!(std::fs::read_dir(&operations).unwrap().count(), original_count, "missing runtime must admit no operation");
    std::env::set_var("WA_SENTINEL_NODE", "node");
    assert!(run_script_command(&script).unwrap_err().to_string().contains("absolute executable"));
    // A detached watcher with no Node on PATH can use the standard Windows install.
    std::env::remove_var("WA_SENTINEL_NODE");
    std::env::set_var("PATH", home.join("empty-bin"));
    #[cfg(windows)] {
        if std::env::var_os("ProgramFiles").is_some_and(|p| PathBuf::from(p).join("nodejs/node.exe").is_file()) {
            assert!(script_runner::node_runtime().unwrap().is_file());
        }
    }
    std::env::set_var("WA_SENTINEL_NODE", &node);
    eprintln!("private JavaScript request proof retained {}", home.display());
}

#[test]
fn job_run_prepare_and_pipeline_use_the_same_native_node_dispatch() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let node = script_runner::node_runtime().expect("Node is a declared requirement for this fixture");
    let home = std::env::temp_dir().join(format!("wa-node-job-scripts-{}-{}", std::process::id(), now_epoch()));
    let allowed = home.join("approved scripts with space"); std::fs::create_dir_all(&allowed).unwrap();
    let _env = Environment::set(&[("WASM_AGENT_HOME", home.as_os_str()), ("WA_SENTINEL_SCRIPTS", allowed.as_os_str()), ("WA_SENTINEL_NODE", node.as_os_str())]);
    let store = wa_jobs::Store::new(home.join("private-jobs.sqlite"));
    let script = allowed.join("exact.cjs");
    std::fs::write(&script, "const fs=require('node:fs'); const event=JSON.parse(fs.readFileSync(process.env.WA_JOB_EVENT_FILE,'utf8')); console.log(JSON.stringify({ok:true,instruction:'native prepared',event:event.value}));\n").unwrap();
    let action = json!({"kind":"run","script":script,"timeout_seconds":10});
    store.put(&json!({"id":"node-dispatch","name":"private Node dispatch","trigger":{"kind":"event","topic":"private.node"},"action":action})).unwrap();
    let enabled = store.enable("node-dispatch", true).unwrap();
    let rev = enabled["revision"].as_i64().unwrap();
    store.enqueue("node-dispatch", rev, "private-node-event", &json!({"value":17}), now_epoch() as i64).unwrap();
    let delivery = store.claim(now_epoch() as i64, 6).unwrap().unwrap();
    assert!(jobs::execute(&store, &delivery).unwrap().contains("completed"));
    assert_eq!(jobs::run_prepare(&store, "node-dispatch", rev, &delivery, &json!({"script":script,"timeout_seconds":10})).unwrap(), "native prepared");
    let result = jobs::run_pipeline_step(&store, "node-dispatch", rev, &delivery, &action, 0).unwrap();
    assert_eq!(result["event"], 17); assert_eq!(result["ok"], true);
    let count = std::fs::read_dir(sentinel_dir().join("operations")).unwrap().filter(|e| e.as_ref().is_ok_and(|e| e.path().join("state.json").is_file())).count();
    assert_eq!(count, 3);
    std::env::set_var("WA_SENTINEL_NODE", home.join("absent-node"));
    assert!(jobs::execute(&store, &delivery).unwrap_err().to_string().contains("node_runtime_unavailable"));
    assert!(jobs::run_prepare(&store, "node-dispatch", rev, &delivery, &json!({"script":script})).unwrap_err().to_string().contains("node_runtime_unavailable"));
    assert!(jobs::run_pipeline_step(&store, "node-dispatch", rev, &delivery, &action, 1).unwrap_err().to_string().contains("node_runtime_unavailable"));
    assert_eq!(std::fs::read_dir(sentinel_dir().join("operations")).unwrap().filter(|e| e.as_ref().is_ok_and(|e| e.path().join("state.json").is_file())).count(), count);
    eprintln!("private JavaScript jobs proof retained {}", home.display());
}
