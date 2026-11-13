//! What the archive must do, measured over a real kv (in memory), a real directory and a real sealer.
//!
//! The one thing these tests deliberately do NOT use is the node's keystore: the archive's format and
//! its operations are the subject here, and the keystore's own paths are exercised where the operator's
//! key lives (`crates/wa-capabilities`, `docs/VAULT.md`). `Xor` still *is* a transform, so a test that
//! says "the file is encrypted" fails if the sealing call is skipped.
use crate::ops::{fixture, fixture_rich, Sink};
use crate::*;
use wa_whatsapp_index::keys;

const MONTH: &str = "2026-03";
/// A cut instant well after the month, so nothing here depends on when the test runs.
const NOW: i64 = 1_777_000_000_000;

fn sealer() -> Xor {
    Xor { key: 0x5a }
}

fn build() -> Build {
    Build { component_version: "0.1.0".into(), schema: "v1".into() }
}

fn temp(name: &str) -> tempfile::TempDir {
    let dir = tempfile::Builder::new().prefix(name).tempdir().expect("a temp dir");
    dir
}

// ---- the calendar ---------------------------------------------------------------------------------

#[test]
fn a_month_is_a_utc_calendar_month_with_half_open_bounds() {
    assert_eq!(month_of(0), "1970-01");
    assert_eq!(month_of(1_777_000_000_000), "2026-04");
    let (start, end) = month_bounds("2026-03").expect("a month");
    assert_eq!(month_of(start), "2026-03");
    assert_eq!(month_of(end - 1), "2026-03");
    assert_eq!(month_of(end), "2026-04");
    assert_eq!(end - start, 31 * 86_400_000, "March has 31 days");
    assert_eq!(month_bounds("2024-02").map(|(a, b)| b - a).unwrap(), 29 * 86_400_000, "a leap February");
    // A month that is not one is refused, not guessed: the month becomes a file name.
    for bad in ["2026-13", "2026-00", "26-03", "../../etc", "2026-3", ""] {
        assert!(month_bounds(bad).is_err(), "{bad:?} is not a month");
    }
}

#[test]
fn an_archive_expires_360_days_after_the_last_day_of_its_month() {
    let (_, end) = month_bounds(MONTH).unwrap();
    assert!(!expired(MONTH, end + 359 * 86_400_000), "kept until its 360th day");
    assert!(expired(MONTH, end + 360 * 86_400_000), "deleted on its 360th day");
    // The clock that decides is the message date, not the cut date.
    assert!(!expired(MONTH, end));
}

#[test]
fn the_due_month_is_the_oldest_one_entirely_outside_the_window() {
    let kv = fixture("2026-03", 2);
    let (_, march_end) = month_bounds("2026-03").unwrap();
    // A window that still contains March has nothing due.
    assert_eq!(due(&kv, march_end + 10 * 86_400_000, 180).unwrap(), None);
    // A window that starts after March 31 makes March due - and March is the oldest month the index has.
    assert_eq!(due(&kv, march_end + 181 * 86_400_000, 180).unwrap(), Some("2026-03".to_string()));
    // A node that was off for a year answers the OLDEST month, one month at a time.
    let two = fixture("2026-03", 1);
    for (key, value) in fixture("2026-01", 1).entries() {
        two.set(&key, &value).unwrap();
    }
    assert_eq!(due(&two, march_end + 400 * 86_400_000, 180).unwrap(), Some("2026-01".to_string()));
}

// ---- the file ------------------------------------------------------------------------------------

#[test]
fn the_file_is_self_describing_and_its_contents_are_not_readable() {
    let dir = temp("waarchive-format");
    let kv = fixture(MONTH, 6);
    let archived = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");
    assert!(archived.written);
    assert_eq!(archived.messages, 6);
    assert_eq!(archived.chats, 2, "two chats in the fixture");

    let bytes = std::fs::read(&archived.path).expect("the file");
    assert_eq!(&bytes[..8], MAGIC, "an archive is identifiable");

    // The manifest is readable without a key: month, counts, digest, build, schema.
    let manifest = verify_file(&archived.path).expect("a verified archive");
    assert_eq!(manifest.month, MONTH);
    assert_eq!(manifest.messages, 6);
    assert_eq!(manifest.chats, 2);
    assert_eq!(manifest.component_version, "0.1.0");
    assert_eq!(manifest.schema, "v1");
    assert_eq!(manifest.sha256, archived.sha256);
    assert_eq!(manifest.key_namespace, SEAL_NAMESPACE);
    assert!(bytes.windows(manifest.month.len()).any(|window| window == MONTH.as_bytes()), "the month is in the clear");

    // The messages are NOT: the sealed body does not carry a body word, a chat id or a sender.
    for secret in ["mensagem", "5511999999999", "3EB0", "5511888888888"] {
        assert!(
            !bytes.windows(secret.len()).any(|window| window == secret.as_bytes()),
            "{secret:?} is readable in the archive file"
        );
    }
    // And the index is empty of that month: the cut removed every key it archived.
    assert!(!kv.keys().iter().any(|key| key.starts_with(&format!("{}m/", keys::PREFIX))), "the records left the index");
    assert!(!kv.keys().iter().any(|key| key.starts_with(&format!("{}w/", keys::PREFIX))), "the tokens left the index");
    assert!(!kv.keys().iter().any(|key| key.starts_with(&format!("{}all/", keys::PREFIX))), "the age keys left the index");
    assert!(kv.is_empty(), "nothing of the month is left behind: {:?}", kv.keys());
}

