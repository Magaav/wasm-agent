use super::*;
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
#[test]
fn settlement_wakes_all_observers_without_relaunch_or_lost_notification() {
    let (m,root)=fixture();
    let id=m.start(shell("sleep 30 & wait")).unwrap();
    let barrier=Arc::new(std::sync::Barrier::new(3));
    let workers: Vec<_>=(0..2).map(|_| {
        let manager=m.clone();let id=id.clone();let barrier=barrier.clone();
        std::thread::spawn(move || {barrier.wait();manager.wait(&id,Duration::from_secs(5)).unwrap()})
    }).collect();
    barrier.wait();
    std::thread::sleep(Duration::from_millis(30));
    m.cancel(&id).unwrap();
    for worker in workers {assert_eq!(worker.join().unwrap()["state"],"cancelled");}
    let before=Instant::now();
    assert_eq!(m.wait(&id,Duration::from_secs(5)).unwrap()["settled"],true);
    assert!(before.elapsed()<Duration::from_secs(1),"settled state must not wait for another event");
    assert_eq!(m.list().as_array().unwrap().len(),1);
    fs::remove_dir_all(root).unwrap();
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
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn normal_command_succeeds_and_closes_stdin() {
    let (m, root) = fixture();
    let id = m.start(shell("read input; printf done")).unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["ok"], true, "{s}");
    assert_eq!(s["stdout"], "done");
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn exited_shell_cannot_leave_descendant_or_lose_output() {
    let (m, root) = fixture();
    let mut spec = shell("sleep 30 & printf visible; printf diagnostic >&2");
    spec.timeout = Duration::from_millis(300);
    let start = Instant::now();
    let id = m.start(spec).unwrap();
    let s = settled(&m, &id);
    assert!(start.elapsed() < Duration::from_millis(1500), "{s}");
    assert_eq!(s["ok"], false, "{s}");
    assert_eq!(s["process_exit_code"], 0);
    assert_eq!(s["stdout"], "visible");
    assert_eq!(s["stderr"], "diagnostic");
    assert_eq!(s["output_complete"], true);
    assert!(s["error"]
        .as_str()
        .unwrap()
        .contains("background_descendants"));
    fs::remove_dir_all(root).unwrap();
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
    assert_eq!(s["stdout"], "before");
    assert_eq!(s["output_complete"], true);
    fs::remove_dir_all(root).unwrap();
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
    fs::remove_dir_all(root).unwrap();
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
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn quiet_operation_is_not_misdiagnosed() {
    let (m, root) = fixture();
    let id = m.start(shell("sleep 0.2; printf done")).unwrap();
    let s = settled(&m, &id);
    assert_eq!(s["ok"], true, "{s}");
    fs::remove_dir_all(root).unwrap();
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
    fs::remove_dir_all(root).unwrap();
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
    fs::remove_dir_all(root).unwrap();
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
    fs::remove_dir_all(root).unwrap();
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
    fs::remove_dir_all(root).unwrap();
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
    fs::remove_dir_all(root).unwrap();
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
    fs::remove_dir_all(root).unwrap();
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
    // A notification is not permission to outrun the durable failure record.
    let restored=Manager::new(&root).snapshot(&id).unwrap();
    assert_eq!(restored["state"],"failed");
    assert_eq!(restored["error"],s["error"]);
    fs::remove_dir_all(root).unwrap();
}
