//! The runner's tests that need THIS process's real facts (`operations_seam::HostFacts`, installed below).
//!
//! They moved here with the runner (`ready-operations-slice-2.md`, stage A): the runner asks its embedding
//! process for the relay's cancel flag, the in-turn marker, a program on PATH and a file's digest, and a test
//! that answered those itself would be asserting against a stub. Nothing in these tests was loosened - every
//! assertion is the one the runner carried, and each test installs the host's own facts first.
#![cfg(test)]

use crate::operations as runner;

#[cfg(test)]
mod vault_approval_tests {
    use crate::operations::{approval_problem, approval_text, is_absolute_path, is_script_path, looks_like_path,
                platform_root, request_server_problem, seal_request, sha256_hex, APPROVAL_FORM};
    use serde_json::{json, Value};

    fn scratch(name: &str, body: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("wa-vault-approval-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let path = dir.join(name);
        std::fs::write(&path, body).expect("scratch script");
        path
    }

    /// A NATIVE binary copied under a chosen name, for fixtures that must pass the allow-list: a shell
    /// script is refused as a program now, so a fixture program has to be a real ELF/Mach-O/PE file.
    fn native_copy(name: &str) -> std::path::PathBuf {
        let source = ["/usr/bin/env", "/bin/env", "/usr/bin/true", "/bin/true"]
            .into_iter()
            .find(|candidate| {
                crate::operations::file_magic(candidate).as_deref() == Some("elf")
                    || crate::operations::file_magic(candidate).as_deref() == Some("macho")
            })
            .expect("a native binary to copy for the fixtures");
        let dir = std::env::temp_dir().join(format!("wa-vault-approval-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let path = dir.join(name);
        std::fs::copy(source, &path).expect("a native fixture");
        path
    }

    /// An approval that ALSO carries the operator's --native voucher for a program outside the two
    /// families: the one shape in which a native binary runs a vault connector (round 8).
    fn approval_native(program: &std::path::Path, files: &[&std::path::Path], vault: &[&str]) -> Value {
        let mut document = approval(&program.to_string_lossy(), "", &[], &[], files, vault);
        let real = crate::operations::real_path(&program.to_string_lossy());
        let sha = sha256_hex(&std::fs::read(program).expect("the vouched binary"));
        // The console SORTS the file list before hashing it (lua/core/mcp.lua, M.vault_manifest:
        // `table.sort(files, ...)`), and approval_problem sorts it too - so a helper that handed the list
        // in the order it was written built a digest the kernel would never reproduce. One file hid it.
        let mut listed: Vec<(String, String)> = files.iter().map(|path| (path.to_string_lossy().to_string(),
            sha256_hex(&std::fs::read(path).expect("a covered file")))).collect();
        listed.sort_by(|left, right| left.0.cmp(&right.0));
        document["files"] = json!(listed.iter().map(|(path, _)| path.clone()).collect::<Vec<_>>());
        let text = approval_text(&document["program"].as_str().unwrap_or_default().to_string(), "", &[],
            &[], &listed,
            &vault.iter().map(|entry| entry.to_string()).collect::<Vec<_>>(),
            Some((real.as_str(), sha.as_str())));
        document["sha256"] = json!(sha256_hex(text.as_bytes()));
        document["native"] = json!({"path": real, "sha256": sha});
        document
    }

    /// A NATIVE binary in this user's own directory, under a name the allow-list accepts (round 8: a
    /// program is judged by its REALPATH's basename and by its leading bytes, so a `#!/bin/sh` fixture
    /// called `node` is exactly what the allow-list refuses). Copied from the platform's own, and given a
    /// subdirectory so two tests running at once cannot collide on one file.
    fn scratch_native(name: &str) -> std::path::PathBuf {
        let source = ["/usr/bin/env", "/bin/env", "/usr/bin/true", "/bin/true"].iter()
            .find(|candidate| std::fs::metadata(candidate).is_ok())
            .copied().expect("a native binary on this host to copy");
        // One directory PER CALL: these tests run in parallel, and a copy removed by the test that
        // finished first was a copy the next one still needed (`program_not_native` on a real ELF).
        use std::sync::atomic::{AtomicU64, Ordering};
        static SERIAL: AtomicU64 = AtomicU64::new(0);
        let serial = SERIAL.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir()
            .join(format!("wa-vault-approval-{}/native-{serial}", std::process::id())).join(name);
        std::fs::create_dir_all(path.parent().expect("a parent")).expect("scratch dir");
        std::fs::copy(source, &path).expect("a native copy");
        path
    }

    fn spec(program: &str, args: &[String]) -> wa_operation::Spec {
        wa_operation::Spec::command(program.to_string(), args.to_vec())
    }

    /// An approval as the console records one (lua/core/mcp.lua, M.vault_manifest): the form, the digest
    /// over the bytes on disk, and the fields that digest covers.
    fn approval(program: &str, cwd: &str, env: &[(&str, &str)], args: &[String],
                files: &[&std::path::Path], vault: &[&str]) -> Value {
        let list: Vec<(String, String)> = files.iter().map(|path| {
            let body = std::fs::read(path).expect("a file the approval covers");
            (path.to_string_lossy().to_string(), sha256_hex(&body))
        }).collect();
        let env: Vec<(String, String)> = env.iter().map(|(name, reference)| (name.to_string(), reference.to_string())).collect();
        let vault: Vec<String> = vault.iter().map(|entry| entry.to_string()).collect();
        let digest = sha256_hex(approval_text(program, cwd, &env, args, &list, &vault, None).as_bytes());
        json!({"form": APPROVAL_FORM, "sha256": digest, "program": program, "cwd": cwd,
            "env": env.iter().map(|(name, reference)| json!({"name": name, "ref": reference})).collect::<Vec<_>>(),
            "args": args,
            "files": files.iter().map(|path| path.to_string_lossy().to_string()).collect::<Vec<_>>(),
            "vault": vault})
    }

    /// The request file a launch reads: the shape lua/core/mcp.lua writes and mcp-client.mjs spawns from.
    fn request(program: &str, args: &[&str], cwd: Option<&str>) -> Vec<u8> {
        let mut server = json!({"transport": "stdio", "program": program, "args": args,
            "env": {"TOKEN": "TOKEN"}});
        if let Some(cwd) = cwd { server["cwd"] = json!(cwd); }
        serde_json::to_vec(&json!({"action": "call", "server": server, "tool": "echo"}))
            .expect("a request file")
    }

    // The ONE canonical text: a newline, a space or a tab inside a field cannot forge a line, and the
    // same fixture hashes to the same digest on both sides (see the Lua pin in
    // scripts/test-mcp-vault-approval.lua).
    #[test]
    fn the_canonical_text_escapes_fields_and_matches_the_lua_side() {
        crate::test_facts::install();
        let env: Vec<(String, String)> = vec![("MAIL_USER".into(), "MAIL_USER".into()),
            ("LANG".into(), "LC_ALL".into())];
        let text = approval_text(
            "/usr/bin/node",
            "/home/agent/work tree",
            &env,
            &["/home/agent/scripts/fixture.mjs".into(), "--token".into(), "a b".into()],
            &[("/home/agent/scripts/fixture.mjs".into(), "aa".repeat(32)),
              ("/home/agent/scripts/lib/other.mjs".into(), "bb".repeat(32))],
            &["FIXTURE_TOKEN".into(), "SECOND_ONE".into()],
            None,
        );
        assert!(text.starts_with("mcp-vault-approval/v4\nprogram /usr/bin/node\ncwd /home/agent/work%20tree\n"), "{text}");
        assert!(text.contains("\nenv LANG=LC_ALL\nenv MAIL_USER=MAIL_USER\narg "), "the plain environment is sorted by name: {text}");
        assert!(text.contains("\narg a%20b\n"), "a space is escaped, not a separator: {text}");
        assert_eq!(sha256_hex(text.as_bytes()),
            "0d7f15fd975c32c4d5875437dfc193931fbc01972a83f55d1b01c736c6e8ee0b",
            "the digest the Lua side pins for the same fixture");
    }

    #[test]
    fn an_approved_launch_is_accepted_and_an_edited_script_is_not() {
        crate::test_facts::install();
        let script = scratch("plain.mjs", "export const ok = 1;\n");
        let client = scratch("client.mjs", "import './plain.mjs';\n");
        let args = vec![client.to_string_lossy().to_string(), "--request-file".into(), "/tmp/request.json".into()];
        let ok = approval("/usr/bin/node", "", &[], &args, &[&client, &script], &["TOKEN"]);
        assert!(approval_problem(&ok, &spec("/usr/bin/node", &args)).is_ok(),
            "what the operator approved launches: {:?}", approval_problem(&ok, &spec("/usr/bin/node", &args)));

        // The attack the review measured: the script of an approved connector is rewritten afterwards.
        std::fs::write(&script, "export const ok = 2; // replaced after the approval\n").expect("rewrite");
        let refused = approval_problem(&ok, &spec("/usr/bin/node", &args)).unwrap_err();
        assert!(refused.starts_with("vault_approval_mismatch:"), "{refused}");
        assert!(refused.contains("/mcp <id> probe"), "the refusal says how to approve it again: {refused}");

        // Approving the OLD bytes again still does not help now: the digest is over what is on disk.
        std::fs::write(&script, "export const ok = 1;\n").expect("restore");
        assert!(approval_problem(&ok, &spec("/usr/bin/node", &args)).is_ok(), "the approved bytes are back");
        // ARGUMENTS are in the digest too: an approval minted for one command line does not cover
        // another.
        let mut other = ok.clone();
        let mut moved: Vec<String> = args.clone();
        moved.push("--extra".into());
        other["args"] = json!(moved);
        let refused = approval_problem(&other, &spec("/usr/bin/node", &args)).unwrap_err();
        assert!(refused.starts_with("vault_approval_mismatch:"), "{refused}");
        // THE CWD and the PLAIN ENVIRONMENT are in it as well (this round): a connector moved to another
        // directory, or one that now asks for another variable, is not the launch that was approved.
        let mut moved_cwd = ok.clone();
        moved_cwd["cwd"] = json!("/tmp");
        assert!(approval_problem(&moved_cwd, &spec("/usr/bin/node", &args)).unwrap_err()
            .starts_with("vault_approval_mismatch:"));
        let mut moved_env = ok.clone();
        moved_env["env"] = json!([{"name": "PROXY", "ref": "PROXY"}]);
        assert!(approval_problem(&moved_env, &spec("/usr/bin/node", &args)).unwrap_err()
            .starts_with("vault_approval_mismatch:"));
        let _ = std::fs::remove_file(&script);
        let _ = std::fs::remove_file(&client);
    }

    #[test]
    fn a_launch_running_a_script_the_approval_does_not_name_is_refused() {
        crate::test_facts::install();
        let client = scratch("uncovered-client.mjs", "export const c = 1;\n");
        let smuggled = scratch("smuggled.sh", "echo value\n");
        let approved_args = vec![client.to_string_lossy().to_string()];
        let ok = approval("/usr/bin/node", "", &[], &approved_args, &[&client], &[]);
        let running = spec("/usr/bin/node",
            &[client.to_string_lossy().to_string(), smuggled.to_string_lossy().to_string()]);
        let refused = approval_problem(&ok, &running).unwrap_err();
        assert!(refused.starts_with("vault_approval_script_not_covered:"), "{refused}");
        assert!(refused.contains("smuggled.sh"), "{refused}");
        let _ = std::fs::remove_file(&client);
        let _ = std::fs::remove_file(&smuggled);
    }

    #[test]
    fn a_missing_approval_or_a_missing_script_reads_nothing() {
        crate::test_facts::install();
        let running = spec("/usr/bin/node", &["/tmp/client.mjs".to_string()]);
        for empty in [Value::Null, json!({}), json!({"sha256": "  "})] {
            let refused = approval_problem(&empty, &running).unwrap_err();
            assert!(refused.starts_with("vault_approval_required:"), "{refused}");
        }
        let vanished = json!({"form": APPROVAL_FORM, "sha256": "00".repeat(32), "program": "/usr/bin/node",
            "cwd": "", "env": [], "args": [], "files": ["/nonexistent/wasm-agent/connector.mjs"], "vault": []});
        let refused = approval_problem(&vanished, &spec("/usr/bin/node", &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_unreadable:/nonexistent/wasm-agent/connector.mjs"), "{refused}");
    }

    // A row approved before this round covers v1's fields only: it cannot be compared against v2's
    // digest, so it is refused by name and the operator approves again.
    #[test]
    fn an_approval_that_predates_the_form_is_refused() {
        crate::test_facts::install();
        let mut old = json!({"sha256": "ab".repeat(32), "program": "/usr/bin/node", "args": [],
            "files": [], "vault": []});
        let refused = approval_problem(&old, &spec("/usr/bin/node", &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_digest_form:"), "{refused}");
        assert!(refused.contains("/mcp <id> probe"), "{refused}");
        old["form"] = json!("mcp-vault-approval/v1");
        assert!(approval_problem(&old, &spec("/usr/bin/node", &[])).unwrap_err()
            .starts_with("vault_approval_digest_form:"));
    }

    // A program the platform does not own is the connector's own code (this round's second hole): it
    // must be a file the digest names, or the launch reads no value.
    #[test]
    fn a_program_the_platform_does_not_own_must_be_in_the_digest() {
        crate::test_facts::install();
        // Round 8 judges the program BEFORE its coverage: a file that is not node or a POSIX shell is
        // refused by the allow-list, whatever the digest says about it. A user-owned node is the shape
        // that reaches the coverage rule - allowed as a program, and still a file this launch runs.
        let binary = scratch_native("node");
        let program = binary.to_string_lossy().to_string();
        let unlisted = approval("/usr/bin/node", "", &[], &[], &[], &["TOKEN"]);
        let mut named = unlisted.clone();
        named["program"] = json!(program);
        let refused = approval_problem(&named, &spec(&program, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_covered:"), "{refused}");
        // Named by the digest, the same launch is accepted.
        let covered = approval(&program, "", &[], &[], &[&binary], &["TOKEN"]);
        assert!(approval_problem(&covered, &spec(&program, &[])).is_ok(),
            "{:?}", approval_problem(&covered, &spec(&program, &[])));
        // A shell script OUTSIDE both families is refused earlier, by the allow-list: it is the same
        // launch as a python or a copy of node under another name.
        let script = scratch("home-conn", "#!/bin/sh\necho value\n");
        let scripted = script.to_string_lossy().to_string();
        let mut smuggled = unlisted.clone();
        smuggled["program"] = json!(scripted);
        let refused = approval_problem(&smuggled, &spec(&scripted, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        let _ = std::fs::remove_file(&binary);
        let _ = std::fs::remove_file(&script);
    }

    #[test]
    fn a_relative_path_or_a_package_runner_cannot_be_approved() {
        crate::test_facts::install();
        let bare = approval("node", "", &[], &[], &[], &["TOKEN"]);
        assert!(approval_problem(&bare, &spec("/usr/bin/node", &[])).unwrap_err()
            .starts_with("vault_approval_program_not_absolute:node:"), "a name is resolved through PATH");
        let runner = approval("npx", "", &[], &[], &[], &["TOKEN"]);
        let refused = approval_problem(&runner, &spec("/usr/bin/node", &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_package_runner:npx:"), "{refused}");
        let relative = approval("/usr/bin/node", "", &[], &["conn.mjs".into()], &[], &["TOKEN"]);
        let refused = approval_problem(&relative, &spec("/usr/bin/node", &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_path_not_absolute:conn.mjs:"), "{refused}");
        // The shape helpers are the same rules the console applies (M.vault_manifest).
        assert!(!looks_like_path("--token") && !looks_like_path("https://example.com/mcp"));
        assert!(looks_like_path("conn.mjs") && looks_like_path("./lib/x.mjs") && looks_like_path("/a/b"));
        assert!(is_absolute_path("/usr/bin/node") && !is_absolute_path("conn.mjs"));
        assert!(platform_root("/usr/bin/node") && platform_root("/nix/store/x/bin/node"));
        assert!(!platform_root("/home/agent/bin/conn"), "the agent's own directory is not the platform's");
    }

    #[test]
    fn only_absolute_script_paths_are_covered_by_the_launch_cross_check() {
        crate::test_facts::install();
        assert!(is_script_path("/home/agent/scripts/mcp-client.mjs"));
        assert!(is_script_path("C:\\Users\\agent\\scripts\\connector.py"));
        assert!(!is_script_path("mcp-client.mjs"), "a bare name is resolved by PATH, not by us");
        assert!(!is_script_path("/tmp/request.json"), "a request file is not a script");
        assert!(!is_script_path("--request-file"));
        assert!(!is_script_path("/usr/bin/node"), "the platform binary is not the connector's script");
    }

    // This round's first hole: the child spawns server.program/args/cwd from the request file, so THAT
    // command must be the one the operator approved.
    #[test]
    fn the_request_the_child_reads_must_name_the_approved_command() {
        crate::test_facts::install();
        let client = scratch("request-client.mjs", "export const c = 1;\n");
        let client_path = client.to_string_lossy().to_string();
        let approved_args = vec![client_path.clone()];
        let approved = approval("/usr/bin/node", "", &[], &approved_args, &[&client], &["TOKEN"]);
        let good = request("/usr/bin/node", &[&client_path], None);
        assert!(request_server_problem(&good, &approved).is_ok(),
            "{:?}", request_server_problem(&good, &approved));

        // The attack: a background loop rewrites server.program between the console's write and the
        // child's read.
        let smuggled = request("/bin/sh", &["-c", "echo $TOKEN"], None);
        let refused = request_server_problem(&smuggled, &approved).unwrap_err();
        assert!(refused.starts_with("vault_request_program_mismatch:"), "{refused}");
        assert!(refused.contains("/bin/sh"), "{refused}");
        // A command line, a directory or a transport the operator never approved.
        let extra = request("/usr/bin/node", &[&client_path, "--eval", "1"], None);
        assert!(request_server_problem(&extra, &approved).unwrap_err()
            .starts_with("vault_request_arguments_mismatch:"));
        let mut rewired = request("/usr/bin/node", &[&client_path], None);
        let mut document: Value = serde_json::from_slice(&rewired).expect("a request");
        document["server"]["env"] = json!({"TOKEN": "TOKEN", "EXTRA": "PATH"});
        rewired = serde_json::to_vec(&document).expect("a request");
        assert!(request_server_problem(&rewired, &approved).unwrap_err()
            .starts_with("vault_request_environment_mismatch:"));
        let moved = request("/usr/bin/node", &[&client_path], Some("/tmp"));
        assert!(request_server_problem(&moved, &approved).unwrap_err().starts_with("vault_request_cwd_mismatch:"));
        let http = serde_json::to_vec(&json!({"server": {"transport": "http", "url": "https://example.com/mcp"}}))
            .expect("a request");
        assert!(request_server_problem(&http, &approved).unwrap_err()
            .starts_with("vault_request_transport_not_checked:"));
        let garbage = b"not a request".to_vec();
        assert!(request_server_problem(&garbage, &approved).unwrap_err().starts_with("vault_request_unreadable:"));
        // A relative script, and a program outside the platform's roots the approval does not name.
        let mut relative = approved.clone();
        relative["args"] = json!(["conn.mjs"]);
        assert!(request_server_problem(&request("/usr/bin/node", &["conn.mjs"], None), &relative)
            .unwrap_err().starts_with("vault_request_path_not_absolute:"));
        // A program outside the platform's roots the approval does not name. It is a native node, so
        // the refusal is the COVERAGE one: a file in neither family is refused earlier, by the allow-list
        // (round 8), which is asserted straight after.
        let binary = scratch_native("node");
        let program = binary.to_string_lossy().to_string();
        let mut outside = approved.clone();
        outside["program"] = json!(program);
        outside["args"] = json!([]);
        assert!(request_server_problem(&request(&program, &[], None), &outside).unwrap_err()
            .starts_with("vault_request_program_not_covered:"));
        let script = scratch("request-conn", "#!/bin/sh\necho value\n");
        let scripted = script.to_string_lossy().to_string();
        let mut family = approved.clone();
        family["program"] = json!(scripted);
        family["args"] = json!([]);
        // The request-side check answers with the approval's own words for a PROGRAM (the console and the
        // kernel share one judgement, program_shape_problem), and with `vault_request_` for the arguments
        // it re-resolves against this request's own words.
        assert!(request_server_problem(&request(&scripted, &[], None), &family).unwrap_err()
            .starts_with("vault_approval_program_not_allowed:"));
        let _ = std::fs::remove_file(&client);
        let _ = std::fs::remove_file(&binary);
        let _ = std::fs::remove_file(&script);
    }

    // The seal half: the child is told the sha256 of the exact bytes the kernel checked, so a rewrite
    // after that check is refused in the child (scripts/test-mcp-request-seal.mjs proves the child side).
    #[test]
    fn the_request_seal_is_the_sha256_of_the_bytes_the_kernel_read() {
        crate::test_facts::install();
        let dir = std::env::temp_dir().join(format!("wa-request-seal-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let path = dir.join("request.json");
        let bytes = request("/usr/bin/node", &["/abs/conn.mjs"], None);
        std::fs::write(&path, &bytes).expect("the request");
        let path_text = path.to_string_lossy().to_string();
        let mut launch = spec("/usr/bin/node", &["--request-file".into(), path_text.clone()]);
        let approval = json!({"form": APPROVAL_FORM});
        assert!(seal_request(&mut launch, &approval, false).is_ok(),
            "a plain launch is sealed without an approval check");
        let sealed = launch.env.iter().find(|(name, _)| name == "WA_MCP_REQUEST_SHA256")
            .map(|(_, value)| value.clone());
        assert_eq!(sealed, Some(sha256_hex(&bytes)), "the child is given the bytes the kernel read");
        assert_eq!(launch.env.iter().find(|(name, _)| name == "WA_MCP_REQUEST_FILE").map(|(_, value)| value.clone()),
            Some(path_text.clone()));
        // A rewrite after the seal is exactly what the child refuses: what is on disk no longer hashes
        // to what was checked.
        std::fs::write(&path, request("/bin/sh", &["-c", "echo $TOKEN"], None)).expect("rewrite");
        assert_ne!(sealed, Some(sha256_hex(&std::fs::read(&path).expect("the rewritten request"))),
            "the sealed digest is the bytes the kernel checked, not what is on disk later");
        // A vault launch that names no request file has nothing to compare the approved command against.
        let mut bare = spec("/usr/bin/node", &[]);
        assert!(seal_request(&mut bare, &approval, true).unwrap_err().starts_with("vault_request_unnamed:"));
        assert!(seal_request(&mut bare, &approval, false).is_ok(), "a plain launch needs no request file");
        let _ = std::fs::remove_file(&path);
    }

    // ---- round 6: the interpreter, the arguments, the ownership of a platform root, the recheck ----
    //
    // Each of these fails on 6596aecc. They are the four shapes the review named, from the approval's own
    // data, so they hold for a launch the console never touched.

    /// Findings 1 and 5: the process the vault values are put in is the interpreter the launch SPAWNS,
    /// which is not always the definition's program, and "/usr/bin is the platform's" is a claim about
    /// OWNERSHIP - a path prefix alone called /usr/local/bin the platform's on a machine where the user
    /// owns it.
    #[test]
    fn the_interpreter_the_launch_spawns_is_the_platforms_own_or_in_the_digest() {
        crate::test_facts::install();
        // Round 8: this fixture is a REAL native node, because the allow-list judges the spawned
        // interpreter by what the file IS - a shell script called `node` is refused by it, one step
        // before the coverage rule this test is about.
        let owned = scratch_native("node");
        let ours = crate::operations::real_path(&owned.to_string_lossy());
        // A file this user owns is never the platform's, and a platform prefix cannot make it so.
        assert!(!crate::operations::owned_by_root(&ours), "a file this user owns is not root-owned: {ours}");
        assert!(!crate::operations::platform_owned(&ours), "and a path the platform does not own is not platform_owned");
        // The real thing is: a root-owned, not group/other-writable system program and its directories.
        assert!(crate::operations::owned_by_root("/usr/bin"), "/usr/bin is root-owned and not writable by us");
        assert!(crate::operations::platform_owned("/usr/bin/env"), "/usr/bin/env is the platform's own");
        assert!(!crate::operations::platform_owned("/usr/local/bin/wasm-agent-nothing-here"),
            "a path that is not there is not the platform's");
        assert!(crate::operations::PLATFORM_ROOTS.contains(&"/System/"), "the Lua and Rust lists agree (/System/)");

        // The definition names the platform's node; the launch is told to spawn a file this user owns,
        // which nobody hashed - the WA_NODE shape, and <data>/node after it.
        let approved = approval("/usr/bin/node", "", &[], &[], &[], &["TOKEN"]);
        let refused = approval_problem(&approved, &spec(&ours, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_interpreter_not_covered:"), "{refused}");
        assert!(refused.contains(&ours), "the refusal names the interpreter: {refused}");
        // Covered by the digest, the same launch reads the value.
        let covered = approval("/usr/bin/node", "", &[], &[], &[&owned], &["TOKEN"]);
        assert!(approval_problem(&covered, &spec(&ours, &[])).is_ok(),
            "{:?}", approval_problem(&covered, &spec(&ours, &[])));
        let _ = std::fs::remove_file(&owned);
    }

    /// Round 8: the spawned interpreter is judged by the same ALLOW-LIST as the connector's own program,
    /// and that arm had no test on either side - the test above asserts interpreter_not_covered, which
    /// fires one step LATER. On a host where "which node" is a mise/asdf/nvm shim the realpath is not
    /// node (measured here: /home/victor/.local/share/mise/shims/node -> /usr/bin/mise), so this arm is
    /// the first thing such a host hits.
    #[test]
    fn the_interpreter_the_launch_spawns_is_held_to_the_allow_list() {
        crate::test_facts::install();
        // A native binary whose REALPATH is an interpreter: it is native, it is in the digest, and it is
        // still refused, because what it IS (python3) is not one of the two families.
        let interpreter = native_copy("python3");
        let approved = approval("/usr/bin/node", "", &[], &[], &[&interpreter], &["TOKEN"]);
        let refused = approval_problem(&approved, &spec(&interpreter.to_string_lossy(), &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        // And a copy NAMED node that is only a shell script: the name is not the program, so it is
        // refused one branch later (not_native) than a name outside the allow-list.
        // Round 9: NOT `fake-node` in the shared directory. The round-6 test beside this one writes a FILE
        // of that name through `scratch` (a shell script called node), and a directory and a file cannot
        // share the path: whichever ran second failed with `AlreadyExists`, one suite run in three. The
        // directory is its own subtree, so both tests keep their fixture.
        let fake_dir = std::env::temp_dir()
            .join(format!("wa-vault-approval-{}/fake-node-tree", std::process::id()));
        std::fs::create_dir_all(&fake_dir).expect("scratch dir");
        let fake = fake_dir.join("node");
        std::fs::write(&fake, "#!/bin/sh\nexit 0\n").expect("a shell script called node");
        let vouched = approval("/usr/bin/node", "", &[], &[], &[&fake], &["TOKEN"]);
        let refused = approval_problem(&vouched, &spec(&fake.to_string_lossy(), &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_native:"), "{refused}");
    }

    /// Finding 5: Lua and Rust keep lists of refused names, and they drifted - the Rust list matched
    /// "Rscript" only by accident while Lua lowercased first. ONE table (fixtures/mcp-refused-names.json)
    /// is the source of both, and both compare case-insensitively.
    #[test]
    fn the_refused_name_lists_are_the_shared_table_and_case_insensitive() {
        crate::test_facts::install();
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/mcp-refused-names.json");
        let table: Value = serde_json::from_slice(&std::fs::read(&path).expect("the shared table"))
            .expect("the shared table is JSON");
        let listed = |key: &str| -> Vec<String> {
            table[key].as_array().expect(key).iter()
                .map(|entry| entry.as_str().expect("a name").to_string()).collect()
        };
        let mut rust_interpreters: Vec<String> =
            crate::operations::REFUSED_INTERPRETERS.iter().map(|name| name.to_string()).collect();
        let mut rust_wrappers: Vec<String> =
            crate::operations::REFUSED_WRAPPERS.iter().map(|name| name.to_string()).collect();
        let mut rust_allowed: Vec<String> =
            crate::operations::ALLOWED_PROGRAMS.iter().map(|name| name.to_string()).collect();
        let mut wanted_interpreters = listed("refused_interpreters");
        let mut wanted_wrappers = listed("refused_wrappers");
        let mut wanted_allowed = listed("allowed_programs");
        rust_interpreters.sort();
        wanted_interpreters.sort();
        rust_wrappers.sort();
        wanted_wrappers.sort();
        rust_allowed.sort();
        wanted_allowed.sort();
        assert_eq!(rust_interpreters, wanted_interpreters, "the interpreter list is the shared table");
        assert_eq!(rust_wrappers, wanted_wrappers, "the wrapper list is the shared table");
        assert_eq!(rust_allowed, wanted_allowed, "the allow-list is the shared table");
        // Case-insensitive on BOTH sides: "Rscript" (as macOS spells it) is the same name as "rscript".
        for spelling in ["Rscript", "RSCRIPT", "rscript"] {
            let found = crate::operations::refused_interpreter_or_wrapper(spelling)
                .unwrap_or_else(|| panic!("{spelling} is a refused interpreter"));
            assert_eq!(found.0, "interpreter", "{spelling}");
        }
        for spelling in ["Env", "TIMEOUT", "timeout"] {
            let found = crate::operations::refused_interpreter_or_wrapper(spelling)
                .unwrap_or_else(|| panic!("{spelling} is a refused wrapper"));
            assert_eq!(found.0, "wrapper", "{spelling}");
        }
        // A versioned name is the same interpreter, and the allowed families are not in either list.
        assert_eq!(crate::operations::refused_interpreter_or_wrapper("python3.11").map(|found| found.0), Some("interpreter"));
        assert!(crate::operations::refused_interpreter_or_wrapper("node").is_none());
        assert!(crate::operations::refused_interpreter_or_wrapper("bash").is_none());
    }

    /// Round 8: the allow-list, judged by REALPATH and by what the file IS, and the voucher that is the
    /// one way a native binary outside the two families runs a vault connector.
    #[test]
    fn an_interpreter_or_a_wrapper_is_refused_whatever_its_name_or_voucher() {
        crate::test_facts::install();
        // Every refused family, under a versioned name and with its own argument list: refused as a
        // PROGRAM, whether or not the operator recorded a --native voucher for it.
        for program in ["/usr/bin/python3.11", "/usr/bin/perl5.36", "/usr/bin/env", "/usr/bin/timeout",
                        "/usr/bin/nohup", "/usr/bin/xargs"] {
            let refused = crate::operations::program_refusal(program, None)
                .unwrap_or_else(|| panic!("{program} is refused"));
            assert!(refused.starts_with("vault_approval_program_not_allowed:")
                || refused.starts_with("vault_approval_program_wrapper:"), "{program}: {refused}");
            let vouched = crate::operations::program_refusal(program, Some(program));
            assert!(vouched.is_some(), "--native must not approve {program}");
        }
        // A native binary under another name is NOT allowed without a voucher (its basename is not one
        // of the two families), and IS allowed with one - and then the bytes are in the digest.
        let copy = scratch("native-copy", "#!/bin/sh
exit 0
");
        let copied = crate::operations::real_path(&copy.to_string_lossy());
        let refused = crate::operations::program_refusal(&copied, None).expect("a name outside the two families");
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        // The voucher covers a NATIVE executable only: this fixture is a script, so even vouched for it
        // is refused by name rather than approved on a name the operator trusted.
        let vouched = crate::operations::program_refusal(&copied, Some(copied.as_str())).expect("a script is not native");
        assert!(vouched.starts_with("vault_approval_program_native_not_executable:"), "{vouched}");
        // A script wearing an ALLOWED name is refused too: /bin/sh copied to ./node is not node.
        let fake = scratch("fake-node", "#!/bin/sh
exit 0
");
        let fake_path = crate::operations::real_path(&fake.to_string_lossy());
        let refused = crate::operations::program_refusal(&fake_path, None).unwrap_or_default();
        assert!(refused.starts_with("vault_approval_program_native_not_executable:")
            || refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        let _ = std::fs::remove_file(&copy);
        let _ = std::fs::remove_file(&fake);
    }

    /// Round 8, finding 4: the flag is compared BEFORE an '=', and a short cluster is split, so
    /// "--eval=code" and "-pe" are the inline code a whole-string comparison let through.
    #[test]
    fn an_inline_flag_is_matched_before_its_value_and_through_a_cluster() {
        crate::test_facts::install();
        let inline = |program: &str, value: &str| crate::operations::inline_flag(program, value);
        assert_eq!(inline("/usr/bin/node", "--eval=process.exit(0)").as_deref(), Some("--eval"));
        assert_eq!(inline("/usr/bin/node", "--print=1").as_deref(), Some("--print"));
        assert_eq!(inline("/usr/bin/node", "-pe").as_deref(), Some("-p (in -pe)"));
        assert_eq!(inline("/bin/sh", "-ec").as_deref(), Some("-c (in -ec)"));
        // A long option is never split: --print is one flag, not --p, --r, --i, --n, --t. The run of
        // letters after the dash is not a cluster of short flags.
        assert_eq!(inline("/usr/bin/python3", "--require").as_deref(), Some("--require"));
        assert_eq!(inline("/usr/bin/python3", "--require=x").as_deref(), Some("--require"));
        assert_eq!(inline("/usr/bin/python3", "--nosuchflag"), None);
        assert_eq!(inline("/usr/bin/node", "--mode"), None);
        assert_eq!(inline("/usr/bin/node", "/abs/script.mjs"), None);
    }

    /// Finding 2: program /usr/bin/node, args ["server"], cwd /home/u/conn runs ./server.js, and
    /// looks_like_path saw nothing because "server" has no slash and no extension.
    #[test]
    fn an_argument_is_resolved_from_the_connectors_own_directory() {
        crate::test_facts::install();
        let dir = std::env::temp_dir().join(format!("wa-vault-cwd-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let script = dir.join("server.js");
        std::fs::write(&script, "export const run = 1;\n").expect("the script a bare word names");
        let cwd = dir.to_string_lossy().to_string();
        let bare = vec!["server".to_string()];
        // Named by the digest, the bare word launches.
        let named = approval("/usr/bin/node", &cwd, &[], &bare, &[&script], &["TOKEN"]);
        assert!(approval_problem(&named, &spec("/usr/bin/node", &bare)).is_ok(),
            "{:?}", approval_problem(&named, &spec("/usr/bin/node", &bare)));
        // Not named, it is a file this launch runs and the approval does not cover.
        let unnamed = approval("/usr/bin/node", &cwd, &[], &bare, &[], &["TOKEN"]);
        let refused = approval_problem(&unnamed, &spec("/usr/bin/node", &bare)).unwrap_err();
        assert!(refused.starts_with("vault_approval_argument_not_covered:"), "{refused}");
        assert!(refused.contains("server.js"), "the refusal names the resolved file: {refused}");
        // A file that is not there cannot be resolved, so the argument is refused by name: it can appear
        // between the approval and the launch.
        let absent = vec!["absent".to_string()];
        let unresolved = approval("/usr/bin/node", &cwd, &[], &absent, &[], &["TOKEN"]);
        let refused = approval_problem(&unresolved, &spec("/usr/bin/node", &absent)).unwrap_err();
        assert!(refused.starts_with("vault_approval_argument_unresolved:absent:"), "{refused}");
        // An inline string is code no digest of files can name.
        let inline = vec!["-e".to_string(), "console.log(process.env.TOKEN)".to_string()];
        let run = approval("/usr/bin/node", &cwd, &[], &inline, &[], &["TOKEN"]);
        let refused = approval_problem(&run, &spec("/usr/bin/node", &inline)).unwrap_err();
        assert!(refused.starts_with("vault_approval_inline_code:-e:"), "{refused}");
        // The value of an option is a value, not a file: --mode stdio stays approvable.
        let option_value = vec![script.to_string_lossy().to_string(), "--mode".to_string(), "stdio".to_string()];
        let ok = approval("/usr/bin/node", &cwd, &[], &option_value, &[&script], &["TOKEN"]);
        assert!(approval_problem(&ok, &spec("/usr/bin/node", &option_value)).is_ok(),
            "{:?}", approval_problem(&ok, &spec("/usr/bin/node", &option_value)));
        let _ = std::fs::remove_file(&script);
    }

    // ---- round 7: node's own order, the ambiguity, the interpreters the digest cannot follow ----

    /// Finding 1: the implied extensions were .mjs, .js, .cjs, /index.* - neither node's order nor even the
    /// extensions node implies. `node ./a` with only a.mjs beside it does not run (measured on node 26), so
    /// the digest named a file nothing runs; with a.mjs AND a.js it runs a.js, which the digest had not
    /// hashed. node's order is matched (exact, .js, .json, .node, then the directory), and a name more than
    /// one file answers to is refused rather than resolved by node's priority.
    #[test]
    fn a_name_is_resolved_in_nodes_own_order_and_an_ambiguous_one_is_refused() {
        crate::test_facts::install();
        let dir = std::env::temp_dir().join(format!("wa-vault-order-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("scratch dir");
        let cwd = dir.to_string_lossy().to_string();
        let server_js = dir.join("server.js");
        std::fs::write(&server_js, "export const run = 1;
").expect("server.js");
        let word = vec!["server".to_string()];
        // The one file that answers to the word is covered, and a launch naming it is accepted.
        let named = approval("/usr/bin/node", &cwd, &[], &word, &[&server_js], &["TOKEN"]);
        assert!(approval_problem(&named, &spec("/usr/bin/node", &word)).is_ok(),
            "{:?}", approval_problem(&named, &spec("/usr/bin/node", &word)));
        // A second file that answers to the SAME word makes it ambiguous: the launch is refused by name,
        // and the refusal names both files, because neither of them is "the" file the operator approved.
        let server_json = dir.join("server.json");
        std::fs::write(&server_json, "{}").expect("server.json");
        let refused = approval_problem(&named, &spec("/usr/bin/node", &word)).unwrap_err();
        assert!(refused.starts_with("vault_approval_argument_ambiguous:server:"), "{refused}");
        assert!(refused.contains("server.js") && refused.contains("server.json"), "{refused}");
        std::fs::remove_file(&server_json).expect("remove server.json");
        // .mjs is NOT implied: with only alone.mjs there, node runs nothing, so the word resolves to
        // nothing either - the round-6 answer named alone.mjs and handed it the value.
        let alone = dir.join("alone");
        std::fs::create_dir_all(&alone).expect("scratch dir");
        std::fs::write(alone.join("alone.mjs"), "export const run = 3;
").expect("alone.mjs");
        let alone_cwd = alone.to_string_lossy().to_string();
        let word_alone = vec!["alone".to_string()];
        let unresolved = approval("/usr/bin/node", &alone_cwd, &[], &word_alone, &[], &["TOKEN"]);
        let refused = approval_problem(&unresolved, &spec("/usr/bin/node", &word_alone)).unwrap_err();
        assert!(refused.starts_with("vault_approval_argument_unresolved:alone:"), "{refused}");
        // A .mjs beside the .js is not an answer to the word: node runs server.js, which the digest names,
        // so the approval still holds.
        let server_mjs = dir.join("server.mjs");
        std::fs::write(&server_mjs, "export const run = 2;
").expect("server.mjs");
        assert!(approval_problem(&named, &spec("/usr/bin/node", &word)).is_ok(),
            "{:?}", approval_problem(&named, &spec("/usr/bin/node", &word)));
        // A directory is resolved by its index file, which is hashed in turn.
        let package_dir = dir.join("pkg");
        std::fs::create_dir_all(&package_dir).expect("scratch dir");
        let index = package_dir.join("index.js");
        std::fs::write(&index, "export const run = 4;
").expect("index.js");
        let folder = vec!["pkg".to_string()];
        let covered = approval("/usr/bin/node", &cwd, &[], &folder, &[&index], &["TOKEN"]);
        assert!(approval_problem(&covered, &spec("/usr/bin/node", &folder)).is_ok(),
            "{:?}", approval_problem(&covered, &spec("/usr/bin/node", &folder)));
        let _ = std::fs::remove_dir_all(&package_dir);
    }

    /// Finding 2: the interpreter families covered only JavaScript and shell, so python3 -c, perl -e,
    /// ruby -e and every interpreter's own module system passed - the program was the platform's and the
    /// code was a string nothing hashed. A program that IS such an interpreter is refused by name, and a
    /// code option given to a program the digest cannot classify is refused as inline code.
    #[test]
    fn an_interpreter_this_digest_cannot_follow_is_refused_by_name() {
        crate::test_facts::install();
        for program in ["/usr/bin/python3", "/usr/bin/python3.11", "/usr/bin/perl", "/usr/bin/ruby3.2",
                        "/usr/local/bin/deno", "/opt/bun", "/usr/bin/php8.2", "/usr/bin/lua5.4"] {
            let refused = crate::operations::program_shape_problem(program).expect("an unfollowed interpreter");
            assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{program}: {refused}");
            assert!(refused.contains("/mcp <id> probe"), "the way to approve it again is in it: {refused}");
        }
        // The two families the digest DOES follow stay approvable as programs.
        assert!(crate::operations::program_shape_problem("/usr/bin/node").is_none());
        assert!(crate::operations::program_shape_problem("/bin/sh").is_none());
        // A code option given to a program the digest cannot classify is still code, not a value, and
        // round 8 decides that from the FAMILY: a program outside node and the shells has no family of
        // its own, so every one of CODE_FLAGS is code. A native binary is the only such program the
        // allow-list lets through (as the operator's --native voucher), and it is judged here.
        let runner_path = scratch_native("runner");
        let runner = runner_path.to_string_lossy().to_string();
        let inline = vec!["-c".to_string(), "print(1)".to_string()];
        assert_eq!(crate::operations::interpreter_family(&runner), "unknown", "no family: every code flag is code");
        assert_eq!(crate::operations::inline_flag(&runner, "-c").as_deref(), Some("-c"), "a code flag, no family");
        assert_eq!(crate::operations::inline_flag(&runner, "-m").as_deref(), Some("-m"), "and so is -m");
        // Unvouched, the allow-list answers first: a native binary outside the two families needs the
        // operator's own voucher before its command line is even read.
        let coded = approval(&runner, "", &[], &inline, &[], &["TOKEN"]);
        let refused = approval_problem(&coded, &spec(&runner, &inline)).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        // Vouched for, the program passes the allow-list - and its inline code is STILL refused, because
        // a native binary's own loads are outside the digest and a string it evaluates is outside it too.
        let digest = sha256_hex(&std::fs::read(&runner_path).expect("the vouched binary"));
        let vouched = json!({"form": APPROVAL_FORM, "sha256": "00".repeat(32), "program": runner,
            "cwd": "", "env": [], "args": inline, "files": [runner.clone()], "vault": ["TOKEN"],
            "native": {"path": runner, "sha256": digest}});
        let refused = approval_problem(&vouched, &spec(&runner, &inline)).unwrap_err();
        assert!(refused.starts_with("vault_approval_inline_code:-c:"), "{refused}");
        // A shell script outside both families never reaches the flag rule: the allow-list refuses the
        // program itself, which is the point of an allow-list rather than a list of code flags.
        let scripted = scratch("runner-script", "#!/bin/sh\nexit 0\n");
        let scripted = scripted.to_string_lossy().to_string();
        let coded = approval(&scripted, "", &[], &inline, &[], &["TOKEN"]);
        let refused = approval_problem(&coded, &spec(&scripted, &inline)).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        // What node's own family names as a file stays a file (--require/-r), not inline code.
        let loads = scratch("loads.mjs", "export const load = 1;
");
        let require = vec!["-r".to_string(), loads.to_string_lossy().to_string()];
        let path_option = approval("/usr/bin/node", "", &[], &require, &[&loads], &["TOKEN"]);
        assert!(approval_problem(&path_option, &spec("/usr/bin/node", &require)).is_ok(),
            "{:?}", approval_problem(&path_option, &spec("/usr/bin/node", &require)));
        let _ = std::fs::remove_file(&runner);
    }

    /// Finding 3: the refusal said "no value was used", and it was not true - the value was put in the
    /// child's environment before the spawn, so a file rewritten between the check and the launch had
    /// already received it. The sentence is the operator's and it is compared verbatim here, so a later
    /// edit that softens it fails this test.
    #[test]
    fn a_change_after_the_check_names_the_value_as_exposed() {
        crate::test_facts::install();
        let script = scratch("exposed.mjs", "export const ok = 1;
");
        let verified = vec![(crate::operations::real_path(&script.to_string_lossy()),
            sha256_hex(&std::fs::read(&script).expect("the script")))];
        std::fs::write(&script, "export const ok = 2;
").expect("rewrite");
        let refused = crate::operations::recheck_after_spawn(&verified).expect("a rewrite is a mismatch");
        let expected = format!("vault_approval_changed_since_check:{}: a file this connector runs changed between the check and the launch, so the operation was killed - the value had already been put in its environment at launch, so treat it as exposed and rotate it if this change was not yours. Approve it again at the operator's terminal: /mcp <id> probe, then /mcp <id> on", crate::operations::real_path(&script.to_string_lossy()));
        assert_eq!(refused, expected);
        let _ = std::fs::remove_file(&script);
    }

    /// Finding 4: the code files were hashed before the spawn and never again, so a rewrite that lands
    /// between the hash and the child's open was caught by nothing. The same bytes are now hashed after
    /// the spawn, and a mismatch kills the operation.
    #[test]
    fn a_rewrite_between_the_check_and_the_spawn_is_caught() {
        crate::test_facts::install();
        let script = scratch("recheck.mjs", "export const ok = 1;\n");
        let verified = vec![(crate::operations::real_path(&script.to_string_lossy()),
            sha256_hex(&std::fs::read(&script).expect("the script")))];
        assert!(crate::operations::recheck_after_spawn(&verified).is_none(), "the approved bytes are still there");
        std::fs::write(&script, "export const ok = 2;\n").expect("rewrite");
        let refused = crate::operations::recheck_after_spawn(&verified).expect("a rewrite is a mismatch");
        assert!(refused.starts_with("vault_approval_changed_since_check:"), "{refused}");
        // Not reading it is not passing it: a file that vanished is a mismatch too.
        std::fs::remove_file(&script).expect("remove");
        assert!(crate::operations::recheck_after_spawn(&verified).is_some(), "a file that cannot be read is a mismatch");
    }

    /// Item 1 of round 9: `--native` works END TO END. The kernel has two judgements about a program -
    /// approval_problem (the launch) and request_server_problem (the command the child spawns from the
    /// request file) - and only the first read the operator's voucher. A vouched ELF therefore passed the
    /// approval and was refused one step later, by the request check, so `/mcp <id> on --native` could
    /// never launch: the review's first item, and the reason both now take the same `program_refusal`
    /// judgement with the same voucher.
    #[test]
    fn a_vouched_native_binary_passes_the_approval_and_the_request_check() {
        crate::test_facts::install();
        let binary = scratch_native("vouched-node");
        let path = binary.to_string_lossy().to_string();
        // The launch as the console really builds it (lua/core/mcp.lua: `program=node_program()`): the
        // kernel spawns the interpreter, which spawns the connector's program from the request file. The
        // connector's program here is a native binary outside the two families, vouched for.
        // Host-independent (item 6): the spawned interpreter is a FIXTURE binary named node, not
        // /usr/bin/node, so this test says the same thing on a host that keeps node somewhere else - or
        // nowhere. A real ELF named `node` passes the allow-list by its name and its bytes.
        let runtime = scratch_native("node");
        let runtime_path = runtime.to_string_lossy().to_string();
        let client = scratch("native-client.mjs", "export const c = 1;\n");
        let request_path = scratch("native-request.json", "{}");
        let launch = spec(&runtime_path, &[client.to_string_lossy().to_string(),
            "--request-file".into(), request_path.to_string_lossy().to_string()]);
        let approved = approval_native(&binary, &[&binary, &client, &runtime], &["TOKEN"]);
        assert!(approval_problem(&approved, &launch).is_ok(),
            "a vouched native binary is a program the allow-list admits: {:?}",
            approval_problem(&approved, &launch));
        // The same command as the child reads it from the request file. This is the half that was missing.
        let sealed = request(&path, &[], None);
        assert!(request_server_problem(&sealed, &approved).is_ok(),
            "the request check carries the same voucher: {:?}",
            request_server_problem(&sealed, &approved));
        // The voucher admits a FILE, not the family: another native binary, unvouched, is refused by the
        // same allow-list it was refused by before this round.
        let other = scratch_native("unvouched-node");
        let other_path = other.to_string_lossy().to_string();
        let mut unvouched = approved.clone();
        unvouched["program"] = json!(other_path);
        unvouched["args"] = json!([]);
        let refused = request_server_problem(&request(&other_path, &[], None), &unvouched).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        // And WITHOUT the voucher the same approval is refused one step earlier, on the launch side: this
        // is what `--native` buys, and what its absence costs.
        let plain = approval(&path, "", &[], &[], &[&binary, &client, &runtime], &["TOKEN"]);
        let refused = approval_problem(&plain, &launch).unwrap_err();
        assert!(refused.starts_with("vault_approval_program_not_allowed:"), "{refused}");
        let _ = std::fs::remove_file(&runtime);
        let _ = std::fs::remove_file(&binary);
        let _ = std::fs::remove_file(&other);
        let _ = std::fs::remove_file(&client);
        let _ = std::fs::remove_file(&request_path);
    }

    /// Item 1: each of the three native refusals is reached by a test of its own, from an approval the
    /// console really writes (the binary IS one of the files it names) - and each of them fires BEFORE a
    /// spawn, so a changed binary never runs.
    #[test]
    fn a_native_binary_that_changed_or_vanished_or_was_not_named_is_refused() {
        crate::test_facts::install();
        // Changed after the approval: the bytes on disk are not the bytes the operator vouched for.
        // Host-independent: a fixture interpreter named node stands in for the platform's.
        let runtime = scratch_native("node");
        let runtime_path = runtime.to_string_lossy().to_string();
        let binary = scratch_native("changed-node");
        let approved = approval_native(&binary, &[&binary, &runtime], &["TOKEN"]);
        let path = binary.to_string_lossy().to_string();
        use std::io::Write as _;
        std::fs::OpenOptions::new().append(true).open(&binary).expect("open")
            .write_all(b"\0").expect("append a byte");
        let refused = approval_problem(&approved, &spec(&runtime_path, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_native_changed:"), "{refused}");
        assert!(refused.contains(&path), "the refusal names the binary: {refused}");

        // Gone after the approval: the console lists the vouched binary among the files, so this is the
        // read that fails first - and it says NATIVE, not "a script this connector was approved with".
        let vanished = scratch_native("vanished-node");
        let approved = approval_native(&vanished, &[&vanished, &runtime], &["TOKEN"]);
        let path = vanished.to_string_lossy().to_string();
        std::fs::remove_file(&vanished).expect("remove the vouched binary");
        let refused = approval_problem(&approved, &spec(&runtime_path, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_native_unreadable:"), "{refused}");
        assert!(!refused.contains("a script this connector was approved with"),
            "a native binary that vanished is not reported as a script: {refused}");

        // A voucher for a file the approval does not name: the digest covers a file list, and a voucher
        // outside it would approve a binary nothing hashed.
        let outside = scratch_native("outside-node");
        let approved = approval_native(&outside, &[&runtime], &["TOKEN"]);
        let refused = approval_problem(&approved, &spec(&runtime_path, &[])).unwrap_err();
        assert!(refused.starts_with("vault_approval_native_not_covered:"), "{refused}");
        let _ = std::fs::remove_file(&outside);
        let _ = std::fs::remove_file(&runtime);
    }
}

/// MUST 3 (review r1): the relay's deadline must not kill ADOPTED work.
///
/// The relay stamps the caller's deadline and the node installs it as this run's cancel flag
/// (serve::install_relay_context). The FOREGROUND `bash` path observes that flag and cancels its own
/// operation (operations.rs, "A cancelled run or child cancels its operation too"); the adoption path
/// this mission added is `control("start")`, which is detached and must survive it.
///
/// This drives the REAL flag through the production seam (host::set_run_cancel_probe +
/// serve::test_set_run_cancel, the same pair subagents' cancel test uses) and asserts three things:
/// the flag is live in this process (foreground IS cancelled by it - the old bug), the adopted start is
/// NOT cancelled by it, and the command's marker holds exactly ONE line, so nothing was re-run.
///
/// Isolation: `manager()` roots its records under $HOME, which is a OnceLock - so this test REFUSES to
/// run unless HOME is a scratch/temp directory, and scripts/test.sh runs it with HOME=$GATE_HOME.
#[cfg(test)]
mod adoption_survives_the_relay_deadline {
    use crate::operations::*;
    use crate::node::shell_config;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    fn scratch_home_or_refuse() -> std::path::PathBuf {
        let home = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default());
        let text = home.to_string_lossy().to_string();
        let scratch = text.contains("tmp") || text.contains("temp") || text.contains("scratch")
            || text.contains("TMP");
        let real = text.ends_with("/.wasm-agent");
        assert!(scratch && !real,
            "refusing to run: this test starts real operations, so HOME must be a scratch or temp \
             directory and never the node's own ~/.wasm-agent (got {text}); scripts/test.sh runs it \
             with HOME=$GATE_HOME");
        home
    }

    #[test]
    fn an_adopted_operation_survives_the_relay_deadline_and_runs_once() {
        crate::test_facts::install();
        let home = scratch_home_or_refuse();
        let marker = home.join("adoption-marker.txt");
        std::fs::write(&marker, "").expect("marker");
        let marker_text = marker.to_string_lossy().to_string();
        let shell = shell_config();
        let session = "relay:review-test".to_string();

        // The production serve layer registers this probe before a turn; here the test registers it and
        // flips the same thread-local flag the probe reads, so the REAL host check is what runs.
        // THE REAL RELAY ENTRY POINT, not a seam beside it (verification r2, SHOULD): this is the exact
        // call the serve layer makes for a relayed request (serve.rs, install_relay_context with the
        // job's cancel flag and deadline). Using it here means the test would still hold if the test-only
        // seam it used to call were removed.
        crate::node::set_run_cancel_probe(crate::node::serve_run_cancel_requested);
        let flag = Arc::new(AtomicBool::new(true));
        crate::node::install_relay_context(Some(flag.clone()), None, "relay:review-test".into());

        // 1. The flag is LIVE in this process: the foreground path cancels its own operation (the bug this
        // mission exists for). A test that did not prove this could pass while flipping nothing.
        let foreground = crate::operations::foreground(&shell.0, &shell.1, "sleep 5", "", 30, &serde_json::json!({}), None);
        assert!(foreground.is_err() || foreground.as_ref().map(|v| v["error"] == "run_cancelled"
                || v["ok"] == false).unwrap_or(false),
            "with the run cancelled, the foreground shell must be stopped, not reported done: {:?}",
            foreground.as_ref().map(|v| v["error"].clone()));

        // 2. Adoption: the same flag is still set, and this start must NOT be cancelled by it.
        let started = crate::operations::control("start", &serde_json::json!({
            "command": format!("printf 'run\\n' >> '{marker_text}'; sleep 3; echo adopted-done"),
            "cwd": "", "timeout_seconds": 60, "session": session, "background": true,
        }), &shell).expect("adopted start");
        let id = started["operation_id"].as_str().expect("operation id").to_string();

        // 3. It settles on its own, with the command's own result - not by the deadline.
        let settled = crate::operations::control("wait", &serde_json::json!({
            "id": id, "wait_ms": 20000, "session": session,
        }), &shell).expect("wait");
        crate::node::install_relay_context(None, None, String::new());
        assert_eq!(settled["settled"], serde_json::json!(true),
            "the adopted operation must settle by finishing, not by the run's cancel: {settled}");
        assert_ne!(settled["error"], serde_json::json!("cancelled"),
            "the adopted operation was CANCELLED by the relay deadline: {settled}");
        assert_eq!(flag.load(Ordering::SeqCst), true, "the flag stayed set the whole time");

        // 4. Exactly once: the marker holds ONE line, so the command was never re-run.
        let text = std::fs::read_to_string(&marker).expect("marker read");
        assert_eq!(text.matches("run").count(), 1,
            "the adopted command must have run exactly once, marker was {text:?}");
    }
}

/// Verification r3 (small): a relayed await RETURNS AT wait_ms, it does not hold until settlement.
///
/// The branch used to ignore wait_ms entirely and return only when the operation settled, so a relayed
/// await held the relay connection and a peer slot until the relay deadline (~35 s). This measures the
/// bound itself: a command that outlives the wait answers at the caller own wait_ms, unsettled, and the
/// SAME call again later answers its result. Isolation: manager() roots its records under HOME, a
/// OnceLock, so this refuses to run outside a scratch/temp HOME.
#[cfg(test)]
mod await_returns_at_its_own_wait {
    use crate::operations::*;
    use crate::node::shell_config;

    fn scratch_home_or_refuse() -> std::path::PathBuf {
        let home = std::path::PathBuf::from(std::env::var("HOME").unwrap_or_default());
        let text = home.to_string_lossy().to_string();
        let scratch = text.contains("tmp") || text.contains("temp") || text.contains("scratch")
            || text.contains("TMP");
        let real = text.ends_with("/.wasm-agent");
        assert!(scratch && !real,
            "refusing to run: this test starts real operations, so HOME must be a scratch or temp \
             directory and never the node own ~/.wasm-agent (got {text})");
        home
    }

    #[test]
    fn a_relayed_await_answers_at_wait_ms_and_never_holds_the_relay() {
        crate::test_facts::install();
        let _home = scratch_home_or_refuse();
        let shell = shell_config();
        let session = "relay:await-test".to_string();
        let started = crate::operations::control("start", &serde_json::json!({
            "command": "sleep 4; echo waited", "cwd": "", "timeout_seconds": 60,
            "session": session, "background": true,
        }), &shell).expect("start");
        let id = started["operation_id"].as_str().expect("id").to_string();

        // The caller asked for 700 ms and the command runs 4 s: the answer must be the STATE, at about
        // 700 ms, not the command result at about 4 s.
        let began = std::time::Instant::now();
        let first = crate::operations::control("await", &serde_json::json!({
            "id": id, "wait_ms": 700, "session": session,
        }), &shell).expect("await");
        let took = began.elapsed();
        assert!(took >= std::time::Duration::from_millis(600),
            "the wait really waited its own budget, took {took:?}");
        assert!(took < std::time::Duration::from_millis(3000),
            "and it did NOT hold until the command settled (4 s), took {took:?}");
        assert_eq!(first["settled"], serde_json::json!(false),
            "an unsettled command answers its state, never a false completion: {first}");

        // wait_ms is clamped to the tool documented maximum (10 s): a caller naming an hour is answered
        // inside 10 s, not held until the relay gives up.
        let began2 = std::time::Instant::now();
        let _ = crate::operations::control("await", &serde_json::json!({
            "id": id, "wait_ms": 3_600_000, "session": session,
        }), &shell).expect("await");
        assert!(began2.elapsed() < std::time::Duration::from_millis(12_000),
            "a huge wait_ms is clamped to 10 s, took {:?}", began2.elapsed());

        // The work is still there and still runs: the await did not cancel or re-run it.
        let settled = crate::operations::control("wait", &serde_json::json!({
            "id": id, "wait_ms": 10000, "session": session,
        }), &shell).expect("wait");
        assert_eq!(settled["settled"], serde_json::json!(true), "and it settles on its own: {settled}");
        let out = settled["stdout"].as_str().unwrap_or("");
        assert_eq!(out.matches("waited").count(), 1,
            "the command ran exactly once, stdout was {out:?}");
    }

    /// A STOP DOES NOT WAIT FOR THE SETTLE (change/esc-stops-now, follow-up 23/11).
    ///
    /// The cancelled-shell stop used to stay attached until the operation settled - a loop with a
    /// 1000 ms cap. Measured at load ~27 (twenty runs): the settle lands in 4-33 ms and the cap was never
    /// reached, so the cap was never main-health's 1041 ms; the wait is still the reader's time spent on
    /// bookkeeping that the supervisor already owns. What is pinned here:
    ///   * the receipt says the supervisor finishes the kill (cleanup: "supervised") and no longer claims
    ///     a settle it did not watch;
    ///   * the call for a sleep-5 shell comes back at once, not after the shell it only had to cancel;
    ///   * the operation really does settle BEHIND the call - the kill is not lost by returning early.
    /// A stop that waited would answer cleanup: "settled" and would have spent the wait on the prompt.
    #[test]
    fn a_cancelled_shell_returns_before_its_settle_finishes() {
        crate::test_facts::install();
        use std::sync::{Arc, atomic::AtomicBool};
        let _home = scratch_home_or_refuse();
        let shell = shell_config();
        // The production probe, and the same relay context the serve layer installs - flipped to
        // cancelled before the shell starts, which is exactly the state Esc leaves behind.
        crate::node::set_run_cancel_probe(crate::node::serve_run_cancel_requested);
        let flag = Arc::new(AtomicBool::new(true));
        crate::node::install_relay_context(Some(flag), None, "relay:cancel-settle-test".into());
        let started = std::time::Instant::now();
        // The seventh argument is the stdin the foreground path now carries (change/run-bodies-without-
        // quoting); this stop test sends none, and the signature is the one that has to be called.
        let receipt = crate::operations::foreground(&shell.0, &shell.1, "sleep 5", "", 30, &serde_json::json!({}), None)
            .expect("a cancelled shell is a receipt, not an error");
        let elapsed = started.elapsed();
        assert_eq!(receipt["error"], serde_json::json!("run_cancelled"), "receipt: {receipt}");
        assert_eq!(receipt["cleanup"], serde_json::json!("supervised"),
            "a stop must not claim a settle it did not watch: {receipt}");
        assert!(elapsed < std::time::Duration::from_millis(600),
            "the stop waited {elapsed:?} for a shell it only had to cancel");
        // ...and the supervisor finishes it behind the call.
        let id = receipt["operation_id"].as_str().expect("operation id").to_string();
        let mut settled = false;
        for _ in 0..60 {
            let state = crate::operations::manager().wait(&id, std::time::Duration::from_millis(50))
                .expect("operation state");
            if state["settled"] == serde_json::json!(true) { settled = true; break; }
        }
        assert!(settled, "the cancelled shell never settled behind the call");
    }
}

/// ITEM 4 (23/11): a promotion SAYS SO in the same result, with the output so far.
///
/// The measured complaint (ledger notes 106, 148, 151, 170): a foreground shell whose descendants were
/// adopted turned into a background operation, and the answer a reader got did not say that had happened -
/// it read like an ordinary command answer with a `note` about "descendants", so the caller either re-ran the
/// work or hunted for an id it had not noticed. This drives the REAL foreground path with a command that
/// exits leaving a live descendant, and pins the sentence, the seconds it happened at, the operation to
/// await and the output so far.
///
/// Isolation: `manager()` roots its records under $HOME (a OnceLock), so the test REFUSES to run unless HOME
/// is a scratch/temp directory - the same guard the adopted-tree tests beside it use.
    #[test]
    fn child_shell_is_marked_in_turn_and_cannot_request_installation() {
        crate::test_facts::install();
        use crate::node::{TaskContext,Provenance,SocketSlot};
        use std::sync::{Arc,atomic::AtomicBool};
        // The HOST installs the task context; the runner reads it back through the seam, so this exercises
        // the real pair (host enter_task + runner's current_owner/current_provenance) and not a stand-in.
        crate::node::enter_task(TaskContext{cancel:Arc::new(AtomicBool::new(false)),deadline:None,
            sockets:SocketSlot::default(),owner:"child-fixture".into(),provenance:Provenance::Child});
        let spec=crate::operations::configure_spec(wa_operation::Spec::command("fixture",vec![]),"",1,"".into(),false,false);
        crate::node::leave_task();
        assert!(spec.env.contains(&("WASM_AGENT_IN_TURN".into(),"1".into())));
        assert!(spec.env.contains(&("WASM_AGENT_PROVENANCE".into(),"child".into())));
        assert_eq!(spec.owner,"child-fixture");
    }
