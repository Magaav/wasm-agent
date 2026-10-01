use super::*;
#[test]
#[ignore = "helper process only; parent exercises stable identity and exact owned drain"]
fn legacy_writer_helper() {
    let root=PathBuf::from(std::env::var("WA_LEGACY_TEST_ROOT").unwrap());
    let id=format!("op-fixture-{}-0",std::process::id());
    fs::create_dir_all(root.join(&id)).unwrap();
    let state=json!({"operation_id":id,"owner":"legacy-worker","settled":false,"cleanup":"unknown","containment":"owned_helper_process_no_children","cwd":root.to_string_lossy()});
    atomic_json(&root.join(&id).join("state.json"),&state).unwrap();
    atomic_json(&root.join(&id).join("state.json.before-reconcile-fixture"),&state).unwrap();
    std::thread::sleep(Duration::from_secs(30));
}
#[test]
fn legacy_adjudication_preserves_unknown_outcome_and_requires_independent_native_evidence() {
    use ring::{rand::SystemRandom,signature::{Ed25519KeyPair,KeyPair}};
    let (m,root)=fixture();fs::create_dir_all(&root).unwrap();
    let evidence=root.with_extension("evidence");fs::create_dir_all(&evidence).unwrap();
    let mut child=std::process::Command::new(std::env::current_exe().unwrap()).args(["--ignored","--exact","tests::legacy_writer_helper","--nocapture"]).env("WA_LEGACY_TEST_ROOT",&root).stdout(std::process::Stdio::null()).spawn().unwrap();
    let pid=child.id();let id=format!("op-fixture-{pid}-0");
    let deadline=Instant::now()+Duration::from_secs(5);
    while !root.join(&id).join("state.json.before-reconcile-fixture").exists(){assert!(Instant::now()<deadline);std::thread::sleep(Duration::from_millis(10));}
    let stamp=legacy::creation(pid).unwrap().unwrap();
    let raw=fs::read(root.join(&id).join("state.json")).unwrap();let state:Value=serde_json::from_slice(&raw).unwrap();
    let state_hash=legacy::hash(&raw);
    let originals_hash=legacy::hash(json!([{"name":"state.json.before-reconcile-fixture","sha256":state_hash}]).to_string().as_bytes());
    let store=fs::canonicalize(&root).unwrap().to_string_lossy().replace('\\',"/");let store=store.strip_prefix("//?/").unwrap_or(&store);let store=if cfg!(windows){store.to_lowercase()}else{store.to_string()};
    fs::copy(std::env::current_exe().unwrap(),evidence.join("writer-binary")).unwrap();
    m.import_index("private writer fixture inventoried; no foreign legacy writer").unwrap();
    let observer=Ed25519KeyPair::from_pkcs8(Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap().as_ref()).unwrap();
    let reviewer=Ed25519KeyPair::from_pkcs8(Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap().as_ref()).unwrap();
    let hex=|bytes:&[u8]|bytes.iter().map(|b|format!("{b:02x}")).collect::<String>();
    atomic_json(&root.join("legacy-authority.json"),&json!({"schema":1,"keys":{"observer":{"public_key":hex(observer.public_key().as_ref()),"roles":["identity","drain","effects"]},"reviewer":{"public_key":hex(reviewer.public_key().as_ref()),"roles":["review"]}}})).unwrap();
    let capture=|name:&str,value:Value,key:&Ed25519KeyPair,signer:&str|{let path=evidence.join(name);let bytes=value.to_string().into_bytes();fs::write(&path,&bytes).unwrap();json!({"path":path,"sha256":legacy::hash(&bytes),"signature":hex(key.sign(&bytes).as_ref()),"signer":signer})};
    let identity=capture("identity.json",json!({"kind":"os-process-and-containment-identity","operation_id":id,"originals_sha256":originals_hash,"store_identity":store,"state_sha256":state_hash,"process_id":pid,"creation_stamp":stamp,"containment_identity":format!("owned Child handle {pid}:{stamp}"),"binary_artifact":evidence.join("writer-binary"),"binary_sha256":legacy::hash(&fs::read(evidence.join("writer-binary")).unwrap())}),&observer,"observer");
    let drain=capture("drain.json",json!({"kind":"os-process-exit-and-containment-drain","operation_id":id,"originals_sha256":originals_hash,"store_identity":store,"state_sha256":state_hash,"process_id":pid,"creation_stamp":stamp,"containment_identity":format!("owned Child handle {pid}:{stamp}"),"wait_result":"signalled","contained_members_exited":true,"handles_bound_to_creation_identity":true}),&observer,"observer");
    fs::write(evidence.join("original-preserved.json"),&raw).unwrap();
    let effects=capture("effects.json",json!({"kind":"scoped-effect-preservation","operation_id":id,"originals_sha256":originals_hash,"store_identity":store,"state_sha256":state_hash,"original_execution_outcome":"unknown","never_replay":true,"quarantine_preserved":true,"scopes":[{"kind":"filesystem","settled":true,"artifact":evidence.join("original-preserved.json"),"sha256":state_hash}]}),&observer,"observer");
    let review=capture("review.json",json!({"kind":"legacy-allocation-safety-review","operation_id":id,"originals_sha256":originals_hash,"store_identity":store,"state_sha256":state_hash,"identity_sha256":identity["sha256"],"drain_sha256":drain["sha256"],"effects_sha256":effects["sha256"],"verdict":"allocation_safe_original_unknown","never_replay":true}),&reviewer,"reviewer");
    let args=json!({"id":id,"expected_state":state,"state_sha256":state_hash,"originals":[{"name":"state.json.before-reconcile-fixture","sha256":state_hash}],"identity":identity,"drain":drain,"effects":effects,"review":review});
    assert!(m.adjudicate_legacy(&args).unwrap_err().to_string().contains("owner_still_live"));
    child.kill().unwrap();child.wait().unwrap(); // Actual owned handle and positive exit, not PID absence.
    let receipt=m.adjudicate_legacy(&args).unwrap();
    assert_eq!(m.adjudicate_legacy(&args).unwrap(),receipt);
    // Independent review means a distinct KEY, not a distinct label. Signing the review
    // with the observer's own key under another authorized alias must be refused.
    let original_authority=fs::read(root.join("legacy-authority.json")).unwrap();
    atomic_json(&root.join("legacy-authority.json"),&json!({"schema":1,"keys":{"observer":{"public_key":hex(observer.public_key().as_ref()),"roles":["identity","drain","effects"]},"reviewerAlias":{"public_key":hex(observer.public_key().as_ref()),"roles":["review"]}}})).unwrap();
    let alias_review=capture("review-alias.json",json!({"kind":"legacy-allocation-safety-review","operation_id":id,"originals_sha256":originals_hash,"store_identity":store,"state_sha256":state_hash,"identity_sha256":identity["sha256"],"drain_sha256":drain["sha256"],"effects_sha256":effects["sha256"],"verdict":"allocation_safe_original_unknown","never_replay":true}),&observer,"reviewerAlias");
    let mut alias_args=args.clone();alias_args["review"]=alias_review;
    assert!(m.adjudicate_legacy(&alias_args).unwrap_err().to_string().contains("legacy_reviewer_key_not_distinct"));
    fs::write(root.join("legacy-authority.json"),&original_authority).unwrap();
    let mut replaced=args.clone();replaced["replacement_note"]=json!("different durable bundle");
    assert!(m.adjudicate_legacy(&replaced).unwrap_err().to_string().contains("bundle_moved"));
    assert_eq!(receipt["original_execution_outcome"],"unknown");assert_eq!(receipt["never_replay"],true);
    assert_eq!(fs::read(root.join(&id).join("state.json")).unwrap(),raw);
    assert!(m.relevant("*","",1).unwrap()["operations"].as_array().unwrap().is_empty());
    let mut bad=args.clone();bad["review"]["signature"]=json!("00");assert!(m.adjudicate_legacy(&bad).is_err());
    bad=args.clone();bad["originals"]=json!([]);assert!(m.adjudicate_legacy(&bad).is_err());
    fs::write(evidence.join("original-preserved.json"),"changed effect evidence").unwrap();
    assert!(m.allocation_safety(&args).is_err());
    assert_eq!(m.relevant("*","",1).unwrap()["operations"][0]["operation_id"],id);
    drop(m);remove_fixture(root);remove_fixture(evidence);
}
#[test]
fn effective_cwd_prevents_self_blocking_unrelated_workspace() {
    let (m, root) = fixture();
    let id = m.start(shell("sleep 30")).unwrap();
    let state = m.snapshot(&id).unwrap();
    assert_eq!(state["cwd_requested"], "");
    // The primary `cwd` contract stays empty for an inherited call; the real directory is
    // effective_cwd, which is what the workspace-release index must key on.
    assert_eq!(state["cwd"], "");
    assert!(!state["effective_cwd"].as_str().unwrap().is_empty());
    assert!(state["owner_process_id"].is_number());
    assert!(state["owner_boot"].as_str().unwrap().starts_with("boot-"));
    let unrelated = root.join("unrelated");
    assert!(m.relevant(&unrelated.to_string_lossy(), "", 1).unwrap()["operations"].as_array().unwrap().is_empty());
    assert_eq!(m.relevant(state["effective_cwd"].as_str().unwrap(), "", 1).unwrap()["operations"][0]["operation_id"], id);
    m.cancel(&id).unwrap(); settled(&m, &id);
    drop(m); remove_fixture(root);
}
#[test]
fn migration_preserves_uncertain_originals_and_is_bounded_after_import() {
    let (m, root) = fixture();
    fs::create_dir_all(root.join("op-legacy")).unwrap();
    let original = json!({"cwd":"","settled":false,"cleanup":"unknown"});
    atomic_json(&root.join("op-legacy/state.json.before-reconcile-1"), &original).unwrap();
    atomic_json(&root.join("op-legacy/state.json"), &json!({"settled":true,"cleanup":"never_spawned"})).unwrap();
    for i in 0..1000 {
        fs::create_dir_all(root.join(format!("op-history-{i}"))).unwrap();
        atomic_json(&root.join(format!("op-history-{i}/state.json")), &json!({"settled":true,"cleanup":"terminated","cwd":"elsewhere"})).unwrap();
    }
    assert!(m.relevant("target", "", 1).unwrap_err().to_string().contains("import_required"));
    assert!(m.import_index("").is_err());
    assert_eq!(m.import_index("Fixture legacy writers stopped; inspected original states").unwrap()["imported"], 1001);
    let result = m.relevant("target", "", 1).unwrap();
    assert_eq!(result["operations"].as_array().unwrap().len(), 1);
    assert_eq!(result["operations"][0]["operation_id"], "op-legacy");
    assert_eq!(result["operations"][0]["originals"][0]["state"], original);
    let legacy: Value=serde_json::from_slice(&fs::read(root.join("op-legacy/state.json")).unwrap()).unwrap();
    let decision=json!({"id":"op-legacy","expected_state":legacy,"owner_boot":"boot-fiction","evidence":"zero output","drain_evidence":"mtime","effect_evidence":"age"});
    assert!(m.reconcile(&decision).unwrap_err().to_string().contains("legacy_operation_owner_identity_unknown"));
    // Query does not open settled files again. Missing historical evidence cannot
    // become an apparent empty operation directory or trigger a full release scan.
    fs::remove_file(root.join("op-history-0/state.json")).unwrap();
    assert_eq!(m.relevant("target", "", 1).unwrap()["operations"][0]["operation_id"], "op-legacy");
    drop(m); remove_fixture(root);
}
#[test]
fn reconciliation_requires_dead_owner_exact_state_and_effect_evidence() {
    let (m, root) = fixture();
    let id = m.start(Spec::command("no-such-executable-reconcile", vec![])).unwrap();
    settled(&m, &id);
    let state: Value = serde_json::from_slice(&fs::read(root.join(&id).join("state.json")).unwrap()).unwrap();
    let other = Manager::new(&root);
    let mut args = json!({"id":id,"owner_boot":state["owner_boot"],"expected_state":state,"evidence":"fixture inspection","drain_evidence":"spawn failed before child existed","effect_evidence":"no effect: nonexistent program"});
    assert!(other.reconcile(&args).unwrap_err().to_string().contains("owner_live"));
    args["effect_evidence"] = json!("");
    assert!(other.reconcile(&args).unwrap_err().to_string().contains("effect_evidence_required"));
    args["effect_evidence"] = json!("no effect: nonexistent program");
    let before = fs::read(root.join(&id).join("state.json")).unwrap();
    drop(m);
    args["expected_state"]["owner"] = json!("wrong-owner");
    assert!(other.reconcile(&args).unwrap_err().to_string().contains("state_moved"));
    args["expected_state"] = serde_json::from_slice(&before).unwrap();
    assert_eq!(other.reconcile(&args).unwrap()["reconciled"], true);
    assert_eq!(fs::read(root.join(&id).join("state.json")).unwrap(), before);
    assert!(other.relevant(args["expected_state"]["effective_cwd"].as_str().unwrap(), "", 1).unwrap()["operations"].as_array().unwrap().is_empty());
    drop(other); remove_fixture(root);
}
fn fixture() -> (Manager, PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "wa-operation-test-{}-{}",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    (Manager::new(&root), root)
}
fn shell(command: &str) -> Spec {
    Spec::command(
        if cfg!(windows) {
            "C:/Program Files/Git/bin/bash.exe"
        } else {
            "/bin/sh"
        },
        vec!["-c".into(), command.into()],
    )
}
fn settled(m: &Manager, id: &str) -> Value {
    let value = m.wait(id, Duration::from_secs(5)).unwrap();
    assert_eq!(value["settled"], true, "{value}");
    value
}
fn remove_fixture(root: PathBuf) {
    // Windows may retain an image mapping briefly after the process is signalled.
    // Retry only the fixture deletion, never the operation or its assertions.
    let deadline=Instant::now()+Duration::from_secs(2);
    loop {
        match fs::remove_dir_all(&root) {
            Ok(())=>return,
            Err(error) if (error.kind()==std::io::ErrorKind::PermissionDenied || error.raw_os_error()==Some(32)) && Instant::now()<deadline=>{
                std::thread::sleep(Duration::from_millis(20));
            }
            Err(error)=>panic!("fixture cleanup {}: {error}",root.display()),
        }
    }
}
#[test]
fn settlement_wakes_all_observers_without_relaunch_or_lost_notification() {
    let (m,root)=fixture();
    let id=m.start(shell("sleep 30 & wait")).unwrap();
    let barrier=Arc::new(std::sync::Barrier::new(3));
    let threads: Vec<_>=(0..2).map(|_| {
        let manager=m.clone();let id=id.clone();let barrier=barrier.clone();
        std::thread::spawn(move || {barrier.wait();manager.wait(&id,Duration::from_secs(5)).unwrap()})
    }).collect();
    barrier.wait();
    std::thread::sleep(Duration::from_millis(30));
    m.cancel(&id).unwrap();
    for thread in threads {assert_eq!(thread.join().unwrap()["state"],"cancelled");}
    let before=Instant::now();
    assert_eq!(m.wait(&id,Duration::from_secs(5)).unwrap()["settled"],true);
    assert!(before.elapsed()<Duration::from_secs(1),"settled state must not wait for another event");
    assert_eq!(m.list().as_array().unwrap().len(),1);
    drop(m);
    remove_fixture(root);
}
#[test]
fn output_and_exit_are_distinct() {
    let (m, root) = fixture();
    let id = m
        .start(shell("printf hello; printf warning >&2; exit 3"))
        .unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["process_exit_code"], 3);
    assert_eq!(s["ok"], false);
    assert_eq!(s["output_complete"], true);
    assert_eq!(s["stdout"], "hello");
    assert_eq!(s["stderr"], "warning");
    drop(m);
    remove_fixture(root);
}
#[test]
fn normal_command_succeeds_and_closes_stdin() {
    let (m, root) = fixture();
    let id = m.start(shell("read input; printf done")).unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["ok"], true, "{s}");
    assert_eq!(s["stdout"], "done");
    let timing=&s["timing"];
    assert_eq!(timing["schema_version"],1,"{s}");
    assert_eq!(timing["clock"],"monotonic","{s}");
    assert_eq!(timing["complete"],true,"{s}");
    assert_eq!(timing["final_state_record_excluded"],true,"{s}");
    let measured=["setup_ms","accepted_record_ms","spawn_ms","execution_ms","drain_cleanup_ms","output_sync_ms"]
        .iter().map(|name|timing[*name].as_u64().unwrap()).sum::<u64>();
    assert_eq!(timing["measured_ms"],measured,"{s}");
    assert_eq!(timing["total_ms"].as_u64().unwrap(),measured+timing["unattributed_ms"].as_u64().unwrap(),"{s}");
    assert_eq!(s["elapsed_ms"],timing["total_ms"],"{s}");
    drop(m);
    remove_fixture(root);
}
#[test]
fn exited_shell_cannot_leave_descendant_or_lose_output() {
    let (m, root) = fixture();
    let mut spec = shell("sleep 30 & printf visible; printf diagnostic >&2");
    // This checks descendant containment after shell exit, not shell startup speed.
    // Cold Windows Git Bash startup can exceed 300 ms before executing the first printf.
    // The separate deadline test retains its 150 ms absolute-deadline assertion.
    spec.timeout = Duration::from_secs(3);
    let start = Instant::now();
    let id = m.start(spec).unwrap();
    let s = settled(&m, &id);
    assert!(start.elapsed() < Duration::from_secs(5), "{s}");
    assert_eq!(s["ok"], false, "{s}");
    assert_eq!(s["process_exit_code"], 0);
    assert_eq!(s["stdout"], "visible");
    assert_eq!(s["stderr"], "diagnostic");
    assert_eq!(s["output_complete"], true);
    assert!(s["error"]
        .as_str()
        .unwrap()
        .contains("background_descendants"));
    drop(m);
    remove_fixture(root);
}
#[test]
fn deadline_covers_both_streams_without_serial_graces() {
    let (m, root) = fixture();
    let mut spec = shell("printf before; sleep 30 & wait");
    spec.timeout = Duration::from_millis(150);
    let start = Instant::now();
    let id = m.start(spec).unwrap();
    let s = settled(&m, &id);
    assert!(start.elapsed() < Duration::from_millis(1400), "{s}");
    assert_eq!(s["error"], "deadline_exceeded");
    // The deadline begins at admission, before the supervisor creates its
    // record and starts the shell. On a loaded host it can expire before the
    // shell prints; both empty output and the complete prefix are valid.
    assert!(s["stdout"] == "" || s["stdout"] == "before", "{s}");
    assert_eq!(s["output_complete"], true);
    drop(m);
    remove_fixture(root);
}
#[test]
fn cancel_is_independent_of_waiter_and_preserves_prefix() {
    let (m, root) = fixture();
    let id = m.start(shell("printf ready; sleep 30 & wait")).unwrap();
    for _ in 0..200 {
        if m.snapshot(&id).unwrap()["output_bytes"]
            .as_u64()
            .unwrap_or(0)
            > 0
        {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(m.read(&id, "stdout", 0, 50).unwrap()["content"], "ready");
    m.cancel(&id).unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["state"], "cancelled");
    assert_eq!(s["stdout"], "ready");
    assert_eq!(s["cleanup"], "terminated");
    drop(m);
    remove_fixture(root);
}
#[test]
fn flood_is_bounded_and_cannot_starve_control() {
    let (m, root) = fixture();
    let mut spec=shell("while :; do printf abcdefghijklmnopqrstuvwxyz; printf ABCDEFGHIJKLMNOPQRSTUVWXYZ >&2; done");
    spec.output_limit = 12000;
    let id = m.start(spec).unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["error"], "output_limit_exceeded");
    assert_eq!(s["output_bytes"], 12000);
    assert_eq!(s["output_complete"], false);
    drop(m);
    remove_fixture(root);
}
#[test]
fn quiet_operation_is_not_misdiagnosed() {
    let (m, root) = fixture();
    let id = m.start(shell("sleep 0.2; printf done")).unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["ok"], true, "{s}");
    drop(m);
    remove_fixture(root);
}
#[test]
fn cursor_read_and_restart_do_not_reexecute() {
    let (m, root) = fixture();
    let id = m.start(shell("printf abcdef")).unwrap();
    settled(&m, &id);
    assert_eq!(m.read(&id, "stdout", 2, 2).unwrap()["content"], "cd");
    assert!(m.read("../secret", "stdout", 0, 50).is_err());
    let reopened = Manager::new(&root);
    assert_eq!(reopened.snapshot(&id).unwrap()["ok"], true);
    let fake = root.join("op-interrupted");
    fs::create_dir(&fake).unwrap();
    atomic_json(
        &fake.join("state.json"),
        &json!({"state":"running","settled":false}),
    )
    .unwrap();
    assert_eq!(
        reopened.snapshot("op-interrupted").unwrap()["state"],
        "outcome_unknown"
    );
    drop(m);
    remove_fixture(root);
}
#[test]
fn split_utf8_and_binary_pages_retain_exact_bytes() {
    let (m, root) = fixture();
    let id = m.start(shell("printf '\\303\\251\\377'")).unwrap();
    settled(&m, &id);
    for (offset, encoded) in ["ww==", "qQ==", "/w=="].iter().enumerate() {
        let page = m.read(&id, "stdout", offset as u64, 1).unwrap();
        assert_eq!(page["text_lossy"], true, "{page}");
        assert_eq!(page["content_base64"], *encoded);
        assert_eq!(page["next_offset"], offset + 1);
    }
    let text = m.read(&id, "stdout", 0, 2).unwrap();
    assert_eq!(text["content"], "é");
    assert_eq!(text["text_lossy"], false);
    assert!(text.get("content_base64").is_none());
    let eof = m.read(&id, "stdout", 3, 1).unwrap();
    assert_eq!(eof["content"], "");
    assert_eq!(eof["text_lossy"], false);
    assert_eq!(eof["next_offset"], 3);
    // Exercise every byte, including NUL and genuinely valid replacement-character text.
    use base64::Engine;
    let bytes: Vec<u8> = (0..=255).collect();
    fs::write(root.join(&id).join("stdout"), &bytes).unwrap();
    let mut recovered = vec![];
    let mut offset = 0;
    while offset < bytes.len() as u64 {
        let page = m.read(&id, "stdout", offset, 7).unwrap();
        if page["text_lossy"] == true {
            recovered.extend(base64::engine::general_purpose::STANDARD.decode(page["content_base64"].as_str().unwrap()).unwrap());
        } else {
            recovered.extend_from_slice(page["content"].as_str().unwrap().as_bytes());
        }
        offset = page["next_offset"].as_u64().unwrap();
    }
    assert_eq!(recovered, bytes);
    fs::write(root.join(&id).join("stdout"), "�").unwrap();
    assert_eq!(m.read(&id, "stdout", 0, 3).unwrap()["text_lossy"], false);
    drop(m);
    remove_fixture(root);
}
#[test]
fn parallel_launches_do_not_inherit_each_others_pipes() {
    let (m, root) = fixture();
    let long = m.start(shell("sleep 30")).unwrap();
    for _ in 0..10 {
        let id = m.start(shell("printf short")).unwrap();
        let s = settled(&m, &id);
        assert_eq!(s["ok"], true, "{s}");
        assert!(s["elapsed_ms"].as_u64().unwrap() < 1000, "{s}");
    }
    m.cancel(&long).unwrap();
    settled(&m, &long);
    drop(m);
    remove_fixture(root);
}
#[cfg(windows)]
#[test]
fn native_shells_preserve_quoted_arguments() {
    let (m, root) = fixture();
    let system = std::env::var("SystemRoot").unwrap();
    let cmd = m
        .start(Spec::command(
            format!("{system}/System32/cmd.exe"),
            vec!["/C".into(), "echo \"hello world\"".into()],
        ))
        .unwrap();
    let s = settled(&m, &cmd);
    assert_eq!(s["ok"], true, "{s}");
    assert!(s["stdout"].as_str().unwrap().contains("hello world"), "{s}");
    let ps = m
        .start(Spec::command(
            format!("{system}/System32/WindowsPowerShell/v1.0/powershell.exe"),
            vec![
                "-NoProfile".into(),
                "-NonInteractive".into(),
                "-Command".into(),
                "Write-Output 'hello world'".into(),
            ],
        ))
        .unwrap();
    let s = settled(&m, &ps);
    assert_eq!(s["ok"], true, "{s}");
    assert!(s["stdout"].as_str().unwrap().contains("hello world"), "{s}");
    drop(m);
    remove_fixture(root);
}
#[test]
fn descendant_cannot_write_after_foreground_completion() {
    let (m, root) = fixture();
    std::fs::create_dir_all(&root).unwrap();
    let mut spec = shell("(sleep 0.4; printf leaked > orphan-proof) & printf visible");
    spec.cwd = root.to_string_lossy().to_string();
    let id = m.start(spec).unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["ok"], false, "{s}");
    std::thread::sleep(Duration::from_millis(600));
    assert!(
        !root.join("orphan-proof").exists(),
        "owned descendant survived settlement"
    );
    drop(m);
    remove_fixture(root);
}