#[test]
fn a_cut_is_repeatable_and_an_empty_month_writes_no_file() {
    let dir = temp("waarchive-empty");
    let kv = fixture(MONTH, 0);
    let nothing = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut of nothing");
    assert!(!nothing.written);
    assert_eq!(nothing.messages, 0);
    assert!(!dir.path().join(file_name(MONTH)).exists(), "no file for an empty month");

    // A second cut of the same month after a crash (the file exists, the keys do) replaces the file and
    // leaves exactly one archive.
    let kv = fixture(MONTH, 3);
    let first = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");
    let second = cut(&kv, &sealer(), dir.path(), MONTH, NOW + 1, &build()).expect("a second cut");
    assert!(!second.written, "the index is already cut");
    let listed = list(&kv, dir.path()).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].sha256, first.sha256);
}

#[test]
fn a_tampered_file_is_refused_and_never_restored() {
    let dir = temp("waarchive-tamper");
    let kv = fixture(MONTH, 4);
    let archived = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");

    let mut bytes = std::fs::read(&archived.path).unwrap();
    let last = bytes.len() - 1;
    bytes[last] ^= 0xff;
    std::fs::write(&archived.path, &bytes).unwrap();
    assert_eq!(verify_file(&archived.path).unwrap_err(), "archive_checksum_mismatch");
    assert_eq!(restore(&kv, &sealer(), dir.path(), MONTH, NOW).unwrap_err(), "archive_checksum_mismatch");

    // A file that is not an archive at all is named as such, not read as an empty one.
    std::fs::write(dir.path().join(file_name(MONTH)), b"WASTATE1 not an archive").unwrap();
    assert_eq!(verify_file(&dir.path().join(file_name(MONTH))).unwrap_err(), "archive_not_an_archive");
    // And `list` reports it as unverified instead of hiding it.
    let listed = list(&kv, dir.path()).unwrap();
    assert_eq!(listed.len(), 1);
    assert!(listed[0].sha256.starts_with("unverified:"), "{:?}", listed[0]);
}

#[test]
fn another_months_blob_cannot_be_opened_as_this_one() {
    // The seal's context binds a body to its month: a file whose manifest says March but whose body was
    // sealed as April opens as nothing.
    let dir = temp("waarchive-context");
    let entries = vec![(b"ix/m/x/1/y".to_vec(), b"{}".to_vec())];
    let april = seal_payload(&sealer(), "2026-04", &entries).expect("sealed as April");
    assert!(open_payload(&sealer(), "2026-03", &april).unwrap_err().contains("archive_context_mismatch"));
    assert_eq!(open_payload(&sealer(), "2026-04", &april).expect("sealed as April opens as April"), entries);
    let _ = dir;
}

// ---- restore and unload ---------------------------------------------------------------------------

