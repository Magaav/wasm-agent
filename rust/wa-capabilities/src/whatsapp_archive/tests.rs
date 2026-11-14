//! The node's half of the archive, measured against a real component namespace (SQLite kv in a temp
//! directory), the real keystore (passphrase protection, so it works on a machine with no keyring) and
//! real files.
//!
//! This is where the *seams* are the subject: that the node's kv adapter reads and deletes exactly what
//! the component wrote, that the seal is the keystore's and not a stand-in, and that a restore leaves a
//! month marked and readable. The archive's own format and operations are measured beside it, in
//! `rust/wa-whatsapp-archive`.
use super::*;
use wa_whatsapp_index::{keys, text, Searchable};

const MONTH: &str = "2026-03";
const CHAT: &str = "5511999999999@s.whatsapp.net";
const SENDER: &str = "5511888888888@s.whatsapp.net";
const PASSPHRASE: &str = "waarchive-test-passphrase";

/// A temp components directory, a temp keystore, and one month of records in the component's namespace.
struct Fixture {
    home: tempfile::TempDir,
}

impl Fixture {
    fn new() -> Fixture {
        Fixture { home: tempfile::Builder::new().prefix("waarchive-cap").tempdir().expect("a temp dir") }
    }

    fn components(&self) -> PathBuf {
        self.home.path().join("components")
    }

    fn keystore(&self) -> PathBuf {
        self.home.path().join("vault")
    }

    fn run(&self, request: Value) -> Value {
        let components = self.components();
        std::fs::create_dir_all(&components).ok();
        run_with(&components, &self.keystore(), Some(PASSPHRASE), &request)
    }

    /// One month of messages, written the way the component writes them.
    fn seed(&self, month: &str, messages: usize) {
        let kv = wa_kernel_runtime::state_host::namespace_in(&self.components(), COMPONENT);
        let (start, _) = wa_whatsapp_index::month::bounds(month).expect("a month");
        for index in 0..messages {
            let id = format!("3EB0{index:06}");
            let ts = start + 1_000 + index as i64;
            let record = format!(
                r#"{{"chat":"{CHAT}","id":"{id}","sender":"{SENDER}","ts":{ts},"kind":"text","text":"mensagem {index}","source":"live"}}"#
            );
            let body = format!("mensagem {index}");
            let contact_names: Vec<&str> = Vec::new();
            let searchable = Searchable { body: &[body.as_str()], media: None, place: None, poll: None, contacts: &contact_names };
            let facts = keys::RecordFacts {
                chat: CHAT.into(),
                id,
                sender: SENDER.into(),
                ts,
                kind: "text".into(),
                source: String::new(),
                tokens: text::tokens(&searchable.text()),
            };
            for (key, value) in facts.keys().into_iter().zip(facts.values(record.as_bytes())) {
                kv.put(key.as_bytes(), &value).expect("a seeded record key");
            }
        }
    }

    fn record_keys(&self) -> Vec<String> {
        let kv = wa_kernel_runtime::state_host::namespace_in(&self.components(), COMPONENT);
        kv.keys().unwrap_or_default().into_iter().map(|key| String::from_utf8_lossy(&key).into_owned()).collect()
    }
}

#[test]
fn the_node_cuts_a_month_out_of_the_component_namespace_into_one_sealed_file() {
    let fixture = Fixture::new();
    fixture.seed(MONTH, 4);
    assert_eq!(fixture.record_keys().len(), 4 * 6, "four messages, six keys each");

    let cut = fixture.run(json!({"action": "cut", "month": MONTH}));
    assert_eq!(cut["ok"], true, "{cut}");
    assert_eq!(cut["written"], true);
    assert_eq!(cut["messages"], 4);
    assert_eq!(cut["chats"], 1);
    // The index no longer holds the month: this is the node deleting the component's keys, through the
    // layout and the tokenizer both ends share.
    assert!(fixture.record_keys().is_empty(), "the month left the namespace: {:?}", fixture.record_keys());

    // One file, named for the month, sealed with the keystore's key.
    let path = PathBuf::from(cut["path"].as_str().unwrap());
    assert!(path.exists());
    assert_eq!(path.file_name().unwrap().to_string_lossy(), format!("whatsapp-archive-{MONTH}.waa"));
    let bytes = std::fs::read(&path).unwrap();
    assert!(!bytes.windows(8).any(|window| window == b"mensagem"), "the messages are not readable at rest");

    let listed = fixture.run(json!({"action": "list"}));
    assert_eq!(listed["ok"], true, "{listed}");
    let archives = listed["archives"].as_array().expect("a list");
    assert_eq!(archives.len(), 1);
    assert_eq!(archives[0]["month"], MONTH);
    assert_eq!(archives[0]["messages"], 4);
    assert_eq!(archives[0]["restored"], false);
    assert_eq!(archives[0]["sha256"], cut["sha256"]);
    assert!(archives[0]["expire_ms"].as_i64().unwrap() > 0);
}