#[test]
fn redirected_background_descendant_is_not_silent_success() {
    let (m, root) = fixture();
    let id = m
        .start(shell("sleep 30 >/dev/null 2>&1 & printf visible"))
        .unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["ok"], false, "{s}");
    assert_eq!(s["stdout"], "visible", "{s}");
    assert!(
        s["error"]
            .as_str()
            .unwrap()
            .contains("background_descendants"),
        "{s}"
    );
    drop(m);
    remove_fixture(root);
}

#[test]
fn promoted_descendants_are_adopted_not_failed() {
    let (m, root) = fixture();
    std::fs::create_dir_all(&root).unwrap();
    let mut spec = shell("(sleep 30; printf leaked > orphan-proof) & printf visible");
    spec.cwd = root.to_string_lossy().to_string();
    spec.promote_descendants = true;
    let id = m.start(spec).unwrap();
    // The shell exits at once. Without promotion this is `background_descendants`; with
    // it the operation is still running and says so, instead of reporting a failure.
    let observed = Instant::now();
    let live = loop {
        let state = m.snapshot(&id).unwrap();
        if state["promoted"] == true || state["settled"] == true || observed.elapsed() >= Duration::from_secs(3) {
            break state;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(live["promoted"], true, "{live}");
    assert_eq!(live["state"], "running", "{live}");
    assert_eq!(live["settled"], false, "{live}");
    assert_eq!(live["shell_exited"], true, "{live}");
    assert_eq!(live["process_exit_code"], 0, "{live}");
    assert_eq!(live["waiting_for"], "descendants", "{live}");
    assert!(live["remaining_ms"].as_u64().unwrap() <= 300000, "{live}");
    assert_eq!(live["timeout_ms"], 300000, "adoption must keep the original command budget: {live}");
    assert_eq!(live["command_completed"], true, "{live}");
    assert!(live["process_exit_elapsed_ms"].is_number(), "{live}");
    assert!(live["output_idle_ms"].as_u64().unwrap() > 0, "{live}");
    // Adoption is not abandonment: the same job object still owns the tree, so cancel
    // reaches the descendant and it never gets to write.
    m.cancel(&id).unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["promoted"], true, "{s}");
    std::thread::sleep(Duration::from_millis(600));
    assert!(
        !root.join("orphan-proof").exists(),
        "a cancelled adopted descendant survived"
    );
    drop(m);
    remove_fixture(root);
}

#[test]
fn adopted_tree_settles_when_it_exits_and_keeps_its_output() {
    let (m, root) = fixture();
    let mut spec = shell("(sleep 0.3; printf done) & printf visible");
    spec.promote_descendants = true;
    let id = m.start(spec).unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["promoted"], true, "{s}");
    assert_eq!(s["state"], "completed", "{s}");
    assert_eq!(s["ok"], true, "{s}");
    // Nothing was terminated; the adopted tree ended on its own.
    assert_eq!(s["cleanup"], "self_exited", "{s}");
    let out = s["stdout"].as_str().unwrap();
    assert!(out.contains("visible"), "{s}");
    assert!(
        out.contains("done"),
        "the adopted descendant's output must not be lost: {s}"
    );
    drop(m);
    remove_fixture(root);
}