#[test]
fn a_restored_month_is_back_in_the_index_marked_read_only_and_the_answers_can_say_so() {
    let dir = temp("waarchive-restore");
    let kv = fixture(MONTH, 5);
    let before: Vec<String> = kv.keys();
    let archived = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");
    assert!(kv.is_empty());

    let restored = restore(&kv, &sealer(), dir.path(), MONTH, NOW + 1).expect("a restore");
    assert_eq!(restored.messages, 5);
    assert_eq!(restored.entries, archived.entries);
    assert!(!restored.again);

    // Every key the cut took is back, with the same values (the record gains its `restored` mark, and
    // the month gains its mark - the two keys a restore adds on purpose).
    let after: Vec<String> = kv.keys().into_iter().filter(|key| !key.starts_with(&keys::archive_prefix())).collect();
    assert_eq!(after, before, "the restored index has the keys the cut removed");
    for key in after.iter().filter(|key| key.starts_with(&format!("{}m/", keys::PREFIX))) {
        let record = kv.get_str(key).expect("a record");
        assert!(record.contains(r#""restored":true"#), "a restored record says so: {record}");
        assert_eq!(record.matches("restored").count(), 1);
    }
    // The mark names the month, without a message in it.
    let mark = kv.get_str(&keys::archive_mark(MONTH)).expect("a mark");
    assert!(mark.contains(MONTH) && mark.contains(&archived.sha256));
    assert!(!mark.contains("mensagem"), "the mark carries no message text: {mark}");

    // A second restore of the same month says it is a repeat and does not duplicate anything.
    let again = restore(&kv, &sealer(), dir.path(), MONTH, NOW + 2).expect("a second restore");
    assert!(again.again);
    assert_eq!(kv.keys().len(), before.len() + 1, "the month keeps exactly one mark");
}

#[test]
fn unload_takes_the_month_out_again_and_leaves_the_archive_file_where_it_is() {
    let dir = temp("waarchive-unload");
    let kv = fixture(MONTH, 4);
    let archived = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");
    restore(&kv, &sealer(), dir.path(), MONTH, NOW + 1).expect("a restore");
    assert!(!kv.is_empty());

    let unloaded = unload(&kv, MONTH, dir.path()).expect("an unload");
    assert_eq!(unloaded.messages, 4);
    assert!(unloaded.was_restored);
    assert!(kv.is_empty(), "the restored rows are gone: {:?}", kv.keys());
    assert!(archived.path.exists(), "unload does not touch the archive file");

    // Unload works after the file has been pushed away: the rows are found in the index, not in the file.
    restore(&kv, &sealer(), dir.path(), MONTH, NOW + 2).expect("a restore");
    let elsewhere = temp("waarchive-unload-pushed");
    let push = push_to_dir(dir.path(), MONTH, elsewhere.path(), false).expect("a push");
    assert!(push.removed_local);
    assert!(!archived.path.exists());
    assert_eq!(unload(&kv, MONTH, dir.path()).expect("an unload without the file").messages, 4);
    assert!(kv.is_empty());
}

#[test]
fn list_reports_every_archive_and_which_months_are_loaded() {
    let dir = temp("waarchive-list");
    let kv = fixture("2026-01", 2);
    for (key, value) in fixture("2026-02", 3).entries() {
        kv.set(&key, &value).unwrap();
    }
    cut(&kv, &sealer(), dir.path(), "2026-01", NOW, &build()).expect("a cut");
    cut(&kv, &sealer(), dir.path(), "2026-02", NOW, &build()).expect("a second cut");
    let listed = list(&kv, dir.path()).expect("a list");
    assert_eq!(listed.iter().map(|row| row.month.as_str()).collect::<Vec<_>>(), vec!["2026-01", "2026-02"]);
    assert_eq!(listed[0].messages, 2);
    assert_eq!(listed[1].messages, 3);
    assert!(listed.iter().all(|row| !row.restored && !row.missing));
    assert_eq!(listed[0].component_version, "0.1.0");

    restore(&kv, &sealer(), dir.path(), "2026-01", NOW + 1).expect("a restore");
    let listed = list(&kv, dir.path()).expect("a list");
    assert!(listed[0].restored && !listed[0].missing);
    assert!(!listed[1].restored);

    // A month that is loaded while its file has been pushed away is still listed, with `missing`.
    let pushed = temp("waarchive-list-dest");
    push_to_dir(dir.path(), "2026-01", pushed.path(), false).expect("a push");
    let listed = list(&kv, dir.path()).expect("a list");
    assert!(listed[0].restored && listed[0].missing, "{:?}", listed[0]);
}

// ---- expiry --------------------------------------------------------------------------------------

#[test]
fn an_archive_past_360_days_is_deleted_and_its_rows_go_first() {
    let dir = temp("waarchive-expire");
    let kv = fixture("2025-01", 3);
    for (key, value) in fixture("2026-04", 2).entries() {
        kv.set(&key, &value).unwrap();
    }
    cut(&kv, &sealer(), dir.path(), "2025-01", NOW, &build()).expect("a cut");
    cut(&kv, &sealer(), dir.path(), "2026-04", NOW, &build()).expect("a second cut");
    // The old month is loaded back, so expiry has rows to remove as well as a file.
    restore(&kv, &sealer(), dir.path(), "2025-01", NOW + 1).expect("a restore");
    assert_eq!(kv.keys().len(), 3 * 6 + 1, "the restored month and its mark are in the index");

    let (_, january_end) = month_bounds("2025-01").unwrap();
    // The day before the 360th: nothing goes.
    let expired_nothing = expire(&kv, dir.path(), january_end + 359 * 86_400_000).unwrap();
    assert!(expired_nothing.is_empty());
    assert!(dir.path().join(file_name("2025-01")).exists());

    // On the 360th day the archive and its rows go, and the newer month stays.
    let expired_months = expire(&kv, dir.path(), january_end + 360 * 86_400_000).unwrap();
    assert_eq!(expired_months, vec!["2025-01".to_string()]);
    assert!(!dir.path().join(file_name("2025-01")).exists(), "the file is gone");
    assert!(kv.is_empty(), "the restored rows are gone: {:?}", kv.keys());
    assert!(dir.path().join(file_name("2026-04")).exists(), "a newer archive is untouched");
}

// ---- push ----------------------------------------------------------------------------------------

#[test]
fn a_push_to_another_disk_is_verified_on_arrival_before_the_local_copy_goes() {
    let dir = temp("waarchive-push-from");
    let dest = temp("waarchive-push-to");
    let kv = fixture(MONTH, 5);
    let archived = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");

    let receipt = push_to_dir(dir.path(), MONTH, dest.path(), false).expect("a push");
    assert_eq!(receipt.sha256, archived.sha256);
    assert_eq!(receipt.verified, archived.sha256, "the target's own digest is what verified it");
    assert!(receipt.removed_local);
    assert!(!archived.path.exists(), "the local copy is gone once the target holds it");
    // What arrived is the same file: the target can verify it without the key.
    let arrived = verify_file(&dest.path().join(file_name(MONTH))).expect("a verified copy");
    assert_eq!(arrived.sha256, archived.sha256);

    // A source file that is not what its manifest says is refused BEFORE anything is copied, and the
    // local file stays: a push verifies what it sends as well as what arrives.
    let kv = fixture(MONTH, 2);
    let archived = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");
    let mut broken_bytes = std::fs::read(&archived.path).unwrap();
    let last = broken_bytes.len() - 1;
    broken_bytes[last] ^= 0xff;
    std::fs::write(&archived.path, &broken_bytes).unwrap();
    let fresh = temp("waarchive-push-fresh");
    let refused = push_to_dir(dir.path(), MONTH, fresh.path(), false);
    assert_eq!(refused.unwrap_err(), "archive_checksum_mismatch");
    assert!(!fresh.path().join(file_name(MONTH)).exists(), "nothing was written to the target");
    assert!(archived.path.exists(), "and the (corrupt) local archive is still here to be looked at");
}

#[test]
fn a_push_to_another_node_travels_in_chunks_and_only_a_matching_digest_frees_the_disk() {
    let dir = temp("waarchive-push-node");
    let kv = fixture_rich(MONTH, 200, 4096);
    let archived = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");
    assert!(archived.bytes > PUSH_CHUNK as u64, "the fixture is more than one chunk: {} bytes", archived.bytes);

    // The target is a real `Sink`: the same code the receiving node runs, over a real directory.
    let remote = temp("waarchive-push-node-remote");
    let mut sink = Sink::new(remote.path(), MONTH).expect("a sink");
    let mut calls: Vec<(u32, u32, usize)> = Vec::new();
    let receipt = push_to_node(dir.path(), MONTH, "nextcloud", false, &mut |month, part, parts, bytes| {
        calls.push((part, parts, bytes.len()));
        sink.accept(part, parts, bytes)
    })
    .expect("a push");
    assert_eq!(receipt.verified, archived.sha256);
    assert_eq!(receipt.to, "nextcloud");
    assert!(receipt.removed_local);
    assert!(calls.len() >= 2, "the file travelled in {} chunks", calls.len());
    assert!(calls.iter().all(|(_, parts, len)| *parts == calls.len() as u32 && *len <= PUSH_CHUNK));
    assert_eq!(calls.iter().map(|(_, _, len)| len).sum::<usize>() as u64, receipt.bytes);
    // The target holds a verifiable archive, and the local copy is gone.
    let arrived = verify_file(&remote.path().join(file_name(MONTH))).expect("the target's copy");
    assert_eq!(arrived.sha256, archived.sha256);
    assert!(!archived.path.exists());

    // A target that answers a different digest is a failed push, and the local file stays.
    let kv = fixture(MONTH, 3);
    let archived = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");
    let refused = push_to_node(dir.path(), MONTH, "nextcloud", false, &mut |_month, _part, _parts, _bytes| {
        Ok("0".repeat(64))
    });
    assert_eq!(refused.unwrap_err(), "archive_push_unverified");
    assert!(archived.path.exists(), "an unverified push does not delete anything");
}

#[test]
fn a_sink_refuses_chunks_out_of_order_and_a_month_that_does_not_match() {
    let dir = temp("waarchive-sink");
    let sink = Sink::new(dir.path(), MONTH).expect("a sink");
    // A chunk that is not the one expected now is refused (nothing has arrived, so that is chunk 0).
    assert_eq!(sink.accept(1, 2, b"second").unwrap_err(), "archive_push_out_of_order");
    // Once a part of a two-part push is in, a call that says the file is three parts is a different
    // push, and the progress on disk is not silently relabelled.
    assert_eq!(sink.accept(0, 2, b"first").unwrap(), "", "the first of two is accepted and answers nothing");
    assert_eq!(sink.accept(1, 3, b"second").unwrap_err(), "archive_push_out_of_order");

    // A whole file that verifies but belongs to another month is refused, not filed under this one.
    let other = temp("waarchive-sink-other");
    let kv = fixture("2026-05", 1);
    let archived = cut(&kv, &sealer(), other.path(), "2026-05", NOW, &build()).expect("a cut");
    let bytes = std::fs::read(&archived.path).unwrap();
    let mut sink = Sink::new(dir.path(), MONTH).expect("a sink");
    assert_eq!(sink.accept(0, 1, &bytes).unwrap_err(), "archive_month_mismatch");
    assert!(!dir.path().join(file_name(MONTH)).exists());
    assert!(!dir.path().join(format!("{}.incoming", file_name(MONTH))).exists(), "a refused push leaves no partial file");
}

// ---- the facts a restore needs --------------------------------------------------------------------

#[test]
fn the_keys_and_tokens_written_back_are_the_ones_the_component_wrote() {
    // One message with an accent, a media filename and an emoji caption: the token keys this archive
    // writes on the way back must be the ones the fold produces, not a subset of them.
    let dir = temp("waarchive-facts");
    let kv = Memory::new();
    let chat = "5511999999999@s.whatsapp.net";
    let id = "3EB0ACAO";
    let ts = month_bounds(MONTH).unwrap().0 + 1_000;
    let record = format!(
        r#"{{"chat":"{chat}","id":"{id}","sender":"5511888888888@s.whatsapp.net","ts":{ts},"kind":"image","text":"Ação 🤖","source":"history","media":{{"filename":"Relatório.pdf","mime":"application/pdf"}}}}"#
    );
    let facts = facts_of(chat, id, ts, record.as_bytes());
    assert!(facts.tokens.iter().any(|token| token == "acao"), "{:?}", facts.tokens);
    assert!(facts.tokens.iter().any(|token| token == "relatorio"), "{:?}", facts.tokens);
    assert!(facts.tokens.iter().any(|token| token == "🤖"));
    for (key, value) in facts.keys().into_iter().zip(facts.values(record.as_bytes())) {
        kv.set(key.as_bytes(), &value).unwrap();
    }
    let archived = cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");
    assert_eq!(archived.entries, facts.keys().len() as u64, "one message is its record key set");
    restore(&kv, &sealer(), dir.path(), MONTH, NOW + 1).expect("a restore");
    // The restored month is searchable by the same word: the token key is back where the fold puts it.
    let token_key = format!("{}w/acao/", keys::PREFIX);
    assert!(kv.keys().iter().any(|key| key.starts_with(&token_key)), "{:?}", kv.keys());
    assert!(kv.keys().iter().any(|key| key.contains("relatorio")));
}

#[test]
fn a_reaction_on_an_archived_message_travels_with_it() {
    let dir = temp("waarchive-reactions");
    let kv = fixture(MONTH, 1);
    let chat = "5511999999999@s.whatsapp.net";
    let id = "3EB0000000";
    let ts = month_bounds(MONTH).unwrap().0 + 60_000;
    let row = keys::reaction(chat, id, "5511888888888@s.whatsapp.net", "👍");
    kv.set(row.as_bytes(), "{\"reactor\":\"5511888888888@s.whatsapp.net\",\"emoji\":\"👍\"}".as_bytes()).unwrap();
    assert!(kv.keys().iter().any(|key| key == &row));

    cut(&kv, &sealer(), dir.path(), MONTH, NOW, &build()).expect("a cut");
    assert!(!kv.keys().iter().any(|key| key == &row), "the reaction row left the index with its target");
    restore(&kv, &sealer(), dir.path(), MONTH, NOW + 1).expect("a restore");
    assert!(kv.keys().iter().any(|key| key == &row), "and it came back with it");
    assert!(kv.get_str(&row).unwrap().contains("👍"));
    let _ = ts;
}
