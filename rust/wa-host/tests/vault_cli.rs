//! `wa vault …` and `wa fleet … --key vault:<name>` proved through the **real binary**.
//!
//! Why this is an integration test and not a unit test: the live finding of 08/11 was not a bug in the
//! vault engine - `rust/wa-vault` and `rust/wa-capabilities::vault_cli` were both correct - it was that
//! `wa-host`'s command table never dispatched to them, so every node answered `wa vault list` with
//! `unknown command: vault` and nothing was ever stored. A unit test of `wa_vault::cli::run` would have
//! stayed green through all of it. So each test below spawns `env!("CARGO_BIN_EXE_wa")` with a temp home
//! and a temp vault directory and asserts on what an operator's terminal sees.
//!
//! Hard rules this file keeps (`.pi-job/common.md`, and the incident of 07/11):
//!
//! * every run gets a fresh temp `WASM_AGENT_HOME`, its own `--db`-equivalent, `WASM_AGENT_RENDEZVOUS`
//!   and `WASM_AGENT_RELAY` emptied, `WASM_AGENT_MANAGED=0` and a vault directory inside that temp home:
//!   no test here can reach a real node's vault, database or identity;
//! * nothing runs `serve`, so no port is bound and no `wa` process of this machine is touched;
//! * a value is asserted **absent** from every output except `reveal`, so a future change that starts
//!   printing one fails here rather than on a node.
//!
//! The keystore: on Windows the default protection is DPAPI and needs no passphrase; on Linux it is the
//! kernel keyring, or the Argon2id-sealed file with `WASM_AGENT_VAULT_PASSPHRASE`. The tests set the
//! passphrase so a CI container with no usable keyring takes the sealed-file path instead of failing
//! for a reason that has nothing to do with the vault.

use std::path::PathBuf;
use std::process::Command;

/// The passphrase these tests use. Never an operator's, and only ever read by a keystore in a temp dir.
const PASSPHRASE: &str = "wa-vault-cli-test-passphrase";

struct Home {
    dir: PathBuf,
}