#[test]
fn output_after_shell_exit_restarts_the_command_idle_window() {
    let (m, root) = fixture();
    let mut spec = shell("(sleep 0.2; printf later; sleep 30) & printf first");
    spec.promote_descendants = true;
    let id = m.start(spec).unwrap();
    let deadline = Instant::now() + Duration::from_secs(4);
    let mut observed_later = false;
    while Instant::now() < deadline {
        let state = m.snapshot(&id).unwrap();
        if state["post_exit_last_output_elapsed_ms"].as_u64().is_some() {
            let output = m.read(&id, "stdout", 0, 128).unwrap();
            assert!(output["content"].as_str().unwrap().contains("later"), "{output}");
            assert!(state["output_idle_ms"].as_u64().unwrap() < 100, "{state}");
            observed_later = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(observed_later, "late descendant output was not observed");
    m.cancel(&id).unwrap();
    let result = settled(&m, &id);
    assert_eq!(result["state"], "cancelled", "{result}");
    drop(m);
    remove_fixture(root);
}

#[cfg(windows)]
fn compiler_helper_command(root: &Path, regular_work: bool, helper_path: &str) -> Spec {
    let helper = root.join(helper_path);
    fs::create_dir_all(helper.parent().unwrap()).unwrap();
    fs::copy(std::env::current_exe().unwrap(), &helper).unwrap();
    let helper = helper.to_string_lossy().replace('\\', "/");
    let system = std::env::var("SystemRoot").unwrap();
    let mut spec = Spec::command(
        format!("{system}/System32/WindowsPowerShell/v1.0/powershell.exe"),
        vec!["-NoProfile".into(), "-NonInteractive".into(), "-Command".into(), format!(
            "Start-Process -WindowStyle Hidden -FilePath '{}' -ArgumentList '--exact tests::compiler_helper_fixture --nocapture'; Start-Sleep -Milliseconds 200; Write-Output build_done{}",
            helper.replace('\'', "''"),
            if regular_work { "; Start-Sleep -Seconds 1; Write-Output actual_work_done" } else { "" }
        )],
    );
    spec.env.push(("WA_OPERATION_COMPILER_HELPER_FIXTURE".into(), "1".into()));
    spec.promote_descendants = true;
    spec
}

#[cfg(windows)]
#[test]
fn compiler_helper_fixture() {
    if std::env::var("WA_OPERATION_COMPILER_HELPER_FIXTURE").as_deref() == Ok("1") {
        println!("compiler_helper_ready");
        std::thread::sleep(Duration::from_secs(30));
    }
}

#[cfg(windows)]
#[test]
fn compiler_telemetry_cannot_keep_a_completed_build_running() {
    let (m, root) = fixture();
    let id = m.start(compiler_helper_command(&root, false,
        "Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44/bin/Hostx64/x64/VCTIP.EXE")).unwrap();
    let result = settled(&m, &id);
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(result["process_exit_code"], 0, "{result}");
    assert_eq!(result["cleanup"], "compiler_helpers_terminated", "{result}");
    assert!(result["auxiliary_cleanup"].as_array().unwrap().iter()
        .any(|image| image.as_str().unwrap().to_ascii_lowercase().ends_with("vctip.exe")));
    assert!(result["stdout"].as_str().unwrap().contains("build_done"), "{result}");
    drop(m);
    remove_fixture(root);
}

#[cfg(windows)]
#[test]
fn compiler_helper_cleanup_waits_for_real_work() {
    let (m, root) = fixture();
    let id = m.start(compiler_helper_command(&root, true,
        "Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44/bin/Hostx64/x64/vctip.exe")).unwrap();
    std::thread::sleep(Duration::from_millis(400));
    assert_eq!(m.snapshot(&id).unwrap()["settled"], false);
    let result = settled(&m, &id);
    assert_eq!(result["ok"], true, "{result}");
    assert!(result["stdout"].as_str().unwrap().contains("actual_work_done"), "{result}");
    drop(m);
    remove_fixture(root);
}

#[cfg(windows)]
#[test]
fn a_process_named_vctip_outside_msvc_stays_adopted() {
    let (m, root) = fixture();
    let id = m.start(compiler_helper_command(&root, false, "user-work/vctip.exe")).unwrap();
    std::thread::sleep(Duration::from_millis(400));
    assert_eq!(m.snapshot(&id).unwrap()["settled"], false);
    m.cancel(&id).unwrap();
    let result = settled(&m, &id);
    assert_eq!(result["state"], "cancelled", "{result}");
    assert!(result.get("auxiliary_cleanup").is_none());
    drop(m);
    remove_fixture(root);
}

#[test]
fn launch_failure_is_visible() {
    let (m, root) = fixture();
    let id = m
        .start(Spec::command(
            "this-program-does-not-exist-wa-operation",
            vec![],
        ))
        .unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["ok"], false);
    assert!(s["error"].is_string());
    assert_eq!(s["timing"]["schema_version"],1,"{s}");
    assert_eq!(s["timing"]["complete"],false,"{s}");
    assert!(s["timing"]["setup_ms"].is_number(),"{s}");
    assert!(s["timing"]["spawn_ms"].is_number(),"{s}");
    // A notification is not permission to outrun the durable failure record.
    let restored=Manager::new(&root).snapshot(&id).unwrap();
    assert_eq!(restored["state"],"failed");
    assert_eq!(restored["error"],s["error"]);
    drop(m);
    remove_fixture(root);
}

/// A command can print the node's own key. The transcript has its own redactor; this proves
/// the *operation's* output - the file on disk and the in-memory view - is redacted too,
/// because a promoted process outlives the turn that started it.
#[test]
fn a_secret_in_operation_output_is_redacted_on_disk_and_in_the_view() {
    let root = std::env::temp_dir().join(format!(
        "wa-operation-redact-{}-{}",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let secret = "sk-live-SECRETVALUE-0123456789abcdef";
    let m = Manager::new(&root).with_secrets(vec![secret.into()]);
    let id = m.start(shell("printf 'key=sk-live-SECRETVALUE-0123456789abcdef'")).unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["stdout"], "key=<redacted>", "{s}");
    let on_disk = fs::read_to_string(root.join(&id).join("stdout")).unwrap();
    assert!(!on_disk.contains("SECRETVALUE"), "the file holds the secret: {on_disk}");
    assert!(on_disk.contains("<redacted>"), "{on_disk}");
    drop(m);
    remove_fixture(root);
}

/// The 8 KiB read boundary can fall inside the key. Filler before it forces that split, and
/// neither the file nor the view may hold the value.
#[test]
fn a_secret_split_across_the_read_buffer_is_redacted() {
    let root = std::env::temp_dir().join(format!(
        "wa-operation-redact-split-{}-{}",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let secret = "sk-live-SECRETVALUE-0123456789abcdef";
    let m = Manager::new(&root).with_secrets(vec![secret.into()]);
    // 8186 filler bytes put "key=<secret>" across the 8192 read boundary.
    let command = format!("printf '%*s' 8186 '' | tr ' ' x; printf 'key={secret}'");
    let id = m.start(shell(&command)).unwrap();
    let s = settled(&m, &id);
    let stdout = s["stdout"].as_str().unwrap_or("");
    assert!(!stdout.contains("SECRETVALUE"), "the split secret leaked into the view");
    assert!(stdout.contains("<redacted>"), "{stdout}");
    let on_disk = fs::read_to_string(root.join(&id).join("stdout")).unwrap();
    assert!(!on_disk.contains("SECRETVALUE"), "the split secret is on disk");
    drop(m);
    remove_fixture(root);
}

// ---- the starting directory ---------------------------------------------------------------
//
// A shell that starts in a directory that no longer exists does not fail at its command, it
// fails before it: on unix it prints `shell-init: error retrieving current directory:
// getcwd: cannot access parent directories` and then treats every relative path as
// unresolvable. Two shapes reach that state, and both are exercised here: a recorded path that
// was deleted (a released session worktree is the ordinary case) and a node whose *own*
// directory was deleted while the process kept running.

/// (a) the command still runs, (b) the result states the substitution, and the recorded path is
/// never claimed as the directory that was used.
#[test]
fn a_deleted_starting_directory_is_substituted_and_stated_in_the_result() {
    let (m, root) = fixture();
    let fallback = root.join("fallback");
    let recorded = root.join("recorded-worktree");
    fs::create_dir_all(&fallback).unwrap();
    fs::create_dir_all(&recorded).unwrap();
    let m = m.with_fallback_cwd(&fallback);
    let mut spec = shell("printf started");
    spec.cwd = recorded.to_string_lossy().to_string();
    fs::remove_dir_all(&recorded).unwrap();
    let id = m.start(spec).unwrap();
    let s = settled(&m, &id);
    let recorded_text = recorded.to_string_lossy().to_string();
    let fallback_text = fallback.to_string_lossy().to_string();
    assert_eq!(s["ok"], true, "the shell did not run its command: {s}");
    assert_eq!(s["stdout"], "started", "{s}");
    assert_eq!(s["cwd_requested"], recorded_text.as_str(), "{s}");
    assert_eq!(s["cwd_substitution"]["requested"], recorded_text.as_str(), "{s}");
    assert_eq!(s["cwd_substitution"]["used"], fallback_text.as_str(), "{s}");
    assert_eq!(
        s["cwd_substitution"]["reason"],
        "recorded_starting_directory_missing",
        "{s}"
    );
    assert_eq!(
        s["cwd"], fallback_text.as_str(),
        "the recorded directory must not be reported as the one that was used: {s}"
    );
    let note = s["cwd_note"].as_str().unwrap_or("");
    assert!(note.contains(&recorded_text), "the note must name what was asked for: {note}");
    assert!(note.contains(&fallback_text), "the note must name where it ran: {note}");
    drop(m);
    remove_fixture(root);
}

/// (c) a directory that exists is unchanged: the shell starts in it, the recorded path is
/// reported as the one used, and nothing claims a substitution.
#[test]
fn a_usable_starting_directory_is_unchanged() {
    let (m, root) = fixture();
    let kept = root.join("kept");
    let fallback = root.join("fallback");
    fs::create_dir_all(&kept).unwrap();
    fs::create_dir_all(&fallback).unwrap();
    // The marker is only reachable from that directory, so reading it is evidence about where
    // the shell actually started - not only about what the record says.
    fs::write(kept.join("marker.txt"), "in the recorded directory").unwrap();
    let m = m.with_fallback_cwd(&fallback);
    let mut spec = shell("cat marker.txt");
    spec.cwd = kept.to_string_lossy().to_string();
    let id = m.start(spec).unwrap();
    let s = settled(&m, &id);
    let kept_text = kept.to_string_lossy().to_string();
    assert_eq!(s["ok"], true, "{s}");
    assert_eq!(s["stdout"], "in the recorded directory", "{s}");
    assert_eq!(s["cwd"], kept_text.as_str(), "{s}");
    assert_eq!(s["cwd_requested"], kept_text.as_str(), "{s}");
    assert!(s["cwd_substitution"].is_null(), "an unchanged call claimed a substitution: {s}");
    assert!(s["cwd_note"].is_null(), "{s}");
    drop(m);
    remove_fixture(root);
}

/// The peer shape from the field report: the call names no directory, so the shell inherits the
/// node's own - which is gone. `node_cwd` is a parameter rather than a read of this process, so
/// the case stays testable: a process's own directory is process-global, and this platform
/// refuses to remove a directory that is a process's working directory at all.
#[test]
fn an_unavailable_node_working_directory_is_substituted() {
    let root = std::env::temp_dir().join(format!(
        "wa-operation-startdir-{}-{}",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let fallback = root.join("fallback");
    let here = root.join("here");
    let gone = root.join("gone");
    fs::create_dir_all(&fallback).unwrap();
    fs::create_dir_all(&here).unwrap();
    let substituted = resolve_start_directory("", Some(&gone), Some(&fallback));
    let fallback_text = fallback.to_string_lossy().to_string();
    assert_eq!(substituted.used, fallback_text);
    let substitution = substituted.substitution.as_ref().unwrap();
    assert_eq!(substitution["reason"], "node_working_directory_unavailable");
    assert_eq!(substitution["used"], fallback_text.as_str());
    let note = substitution_note(substitution);
    assert!(note.contains(&fallback_text), "{note}");
    assert!(
        note.contains("the node's own working directory"),
        "a call that named nothing must say so rather than name a path it never had: {note}"
    );
    // An ordinary call, with a node directory that exists, keeps today's behaviour exactly.
    let unchanged = resolve_start_directory("", Some(&here), Some(&fallback));
    assert_eq!(unchanged.used, here.to_string_lossy());
    assert!(unchanged.substitution.is_none());
    fs::remove_dir_all(root).unwrap();
}

/// A recorded path that exists but is not a directory is a different failure from a deleted one,
/// and it must not be reported as "missing".
#[test]
fn a_recorded_starting_directory_that_is_a_file_says_so() {
    let root = std::env::temp_dir().join(format!(
        "wa-operation-startdir-file-{}-{}",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let fallback = root.join("fallback");
    fs::create_dir_all(&fallback).unwrap();
    let file = root.join("not-a-directory");
    fs::write(&file, "x").unwrap();
    let resolved = resolve_start_directory(
        &file.to_string_lossy(),
        Some(&fallback),
        Some(&fallback),
    );
    assert_eq!(resolved.used, fallback.to_string_lossy());
    assert_eq!(
        resolved.substitution.as_ref().unwrap()["reason"],
        "requested_starting_directory_is_not_a_directory"
    );
    fs::remove_dir_all(root).unwrap();
}

/// The two sentences an operator reads. Neither may leave out where the shell actually ran; the
/// second is only produced when even `/` is not a directory, which is why it is asserted here
/// directly instead of through a spawn.
#[test]
fn the_substitution_sentence_names_both_directories() {
    let with_fallback = json!({"requested":"/local/colmeio","used":"/home/victor",
        "reason":"recorded_starting_directory_missing",
        "detail":"the starting directory this call recorded no longer exists"});
    let note = substitution_note(&with_fallback);
    assert!(note.contains("/local/colmeio"), "{note}");
    assert!(note.contains("/home/victor"), "{note}");
    assert!(note.contains("resolved from /home/victor"), "{note}");
    let without_fallback = json!({"requested":"","used":Value::Null,
        "reason":"node_working_directory_unavailable",
        "detail":"this call named no directory and the node's own working directory is gone"});
    let note = substitution_note(&without_fallback);
    assert!(note.contains("no fallback directory exists"), "{note}");
    assert!(!note.contains("it started in"), "{note}");
}