#[test]
fn a_restored_month_is_readable_marked_and_unloadable() {
    let fixture = Fixture::new();
    fixture.seed(MONTH, 3);
    let cut = fixture.run(json!({"action": "cut", "month": MONTH}));
    assert_eq!(cut["written"], true, "{cut}");
    let keys_before_cut = 3 * 6;

    let restored = fixture.run(json!({"action": "restore", "month": MONTH}));
    assert_eq!(restored["ok"], true, "{restored}");
    assert_eq!(restored["messages"], 3);
    assert_eq!(restored["read_only"], true);
    // Every key is back, plus the month's mark.
    let keys = fixture.record_keys();
    assert_eq!(keys.len(), keys_before_cut + 1);
    assert!(keys.iter().any(|key| key == &format!("{}arc/{MONTH}", keys::PREFIX)));

    // The record says it is a copy, and the answer a reader gets says which month it came from.
    let kv = wa_kernel_runtime::state_host::namespace_in(&fixture.components(), COMPONENT);
    let record_key = keys
        .iter()
        .find(|key| key.starts_with(&format!("{}m/", keys::PREFIX)) && key.contains("3EB0000000"))
        .expect("the record");
    let record = String::from_utf8_lossy(&kv.get(record_key.as_bytes()).unwrap().unwrap()).into_owned();
    assert!(record.contains(r#""restored":true"#), "{record}");

    let listed = fixture.run(json!({"action": "list"}));
    assert_eq!(listed["restored"][0], MONTH, "{listed}");
    assert_eq!(listed["archives"][0]["restored"], true);

    // A restore of a month that is already loaded says so and writes nothing twice.
    let again = fixture.run(json!({"action": "restore", "month": MONTH}));
    assert_eq!(again["again"], true);
    assert_eq!(fixture.record_keys().len(), keys_before_cut + 1);

    let unloaded = fixture.run(json!({"action": "unload", "month": MONTH}));
    assert_eq!(unloaded["ok"], true, "{unloaded}");
    assert_eq!(unloaded["was_restored"], true);
    assert!(fixture.record_keys().is_empty(), "the restored rows are gone");
    // And the archive file is still here: an unload is not a delete.
    assert!(PathBuf::from(cut["path"].as_str().unwrap()).exists());
}

#[test]
fn nothing_is_cut_while_the_month_is_inside_the_window() {
    // The cut only ever takes a month that is ENTIRELY outside the window: a node that asks for a cut
    // the month after it landed gets an answer, not a month of messages moved out of reach.
    let fixture = Fixture::new();
    let now_month = wa_whatsapp_index::month::of(super::now_ms());
    fixture.seed(&now_month, 2);
    let answer = fixture.run(json!({"action": "cut"}));
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["nothing_due"], true);
    assert_eq!(answer["cut"], Value::Null);
    assert_eq!(fixture.record_keys().len(), 2 * 6, "the live month is untouched");

    // An explicit month is cut only when it is due, and a month inside the window is refused by the
    // window - not by a missing file.
    let inside = fixture.run(json!({"action": "cut", "month": now_month}));
    assert_eq!(inside["ok"], false, "{inside}");
    assert_eq!(inside["error"], "archive_month_not_due", "an in-window month is never moved out of the index");
    assert_eq!(fixture.record_keys().len(), 2 * 6, "and nothing was touched");

    // A month that IS outside the window is due, and the answer names the window it used.
    let old = "2025-01";
    fixture.seed(old, 1);
    let due = fixture.run(json!({"action": "status"}));
    assert_eq!(due["due"], old, "{due}");
    assert_eq!(due["keep_days"], super::DEFAULT_KEEP_DAYS);
}

#[test]
fn a_month_past_360_days_expires() {
    let fixture = Fixture::new();
    fixture.seed("2023-05", 2);
    let cut = fixture.run(json!({"action": "cut", "month": "2023-05"}));
    assert_eq!(cut["written"], true, "{cut}");
    let path = PathBuf::from(cut["path"].as_str().unwrap());
    assert!(path.exists());
    // The expiry clock is the message date, and 2023-05 ended more than 360 days ago.
    let expired = fixture.run(json!({"action": "expire"}));
    assert_eq!(expired["ok"], true, "{expired}");
    assert_eq!(expired["expired"], json!(["2023-05"]));
    assert!(!path.exists(), "the expired archive is gone");

    // A restored month that expires is unloaded first: a row no file can explain would otherwise be
    // kept by retention forever.
    fixture.seed("2023-06", 1);
    let cut = fixture.run(json!({"action": "cut", "month": "2023-06"}));
    assert_eq!(cut["written"], true, "{cut}");
    let restored = fixture.run(json!({"action": "restore", "month": "2023-06"}));
    assert_eq!(restored["messages"], 1, "{restored}");
    assert!(!fixture.record_keys().is_empty());
    let expired = fixture.run(json!({"action": "expire"}));
    assert_eq!(expired["expired"], json!(["2023-06"]));
    assert!(fixture.record_keys().is_empty(), "the expired month's rows went first: {:?}", fixture.record_keys());
}

#[test]
fn a_month_can_be_pushed_to_another_disk_with_its_digest_verified_on_arrival() {
    let fixture = Fixture::new();
    fixture.seed(MONTH, 2);
    let cut = fixture.run(json!({"action": "cut", "month": MONTH}));
    assert_eq!(cut["written"], true, "{cut}");
    let source = PathBuf::from(cut["path"].as_str().unwrap());
    let dest = fixture.home.path().join("other-disk");

    let pushed = fixture.run(json!({"action": "push", "month": MONTH, "to": dest.to_string_lossy()}));
    assert_eq!(pushed["ok"], true, "{pushed}");
    assert_eq!(pushed["transport"], "disk");
    assert_eq!(pushed["verified"], cut["sha256"], "the target's own digest is what verified it");
    assert_eq!(pushed["removed_local"], true);
    assert!(!source.exists(), "the local copy is gone, which is the point of the push");
    assert!(dest.join(format!("whatsapp-archive-{MONTH}.waa")).exists());

    // With `keep_local` the node keeps both, which is what a backup is.
    fixture.seed(MONTH, 1);
    fixture.run(json!({"action": "cut", "month": MONTH}));
    let kept = fixture.run(json!({"action": "push", "month": MONTH, "to": dest.to_string_lossy(), "keep_local": true}));
    assert_eq!(kept["removed_local"], false, "{kept}");
}

#[test]
fn the_receiving_node_assembles_the_chunks_and_answers_the_digest_it_computed() {
    // The node half of a push over the mesh: the sender's chunks arrive as separate calls, and only the
    // last one answers the digest of the file that was assembled on this disk. The transport itself is
    // `rust/wa-mesh` (measured in its own tests); what is measured here is that a chunked arrival
    // produces a verifiable archive and that a wrong chunk is refused.
    let sender = Fixture::new();
    sender.seed(MONTH, 3);
    let cut = sender.run(json!({"action": "cut", "month": MONTH}));
    let bytes = std::fs::read(PathBuf::from(cut["path"].as_str().unwrap())).unwrap();
    let parts = bytes.chunks(64).count();

    let receiver = Fixture::new();
    let mut digest = String::new();
    for (index, chunk) in bytes.chunks(64).enumerate() {
        let answer = receiver.run(json!({
            "action": "receive",
            "month": MONTH,
            "part": index,
            "parts": parts,
            "bytes": chunk.iter().map(|byte| format!("{byte:02x}")).collect::<String>(),
        }));
        assert_eq!(answer["ok"], true, "{answer}");
        if index + 1 == parts {
            digest = answer["sha256"].as_str().unwrap_or_default().to_string();
            assert_eq!(answer["complete"], true);
        }
    }
    assert_eq!(digest, cut["sha256"], "the receiver's digest is the sender's digest");
    let arrived = receiver.components().join("wa-whatsapp.archive").join(format!("whatsapp-archive-{MONTH}.waa"));
    assert!(arrived.exists(), "{arrived:?}");
    assert_eq!(std::fs::read(&arrived).unwrap(), bytes, "the file arrived byte for byte");

    // A chunk that arrives out of order is refused instead of being appended in the wrong place.
    let other = Fixture::new();
    let refused = other.run(json!({"action": "receive", "month": MONTH, "part": 1, "parts": 2, "bytes": "00"}));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"], "archive_push_out_of_order");
}

#[test]
fn the_answers_never_carry_a_message_or_a_key() {
    let fixture = Fixture::new();
    fixture.seed(MONTH, 2);
    let mut answers = vec![
        fixture.run(json!({"action": "status"})),
        fixture.run(json!({"action": "cut", "month": MONTH})),
        fixture.run(json!({"action": "restore", "month": MONTH})),
        fixture.run(json!({"action": "list"})),
        fixture.run(json!({"action": "unload", "month": MONTH})),
    ];
    answers.push(fixture.run(json!({"action": "nonsense"})));
    for answer in answers {
        let text = answer.to_string();
        assert!(!text.contains("mensagem"), "an answer carried message text: {text}");
        assert!(!text.contains(SENDER), "an answer carried a sender JID: {text}");
        assert!(!text.contains(CHAT), "an answer carried a chat JID: {text}");
    }
    // A refusal names the action and the reason, and nothing else.
    let unknown = fixture.run(json!({"action": "nonsense"}));
    assert_eq!(unknown["error"], "archive_action_unknown:nonsense");
    // A request that is not JSON at all is refused, not guessed at.
    let bad = fixture.run(json!({"action": "restore"}));
    assert_eq!(bad["error"], "archive_month_required");
}