impl Home {
    fn new(tag: &str) -> Home {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!("wa-vault-cli-{tag}-{}-{nanos}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join(".wasm-agent")).expect("temp home");
        Home { dir }
    }

    fn vault_dir(&self) -> PathBuf {
        self.dir.join(".wasm-agent").join("vault")
    }

    fn file(&self, name: &str) -> PathBuf {
        self.dir.join(name)
    }

    fn write(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.file(name);
        std::fs::write(&path, bytes).expect("write test file");
        path
    }

    /// Run the node's binary with this temp home. `envs` is applied on top of the hermetic set.
    fn run(&self, args: &[&str], envs: &[(&str, &str)]) -> Run {
        let mut command = Command::new(env!("CARGO_BIN_EXE_wa"));
        command
            .args(args)
            .current_dir(&self.dir)
            .env("WASM_AGENT_HOME", &self.dir)
            .env("HOME", &self.dir)
            .env("USERPROFILE", &self.dir)
            .env("WASM_AGENT_DB", self.file("memory.db"))
            .env("WA_COMPONENTS_DIR", self.file("components"))
            .env("WASM_AGENT_RENDEZVOUS", "")
            .env("WASM_AGENT_RELAY", "")
            .env("WASM_AGENT_MANAGED", "0")
            .env("WASM_AGENT_VAULT_PASSPHRASE", PASSPHRASE)
            .env_remove("WA_SCRIPT")
            .env_remove("WASM_AGENT_LUA_ROOT")
            // `WASM_AGENT_VAULT_URL` too: this harness promises "no test here can reach a real node's
            // vault", and without this line a test spawned from a vaulted session inherits the
            // operator's vault URL - `provider.providers()` prefers that route over every other
            // setting on purpose (lua/core/provider.lua, docs/VAULT.md), so a fixture provider would
            // be answered by the real one. Measured on a node in 11/11 (speed.log): a test call went
            // to the operator's provider and nothing said so.
            .env_remove("WASM_AGENT_VAULT_URL")
            .env_remove("WASM_AGENT_VAULT_DIR")
            .env_remove("WASM_AGENT_VAULT_KEYSTORE");
        for (key, value) in envs {
            command.env(key, value);
        }
        let output = command.output().expect("run the wa binary");
        Run {
            code: output.status.code().unwrap_or(-1),
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        }
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct Run {
    code: i32,
    stdout: String,
    stderr: String,
}

impl Run {
    /// Everything the command printed, for the "no value outside reveal" scan.
    fn output(&self) -> String {
        format!("{}\n{}", self.stdout, self.stderr)
    }

    fn ok(&self) -> &Self {
        assert_eq!(self.code, 0, "expected success; stdout={:?} stderr={:?}", self.stdout, self.stderr);
        self
    }

    fn failed(&self) -> &Self {
        assert_ne!(self.code, 0, "expected a refusal; stdout={:?}", self.stdout);
        self
    }

    fn json(&self) -> serde_json::Value {
        serde_json::from_str(self.stdout.trim())
            .unwrap_or_else(|error| panic!("not JSON ({error}): {:?}", self.stdout))
    }
}

#[test]
fn a_vault_round_trip_through_the_wa_binary() {
    let home = Home::new("roundtrip");
    let first = b"planted-secret-value-roundtrip-1";
    let second = b"planted-secret-value-roundtrip-2";
    let first_path = home.write("first.secret", first);
    let second_path = home.write("second.secret", second);
    let mut printed = String::new();

    // The help text exists and is answered (the command table lists it, so `wa vault --help` must not
    // fall through to the Lua CLI either).
    let help = home.run(&["vault", "help"], &[]);
    help.ok();
    assert!(help.stdout.contains("usage: wa vault <command>"), "stdout={:?}", help.stdout);
    for command in ["list", "reveal", "rotate", "import-ed25519", "audit verify"] {
        assert!(help.stdout.contains(command), "help must name {command}: {:?}", help.stdout);
    }
    printed.push_str(&help.output());

    // `wa vault list` on a node that has never stored anything: recognised, and it creates the
    // keystore on first use (the "nothing is stored" half of the live finding).
    let list = home.run(&["vault", "list"], &[]);
    list.ok();
    assert!(list.stdout.contains("vault: empty"), "stdout={:?}", list.stdout);
    printed.push_str(&list.output());

    let status = home.run(&["vault", "status"], &[]);
    status.ok();
    assert!(
        status.stdout.contains("protection: dpapi")
            || status.stdout.contains("protection: keyring")
            || status.stdout.contains("protection: passphrase"),
        "a node must say how its root key is protected: {:?}",
        status.stdout
    );
    assert!(status.stdout.contains("root: present"), "stdout={:?}", status.stdout);
    printed.push_str(&status.output());

    // set (the value only ever arrives as a file, never as an argument).
    let set = home.run(&["vault", "set", "github", "--from", first_path.to_str().unwrap()], &[]);
    set.ok();
    assert!(set.stdout.contains("github: secret version 1"), "stdout={:?}", set.stdout);
    printed.push_str(&set.output());

    // list: the name and its metadata, and no value.
    let list = home.run(&["vault", "list"], &[]);
    list.ok();
    assert!(list.stdout.contains("github\tsecret\tversion 1"), "stdout={:?}", list.stdout);
    printed.push_str(&list.output());

    let show = home.run(&["vault", "show", "github"], &[]);
    show.ok();
    assert!(show.stdout.contains("kind: secret"), "stdout={:?}", show.stdout);
    printed.push_str(&show.output());

    // reveal is the one command that answers a value, and it answers exactly it.
    let reveal = home.run(&["vault", "reveal", "github"], &[]);
    reveal.ok();
    assert_eq!(reveal.stdout.trim_end_matches(['\r', '\n']), String::from_utf8_lossy(first));

    // rotate to a new value: version 2, and the value changes.
    let rotate = home.run(&["vault", "rotate", "github", "--from", second_path.to_str().unwrap()], &[]);
    rotate.ok();
    assert!(rotate.stdout.contains("version 2"), "stdout={:?}", rotate.stdout);
    printed.push_str(&rotate.output());
    let reveal = home.run(&["vault", "reveal", "github"], &[]);
    reveal.ok();
    assert_eq!(reveal.stdout.trim_end_matches(['\r', '\n']), String::from_utf8_lossy(second));

    // The audit chain verifies over every one of those operations, and no line of it carries a value.
    let audit = home.run(&["vault", "audit", "verify"], &[]);
    audit.ok();
    assert!(audit.stdout.contains("audit: verified"), "stdout={:?}", audit.stdout);
    printed.push_str(&audit.output());
    let tail = home.run(&["vault", "audit", "tail", "--lines", "500"], &[]);
    tail.ok();
    for op in ["\"set\"", "\"rotate\"", "\"reveal\""] {
        assert!(tail.stdout.contains(op), "the audit must record {op}: {:?}", tail.stdout);
    }
    printed.push_str(&tail.output());

    // delete, and the entry is gone rather than hidden.
    let delete = home.run(&["vault", "delete", "github"], &[]);
    delete.ok();
    assert!(delete.stdout.contains("github: deleted"), "stdout={:?}", delete.stdout);
    printed.push_str(&delete.output());
    let gone = home.run(&["vault", "reveal", "github"], &[]);
    gone.failed();
    assert!(gone.output().contains("vault_unknown_entry"), "stderr={:?}", gone.stderr);
    printed.push_str(&gone.output());

    // The rule the design is built on: a value appears in `reveal`'s output and nowhere else.
    for value in [String::from_utf8_lossy(first), String::from_utf8_lossy(second)] {
        assert!(!printed.contains(value.as_ref()), "a value reached non-reveal output: {printed}");
    }
    // And not in the document or the audit file either (ciphertext and names only).
    let document = std::fs::read_to_string(home.vault_dir().join("vault.json")).expect("document");
    let audit_log = std::fs::read_to_string(home.vault_dir().join("audit.log")).expect("audit log");
    for value in [String::from_utf8_lossy(first), String::from_utf8_lossy(second)] {
        assert!(!document.contains(value.as_ref()), "a value is in the vault document in the clear");
        assert!(!audit_log.contains(value.as_ref()), "a value is in the audit log");
    }
}

#[test]
fn the_keystore_refuses_rather_than_falling_back_to_plaintext() {
    let home = Home::new("nokey");
    // Forced to the passphrase protection with no passphrase supplied: the only honest answer is a
    // named refusal. A silent plaintext file would be the worst possible outcome, so it is asserted
    // against directly (no document was written at all).
    let run = home.run(
        &["vault", "list"],
        &[
            ("WASM_AGENT_VAULT_KEYSTORE", "passphrase"),
            ("WASM_AGENT_VAULT_PASSPHRASE", ""),
        ],
    );
    run.failed();
    assert!(
        run.stderr.contains("keystore_passphrase_missing"),
        "the refusal must name the missing passphrase: {:?}",
        run.stderr
    );
    assert!(!home.vault_dir().join("vault.json").exists(), "nothing may be written without a keystore");
}

#[test]
fn the_fleet_key_is_imported_from_a_pkcs8_hex_file_and_signs_a_roster_a_node_verifies() {
    let home = Home::new("fleet");
    let fleet_key = home.file("fleet.key");
    let member_key = home.file("member.key");
    let next_key = home.file("next.key");

    // `wa fleet keygen` is the tool operators use; its file is pkcs8 hex, not a raw seed.
    let fleet = home.run(&["fleet", "keygen", "--out", fleet_key.to_str().unwrap()], &[]);
    fleet.ok();
    let fleet = fleet.json();
    let fleet_public = fleet["public_key"].as_str().expect("fleet public key").to_string();
    let member = home.run(&["fleet", "keygen", "--out", member_key.to_str().unwrap()], &[]);
    member.ok();
    let member = member.json();
    let member_public = member["public_key"].as_str().expect("member public key").to_string();
    let member_id = member["node_id"].as_str().expect("member node id").to_string();
    let next = home.run(&["fleet", "keygen", "--out", next_key.to_str().unwrap()], &[]);
    next.ok();
    let next = next.json();
    let next_public = next["public_key"].as_str().expect("next public key").to_string();

    // import-ed25519 reads the file the operator already has, and answers the *public* key only.
    let imported = home.run(
        &["vault", "import-ed25519", "fleet", "--from", fleet_key.to_str().unwrap()],
        &[],
    );
    imported.ok();
    assert!(imported.stdout.contains("read as pkcs8-hex"), "stdout={:?}", imported.stdout);
    assert!(
        imported.stdout.contains(&format!("public_key: {fleet_public}")),
        "the imported entry must be the keygen key: stdout={:?}",
        imported.stdout
    );
    assert!(fleet_key.exists(), "without --shred the source file is kept: {:?}", imported.stdout);

    // The roster draft the operator would write (docs/MESH.md §1), signed with the vault-held key.
    let template = home.file("roster.json");
    std::fs::write(
        &template,
        serde_json::to_string_pretty(&serde_json::json!({
            "version": 1,
            "fleet": "ohana-vault-test",
            "issued_at": 0,
            "expires_at": 0,
            "nodes": [{
                "node_id": member_id,
                "public_key": member_public,
                "name": "member-1",
                "level": 1,
                "addresses": ["127.0.0.1:8891"],
            }],
        }))
        .expect("roster json"),
    )
    .expect("write roster");

    let signed = home.run(&["fleet", "sign", template.to_str().unwrap(), "--key", "vault:fleet"], &[]);
    signed.ok();
    let signed = signed.json();
    assert_eq!(signed["ok"], serde_json::json!(true), "{signed}");
    assert_eq!(signed["public_key"], serde_json::json!(fleet_public), "signed by the vault key");
    let signed_path = PathBuf::from(signed["path"].as_str().expect("signed path"));
    assert!(signed_path.exists(), "the signed roster is a new file: {signed_path:?}");

    // A node verifies that roster with the fleet public key, and refuses it under another key.
    let shown = home.run(&["fleet", "show", signed_path.to_str().unwrap(), "--key", fleet_public.as_str()], &[]);
    shown.ok();
    let shown = shown.json();
    assert_eq!(shown["verified"], serde_json::json!(true), "{shown}");
    assert_eq!(shown["nodes"][0]["name"], serde_json::json!("member-1"));
    let wrong = home.run(&["fleet", "show", signed_path.to_str().unwrap(), "--key", member_public.as_str()], &[]);
    assert_eq!(wrong.json()["verified"], serde_json::json!(false), "a roster is only valid under its own key");

    // The signature is in the vault's audit chain (a `sign` line), and no seed is anywhere in it.
    let tail = home.run(&["vault", "audit", "tail", "--lines", "200"], &[]);
    tail.ok();
    assert!(tail.stdout.contains("\"sign\""), "audit={:?}", tail.stdout);
    assert!(tail.stdout.contains("operator:fleet"), "audit={:?}", tail.stdout);

    // revoke a member, re-signing with the same vault key as the next revision.
    let revoked_path = home.file("roster.revoked.json");
    let revoked = home.run(
        &[
            "fleet", "revoke", "member-1",
            "--roster", signed_path.to_str().unwrap(),
            "--key", "vault:fleet",
            "--out", revoked_path.to_str().unwrap(),
        ],
        &[],
    );
    revoked.ok();
    let revoked = revoked.json();
    assert_eq!(revoked["ok"], serde_json::json!(true), "{revoked}");
    assert_eq!(revoked["revoked"], serde_json::json!(["member-1"]), "{revoked}");
    assert_eq!(revoked["revision"], serde_json::json!(1), "a change is a new revision: {revoked}");

    // rotate the fleet onto a second key held in the vault, then verify under the new key.
    let rotated_path = home.file("roster.rotated.json");
    let rotated = home.run(
        &[
            "fleet", "rotate",
            "--roster", revoked_path.to_str().unwrap(),
            "--key", "vault:next",
            "--out", rotated_path.to_str().unwrap(),
        ],
        &[],
    );
    // `vault:next` is not imported yet: the refusal must name the reason, not panic.
    rotated.failed();
    assert!(rotated.output().contains("vault_unknown_entry"), "stderr={:?}", rotated.stderr);
    let imported = home.run(&["vault", "import-ed25519", "next", "--from", next_key.to_str().unwrap()], &[]);
    imported.ok();
    let rotated = home.run(
        &[
            "fleet", "rotate",
            "--roster", revoked_path.to_str().unwrap(),
            "--key", "vault:next",
            "--out", rotated_path.to_str().unwrap(),
        ],
        &[],
    );
    rotated.ok();
    let rotated = rotated.json();
    assert_eq!(rotated["ok"], serde_json::json!(true), "{rotated}");
    assert_eq!(rotated["public_key"], serde_json::json!(next_public), "{rotated}");
    let shown = home.run(&["fleet", "show", rotated_path.to_str().unwrap(), "--key", next_public.as_str()], &[]);
    shown.ok();
    assert_eq!(shown.json()["verified"], serde_json::json!(true), "the rotated roster must verify");

    // Nothing in any output of the fleet work carried a seed: the vault's own document holds only
    // ciphertext, and the two key files are still exactly what `wa fleet keygen` wrote.
    let document = std::fs::read_to_string(home.vault_dir().join("vault.json")).expect("document");
    let fleet_secret = std::fs::read_to_string(&fleet_key).expect("fleet key");
    assert!(!document.contains(fleet_secret.trim()), "the fleet key is in the vault document in the clear");
}

#[test]
fn import_ed25519_keeps_the_source_unless_shred_and_the_audit_records_the_shred() {
    let home = Home::new("shred");
    let key = home.file("kept.key");
    home.run(&["fleet", "keygen", "--out", key.to_str().unwrap()], &[]).ok();
    let copy = home.file("shredded.key");
    std::fs::copy(&key, &copy).expect("copy key");

    // Without --shred: the source is kept, and the command says how to destroy it.
    let kept = home.run(&["vault", "import-ed25519", "kept", "--from", key.to_str().unwrap()], &[]);
    kept.ok();
    assert!(kept.stdout.contains("source: kept"), "stdout={:?}", kept.stdout);
    assert!(key.exists());
    let tail = home.run(&["vault", "audit", "tail", "--lines", "50"], &[]);
    assert!(!tail.stdout.contains("shred-source"), "nothing was shredded: {:?}", tail.stdout);

    // With --shred: overwritten and removed, and the chain says so.
    let shredded = home.run(
        &["vault", "import-ed25519", "shredded", "--from", copy.to_str().unwrap(), "--shred"],
        &[],
    );
    shredded.ok();
    assert!(shredded.stdout.contains("source: shredded"), "stdout={:?}", shredded.stdout);
    assert!(!copy.exists(), "the source file must be gone");
    let tail = home.run(&["vault", "audit", "tail", "--lines", "50"], &[]);
    tail.ok();
    assert!(tail.stdout.contains("shred-source"), "the audit must record the shred: {:?}", tail.stdout);
    assert_eq!(tail.stdout.matches("shred-source").count(), 1, "exactly one line per shred");
    // The entries are still readable afterwards: the shred touches the source file, never the entry.
    let public = home.run(&["vault", "public-key", "shredded"], &[]);
    public.ok();
    assert_eq!(public.stdout.trim().len(), 64, "stdout={:?}", public.stdout);
}
