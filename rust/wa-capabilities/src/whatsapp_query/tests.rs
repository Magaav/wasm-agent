//! The query capabilities, measured against a queue of their own: what a tool call enqueues, what it
//! answers, and what it refuses before anything is written.
//!
//! Nothing here touches WhatsApp or the component: the "component" is a `done` written by hand, which
//! is exactly the seam the real one settles through (`rust/components/wa-whatsapp`, `query_tick`).
use super::*;
use std::path::PathBuf;
use wa_queue::{EnqueueRequest, Policy};

/// The build that answers in these tests. The dedupe key is scoped to it
/// (`seam::Verified::dedupe_key_in`), so a test can change it and watch a new job appear - which is
/// the whole point of the scope.
const BUILD: &str = "0bf8762a-live-build";

fn temp_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("wa-query-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// How many files the download directory holds (the test's own count, so the bound is measured).
fn file_count(dir: &std::path::Path) -> usize {
    std::fs::read_dir(dir).map(|entries| entries.flatten().filter(|entry| entry.path().is_file()).count()).unwrap_or(0)
}

fn host(tag: &str) -> wa_kernel_runtime::queue_host::QueueHost {
    wa_kernel_runtime::queue_host::QueueHost::new(temp_dir(tag))
}

/// A queue with the library's defaults and no freshness bound of its own (the producer asks for one),
/// over a directory of its own so a test never touches the node's component kv.
/// Whether a `whatsapp-index` component is installed here. Every test below drives the real query path,
/// and that path now asks the component what a request means (`crate::whatsapp_index_component`): without
/// one there is nothing to test, and a test that invented a validation would be testing a second copy of a
/// rule that moved out of the host. So the test says it skipped, and the same behaviour is measured with the
/// component installed by `scripts/test-whatsapp-index.lua` (360 checks) on every run.
fn component_installed() -> bool {
    crate::whatsapp_index_component::constant("queue").is_string()
}

fn skip_without_component(test: &str) -> bool {
    if component_installed() {
        return false;
    }
    eprintln!("skip {test}: this node runs no whatsapp-index component (scripts/test-whatsapp-index.lua covers it)");
    true
}

fn queue(tag: &str) -> (wa_kernel_runtime::queue_host::QueueHost, wa_queue::Queue) {
    let host = host(tag);
    host.register(COMPONENT, &serde_json::json!({"capabilities": {"queue": {"consume": ["whatsapp.query"]}}}))
        .expect("the component's own grant");
    let queue = host.queue(COMPONENT);
    assert_eq!(queue.policy().max_ready, Policy::default().max_ready);
    (host, queue)
}

#[test]
fn a_search_enqueues_one_job_and_the_same_question_reads_it_again() {
    let (_host, queue) = queue("search");
    if skip_without_component("a_search_enqueues_one_job_and_the_same_question_reads_it_again") { return; }
    let args = serde_json::json!({"q": "boleto", "chat": "5511999999999@lid", "limit": 5});
    // Nothing has answered yet: the answer says "still running" with the id, and says it is retryable.
    let slow = ask_in(&queue, seam::Op::Search, &args, 1, BUILD);
    assert_eq!(slow["ok"], false);
    assert_eq!(slow["error"], "whatsapp_search_slow");
    assert_eq!(slow["retry"], true);
    let id = slow["id"].as_u64().expect("the job id");
    // The payload is the request the component validates, and it names what was asked for.
    let job = queue.job(wa_queue::JobId(id)).unwrap().unwrap();
    assert_eq!(job.queue, seam::queue());
    let request = wa_whatsapp_index::Request::decode(&job.payload).unwrap();
    let verified = request.validate().unwrap();
    assert_eq!((verified.op, verified.q.as_deref(), verified.limit), (wa_whatsapp_index::Op::Search, Some("boleto"), 5u32));
    // The same question is the same job: asking again does not queue a second scan.
    let again = ask_in(&queue, seam::Op::Search, &args, 1, BUILD);
    assert_eq!(again["id"].as_u64(), Some(id));
}

#[test]
fn the_answer_the_component_settled_is_the_tool_answer() {
    let (_host, queue) = queue("settled");
    if skip_without_component("the_answer_the_component_settled_is_the_tool_answer") { return; }
    let args = serde_json::json!({"chat": "5511999999999@lid", "limit": 3});
    let slow = ask_in(&queue, seam::Op::Read, &args, 1, BUILD);
    assert_eq!(slow["error"], "whatsapp_read_slow");
    // The component's side: take the job, answer it, settle.
    let wa_queue::TakeOutcome::Job(taken) = queue.take(seam::queue(), "wa-whatsapp", None).unwrap() else {
        panic!("the job must be takeable");
    };
    let answer = seam::answer(
        seam::Op::Read,
        serde_json::json!({"chat": "5511999999999@lid", "messages": [{"id": "3EB01", "text": "oi"}], "count": 1}),
    );
    queue.done_by(taken.id, "wa-whatsapp", &serde_json::to_vec(&answer).unwrap()).unwrap();
    // The answer the component settled is the tool's answer (decoded from the job record: a settled
    // job is never replayed to a later caller).
    let settled = queue.job(taken.id).expect("job").expect("the record");
    let answer = super::settled_answer(seam::Op::Read, &settled);
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["op"], "read");
    assert_eq!(answer["messages"][0]["id"], "3EB01");
}

/// The read contract of 23/11, at the tool: a read answers the index as it is NOW. A read that has
/// already settled must never be handed to the next caller, because the picture in it is a picture of
/// the past - the account node measured three reads of one chat in a row answering 15:40, 16:15 and
/// 15:44, with nothing saying any of them was old.
#[test]
fn a_settled_read_is_not_replayed_to_the_next_caller() {
    let (_host, queue) = queue("no-replay");
    if skip_without_component("a_settled_read_is_not_replayed_to_the_next_caller") { return; }
    let args = serde_json::json!({"chat": "5511999999999@lid", "limit": 3});
    let first = ask_in(&queue, seam::Op::Read, &args, 1, BUILD);
    assert_eq!(first["error"], "whatsapp_read_slow");
    let id = first["id"].as_u64().expect("the job id");
    let wa_queue::TakeOutcome::Job(taken) = queue.take(seam::queue(), "wa-whatsapp", None).unwrap() else {
        panic!("the job must be takeable");
    };
    assert_eq!(taken.id.0, id);
    let answer = seam::answer(seam::Op::Read, serde_json::json!({"chat": "5511999999999@lid", "messages": [{"id": "3EB01"}], "count": 1}));
    queue.done_by(taken.id, "wa-whatsapp", &serde_json::to_vec(&answer).unwrap()).unwrap();
    // Asking again after the first answer settled asks the index again: it is a DIFFERENT job, so it
    // cannot carry the picture the first one took.
    let again = ask_in(&queue, seam::Op::Read, &args, 1, BUILD);
    let second = again["id"].as_u64().expect("the second job id");
    assert_ne!(second, id, "a settled read must not answer the next read");
}

#[test]
fn a_dead_job_answers_with_its_reason_and_not_with_a_success() {
    let (_host, queue) = queue("dead");
    if skip_without_component("a_dead_job_answers_with_its_reason_and_not_with_a_success") { return; }
    let request = wa_whatsapp_index::Request { op: "media".into(), chat: Some("5511999999999@lid".into()), id: Some("3EB01".into()), ..Default::default() };
    let verified = request.validate().unwrap();
    // One attempt only, so a failure is final and the tool's answer is the refusal.
    queue
        .enqueue(EnqueueRequest::new(seam::queue(), verified.to_request().encode()).fresh_for(seam::fresh_ms()).max_attempts(1).dedupe(verified.dedupe_key_in(BUILD)))
        .unwrap();
    let wa_queue::TakeOutcome::Job(taken) = queue.take(seam::queue(), "wa-whatsapp", None).unwrap() else {
        panic!("the job must be takeable");
    };
    queue.fail_by(taken.id, "wa-whatsapp", "permanent:not_indexed").unwrap();
    let answer = ask_in(&queue, seam::Op::Media, &serde_json::json!({"chat": "5511999999999@lid", "id": "3EB01"}), 1, BUILD);
    assert_eq!(answer["ok"], false);
    // A refusal the caller can act on keeps its own code, and the tool names it: `not_indexed` is not a
    // slow query and not a generic failure (13/11: `contacts` answered `_failed state=dead` here).
    assert_eq!(answer["error"], "whatsapp_media_not_indexed", "{answer}");
    assert_eq!(answer["state"], "dead");
    assert!(answer["detail"].as_str().unwrap().contains("not_indexed"), "{answer}");
}

#[test]
fn a_backfill_takes_count_as_its_limit_and_needs_no_chat() {
    let (_host, queue) = queue("backfill");
    if skip_without_component("a_backfill_takes_count_as_its_limit_and_needs_no_chat") { return; }
    // No chat, an explicit count: one job, and the count travels as the wire's one count field.
    let args = serde_json::json!({"count": 120});
    let slow = ask_in(&queue, seam::Op::Backfill, &args, 1, BUILD);
    assert_eq!(slow["error"], "whatsapp_backfill_slow");
    assert_eq!(slow["retry"], true);
    let id = slow["id"].as_u64().expect("the job id");
    let job = queue.job(wa_queue::JobId(id)).unwrap().unwrap();
    assert_eq!(job.queue, seam::queue());
    let verified = wa_whatsapp_index::Request::decode(&job.payload).unwrap().validate().unwrap();
    assert_eq!((verified.op, verified.chat.is_none(), verified.limit), (wa_whatsapp_index::Op::Backfill, true, 120u32));

    // The default, the `limit`/`count` aliasing and the cap are the CONTRACT's, and they are measured where
    // the rule lives: `rust/wa-whatsapp-index/src/lib.rs` (`backfill_caps_are_the_contracts`) asserts the
    // default, the alias and `BACKFILL_MAX` on `Request::validate` itself. What this test still owns is the
    // half that is the host's - that the job the host enqueued carries the clamped count (120, above) on the
    // contract's queue, which is what the assertion before this comment reads.

    // A chat that is not an exact JID is refused before the queue, like every other query.
    let bare = ask_in(&queue, seam::Op::Backfill, &serde_json::json!({"chat": "5511999999999"}), 50, BUILD);
    assert_eq!(bare["error"], "whatsapp_backfill_bad_chat");
    assert_eq!(bare["effect"], "none");

    // The component's answer is the request list, never a message.
    let wa_queue::TakeOutcome::Job(taken) = queue.take(seam::queue(), "wa-whatsapp", None).unwrap() else {
        panic!("the job must be takeable");
    };
    let body = wa_whatsapp_index::backfill_answer(
        vec![wa_whatsapp_index::BackfillChat {
            chat: "5511999999999@lid".into(),
            count: 120,
            oldest_id: "3EB01".into(),
            oldest_ts: 1_760_000_000_000,
        }],
        "one chat could not be asked",
    );
    let answer = seam::answer(seam::Op::Backfill, body);
    queue.done_by(taken.id, "wa-whatsapp", &serde_json::to_vec(&answer).unwrap()).unwrap();
    // The decode of what the component settled (a settled job is never replayed to a later caller:
    // `a_settled_read_is_not_replayed_to_the_next_caller`).
    let settled = queue.job(taken.id).expect("job").expect("the record");
    let answer = super::settled_answer(seam::Op::Backfill, &settled);
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["op"], "backfill");
    assert_eq!(answer["count"], 1);
    assert_eq!(answer["chats"][0]["chat"], "5511999999999@lid");
    assert_eq!(answer["chats"][0]["count"], 120);
    assert_eq!(answer["note"], "one chat could not be asked");
    assert!(answer.get("messages").is_none(), "a backfill answer never carries a message");
}

#[test]
fn a_legacy_group_id_from_a_search_hit_is_a_chat_every_question_accepts() {
    // The live finding (07/11), at the producer: a search hit names an older group by
    // `9999999999999-9999999999@g.us`, and passing that value to read/media/reactions/download was
    // refused as `bad_chat`. Each question is asked here and must reach the queue naming it exactly.
    let chat = "9999999999999-9999999999@g.us";
    let (_host, queue) = queue("legacy-group");
    if skip_without_component("a_legacy_group_id_from_a_search_hit_is_a_chat_every_question_accepts") { return; }
    for (op, args) in [
        (seam::Op::Read, serde_json::json!({"chat": chat, "limit": 5})),
        (seam::Op::Reactions, serde_json::json!({"chat": chat, "id": "3EB01"})),
        (seam::Op::Media, serde_json::json!({"chat": chat, "id": "3EB01"})),
        (seam::Op::Download, serde_json::json!({"chat": chat, "id": "3EB01"})),
        (seam::Op::Search, serde_json::json!({"chat": chat})),
        (seam::Op::Search, serde_json::json!({"from": chat, "q": "oi"})),
        (seam::Op::Backfill, serde_json::json!({"chat": chat, "count": 10})),
    ] {
        let slow = ask_in(&queue, op, &args, 1, BUILD);
        assert_eq!(slow["error"], format!("{}_slow", op.tool()), "{} {args}", op.tool());
        let id = slow["id"].as_u64().expect("the job id");
        let job = queue.job(wa_queue::JobId(id)).unwrap().unwrap();
        assert_eq!(job.queue, seam::queue());
        let verified = wa_whatsapp_index::Request::decode(&job.payload).unwrap().validate().unwrap();
        let named = verified.chat.as_deref().or(verified.from.as_deref());
        assert_eq!(named, Some(chat), "{} {args}", op.tool());    }
}

#[test]
fn a_bad_argument_is_refused_before_the_queue() {
    let (_host, queue) = queue("refusal");
    if skip_without_component("a_bad_argument_is_refused_before_the_queue") { return; }
    for (op, args, code) in [
        (seam::Op::Search, serde_json::json!({}), "whatsapp_search_empty_query"),
        // An address-shaped chat keeps the exact-JID rule and is refused before anything is queued.
        (seam::Op::Read, serde_json::json!({"chat": "9999999999999-9999999999999@s.whatsapp.net"}), "whatsapp_read_bad_chat"),
        (seam::Op::Read, serde_json::json!({"chat": "1-2-3@g.us"}), "whatsapp_read_bad_chat"),
        (seam::Op::Reactions, serde_json::json!({"chat": "5511999999999@lid"}), "whatsapp_reactions_chat_and_id_required"),
        (seam::Op::Download, serde_json::json!({"chat": "5511999999999@lid", "id": "3EB0 X"}), "whatsapp_download_bad_id"),
    ] {
        let answer = ask_in(&queue, op, &args, 50, BUILD);
        assert_eq!(answer["error"], code, "{op:?} {args}");
        assert_eq!(answer["effect"], "none");
    }
    // Nothing was written for a request that never validated.
    assert_eq!(queue.stats(seam::queue()).unwrap().ready, 0);
    // A *name* is a question, not a bad argument: it is queued for the index to resolve and the answer
    // here is "still running" (no component in a test), never a refusal (#117).
    let named = ask_in(&queue, seam::Op::Read, &serde_json::json!({"chat": "Laura"}), 50, BUILD);
    assert_eq!(named["error"], "whatsapp_read_slow", "{named}");
    assert_eq!(named["retry"], true, "a name was queued, not refused: {named}");
    assert_eq!(queue.stats(seam::queue()).unwrap().ready, 1, "the question is one job for the component");
}

#[test]
fn a_download_reads_the_last_attempts_chunks_and_checks_the_hash() {
    let (_host, queue) = queue("download");
    if skip_without_component("a_download_reads_the_last_attempts_chunks_and_checks_the_hash") { return; }
    let request = wa_whatsapp_index::Request { op: "download".into(), chat: Some("5511999999999@lid".into()), id: Some("I1".into()), ..Default::default() };
    let verified = request.validate().unwrap();
    queue
        .enqueue(EnqueueRequest::new(seam::queue(), verified.to_request().encode()).fresh_for(seam::fresh_ms()).max_attempts(seam::max_attempts()))
        .unwrap();
    let payload = b"a photo of a receipt";
    let manifest = seam::Download {
        chat: "5511999999999@lid".into(),
        id: "I1".into(),
        kind: "image".into(),
        mime: "image/jpeg".into(),
        filename: "IMG-1.jpg".into(),
        sha256: sha256_hex(payload),
        bytes: payload.len() as u64,
        chunks: 1,
        path: None,
    };
    // A failed first attempt, then the real one: progress is append-only, so both are stored.
    queue.progress(wa_queue::JobId(1), &wa_whatsapp_index::download_header(1)).unwrap();
    queue.progress(wa_queue::JobId(1), b"half a fi").unwrap();
    queue.progress(wa_queue::JobId(1), &wa_whatsapp_index::download_header(1)).unwrap();
    queue.progress(wa_queue::JobId(1), payload).unwrap();
    let bytes = collect_in(&queue, 1, &manifest).expect("the last attempt is the whole file");
    assert_eq!(bytes, payload);
    // A hash the bytes do not make is refused, never written to disk.
    let mut wrong = manifest.clone();
    wrong.sha256 = "00".repeat(32);
    let (code, _) = collect_in(&queue, 1, &wrong).expect_err("a wrong digest is refused");
    assert_eq!(code, "hash_mismatch");
    // And a job whose chunks are not all there is refused too.
    let mut greedy = manifest.clone();
    greedy.chunks = 4;
    let (code, _) = collect_in(&queue, 1, &greedy).expect_err("missing chunks are refused");
    assert_eq!(code, "progress_incomplete");
}

#[test]
fn a_download_filename_cannot_escape_the_directory() {
    let manifest = seam::Download {
        chat: "5511999999999@lid".into(),
        id: "3EB0ABCDEF".into(),
        kind: "document".into(),
        mime: "application/pdf".into(),
        filename: "../../../etc/passwd".into(),
        sha256: String::new(),
        bytes: 10,
        chunks: 1,
        path: None,
    };
    let name = file_name(&manifest);
    assert!(!name.contains('/') && !name.contains('\\'), "{name}");
    assert!(!name.starts_with('.'), "{name}");
    assert!(name.starts_with("3EB0ABCDEF-"), "{name}");
    assert!(name.ends_with(".pdf"), "{name}");
    // A message that named no file at all still gets a name with an extension from its MIME type.
    let mut nameless = manifest.clone();
    nameless.filename = String::new();
    nameless.mime = "image/jpeg".into();
    let name = file_name(&nameless);
    assert!(name.ends_with(".jpg"), "{name}");
}

#[test]
fn the_download_directory_is_pruned_to_its_bounds() {
    let dir = temp_dir("prune");
    for i in 0..5 {
        std::fs::write(dir.join(format!("f{i}")), vec![0u8; 10]).unwrap();
        // Distinct modification times, so "oldest" is well defined.
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    // Fifty bytes stored plus thirty incoming is over a forty-five byte bound: the oldest entries go
    // first, and the newest one stays (the bound is measured with the file about to be written).
    prune_to(&dir, 30, 64, 45);
    assert_eq!(file_count(&dir), 1, "everything but the newest file was removed");
    assert!(dir.join("f4").exists(), "the newest file is the last to go");
    // The count bound works on its own too.
    for i in 0..5 {
        std::fs::write(dir.join(format!("g{i}")), vec![0u8; 1]).unwrap();
    }
    // The file about to be written counts against the bound too: three kept means two already there
    // plus the one being written.
    prune_to(&dir, 1, 3, 1024 * 1024);
    assert_eq!(file_count(&dir), 2);
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_reason_is_one_bounded_line() {
    let line = one_line("multi\nline\terror");
    assert!(!line.contains('\n') && !line.contains('\t'), "{line}");
    assert!(one_line(&"x".repeat(500)).chars().count() <= 160);
}

#[test]
fn every_op_the_seam_defines_is_a_host_capability() {
    // The contract between the node and the component, from the node's side: the seam's op list and the
    // capability registry are the same set, so an op can never be enqueued by nobody (a name the model
    // is offered with no `host.whatsapp_*` behind it) or registered with no question to ask.
    //
    // Measured 13/11 on the account node: `mcp_whatsapp_contacts` reached a component built before
    // `contacts` existed, was refused `bad_op`, retried, dead-lettered, and answered
    // `whatsapp_contacts_failed state=dead` twenty seconds later - a disagreement no test could see.
    let registered: Vec<&str> = crate::capabilities::inventory().iter().map(|capability| capability.name).collect();
    for op in seam::Op::ALL {
        assert!(
            registered.contains(&op.tool()),
            "{} is one of the seam's ops but no host capability answers it",
            op.tool()
        );
    }
}

/// The capabilities of this world that are answered by the NODE, not by a question to the component.
///
/// `whatsapp_approve` reads and decides the drafts waiting for an operator: it enqueues a send when a
/// draft is approved and queues nothing when it is rejected. It is a policy capability over the world's
/// own traffic, so there is no op for it in the seam and there should not be one.
const NODE_SIDE_CAPABILITIES: &[&str] = &[
    // The three generic doors: each forwards its argument document to whichever op it names, so the
    // world is reachable through one capability per effect class rather than one per op.
    "whatsapp_index",
    "whatsapp_file",
    "whatsapp_request",
    // The send and its state travel the outbox queue (`whatsapp.outbox`), not an op on the query queue:
    // the component consumes that queue on a tick of its own.
    "whatsapp_send",
    "whatsapp_send_status",
    // A policy capability over the world's own traffic: it decides the drafts waiting for an operator and
    // enqueues the send when one is approved, so there is nothing for the component to answer.
    "whatsapp_approve",
    // Index archives are this node's files (cut a month into a sealed file, list, push with its sha256),
    // handled by the node because the component never sees a sealed archive.
    "whatsapp_archive",
];

#[test]
fn every_host_capability_of_the_world_is_a_seam_op_or_a_named_node_side_capability() {
    // The other direction of `every_op_the_seam_defines_is_a_host_capability`, which the tree did not
    // have: that row proves every seam op has a host capability, and this one proves the converse for
    // the world's own surface - so neither side can grow a name the other never hears about.
    //
    // It is NOT set equality, and the first version of this test found out why: `whatsapp_approve` is
    // a capability of the world with no op behind it, because the node answers it itself. The
    // exception is written down instead of being assumed, so a capability added here with no op and no
    // entry in the list above fails this row - which is the decision its author has to make.
    let declared: Vec<&str> = crate::capabilities::inventory()
        .iter()
        .map(|capability| capability.name)
        .filter(|name| name.starts_with("whatsapp_"))
        .collect();
    for name in &declared {
        if seam::Op::ALL.iter().any(|op| op.tool() == *name) {
            continue;
        }
        assert!(
            NODE_SIDE_CAPABILITIES.contains(name),
            "{name} is a capability of this world with no op in the seam: either it is a question to the              component that the seam is missing, or it is answered by the node and belongs in              NODE_SIDE_CAPABILITIES with the reason"
        );
    }
    // And the list cannot rot: a name in it that is no longer a capability is a stale justification.
    for name in NODE_SIDE_CAPABILITIES {
        assert!(declared.contains(name), "{name} is listed as node-side but is no longer a capability");
    }
}

#[test]
fn a_settled_refusal_is_the_tools_own_error_and_not_a_dead_letter() {
    // The component answers a payload it can never read (`seam::terminal_refusal`): the job settles
    // `done`, and the tool names the refusal by its own code at once.
    let (_host, queue) = queue("settled-refusal");
    if skip_without_component("a_settled_refusal_is_the_tools_own_error_and_not_a_dead_letter") { return; }
    let args = serde_json::json!({});
    let first = ask_in(&queue, seam::Op::Contacts, &args, 1, BUILD);
    let id = first["id"].as_u64().unwrap_or_else(|| panic!("a job was queued: {first}"));
    // The worker takes it and answers the refusal.
    let _ = queue.take(seam::queue(), COMPONENT, None).expect("take");
    let refusal = wa_whatsapp_index::Refusal::new("bad_op", "op must be one of search, read, contacts");
    let body = serde_json::to_vec(&wa_whatsapp_index::terminal_refusal("contacts", &refusal)).unwrap();
    queue.done_by(wa_queue::JobId(id), COMPONENT, &body).expect("settle the refusal");
    // The settled refusal is answered by its own word (a settled job is never replayed to a later
    // caller: `a_settled_read_is_not_replayed_to_the_next_caller`).
    let settled = queue.job(wa_queue::JobId(id)).expect("job").expect("the record");
    let answer = super::settled_answer(seam::Op::Contacts, &settled);
    assert_eq!(answer["error"], "whatsapp_contacts_bad_op", "{answer}");
    assert_eq!(answer["state"], "refused");
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["effect"], "none");
    assert!(
        answer["note"].as_str().unwrap_or_default().contains("wa services upgrade wa-whatsapp"),
        "the refusal names the fix: {answer}"
    );
    assert_eq!(queue.stats(seam::queue()).expect("stats").dead, 0, "nothing was dead-lettered");
}

#[test]
fn a_dead_permanent_refusal_from_an_older_component_still_names_its_code() {
    // A component built before the host learned an op cannot settle it; it fails the job and the queue
    // dead-letters it. That is still a refusal the caller can act on, and the tool says so by its code
    // instead of `_failed state=dead`.
    let (_host, queue) = queue("dead-permanent");
    if skip_without_component("a_dead_permanent_refusal_from_an_older_component_still_names_its_code") { return; }
    let args = serde_json::json!({ "q": "Laura" });
    // One attempt, so the component's refusal is final and the queue dead-letters it - the state an
    // older component leaves on a live node.
    let verified = wa_whatsapp_index::Request { op: "contacts".into(), q: Some("Laura".into()), ..Default::default() }
        .validate()
        .expect("a contacts question validates");
    let id = queue
        .enqueue(
            EnqueueRequest::new(seam::queue(), verified.to_request().encode())
                .fresh_for(seam::fresh_ms())
                .max_attempts(1)
                .dedupe(verified.dedupe_key_in(BUILD)),
        )
        .expect("enqueue")
        .id
        .0;
    let _ = queue.take(seam::queue(), COMPONENT, None).expect("take");
    queue.fail_by(wa_queue::JobId(id), COMPONENT, "permanent:bad_op").expect("record the refusal");
    let answer = ask_in(&queue, seam::Op::Contacts, &args, 50, BUILD);
    assert_eq!(answer["error"], "whatsapp_contacts_bad_op", "{answer}");
    assert_eq!(answer["state"], "dead", "the queue's own word for how it ended: {answer}");
    assert_eq!(queue.stats(seam::queue()).expect("stats").ready, 0, "nothing is retried");
}

#[test]
fn a_job_that_died_on_an_older_component_is_not_the_answer_a_new_call_reads() {
    // Measured on the account node, 13/11: `whatsapp_contacts {limit:1}` answered
    // `whatsapp_contacts_bad_op state=dead` for hours after the component that accepts `contacts` was
    // installed, because the dedupe key was the request alone and `wa:queue` answers a repeated key
    // with the job that already carries it - whatever state that job is in.
    let (_host, queue) = queue("stale-build");
    if skip_without_component("a_job_that_died_on_an_older_component_is_not_the_answer_a_new_call_reads") { return; }
    let args = serde_json::json!({ "q": "Laura", "limit": 1 });
    let verified = wa_whatsapp_index::Request { op: "contacts".into(), q: Some("Laura".into()), limit: Some(1), ..Default::default() }
        .validate()
        .expect("a contacts question validates");
    // The job the previous component build was given, dead-lettered with its refusal.
    let stale = queue
        .enqueue(
            EnqueueRequest::new(seam::queue(), verified.to_request().encode())
                .fresh_for(seam::fresh_ms())
                .max_attempts(1)
                .dedupe(verified.dedupe_key_in("build-before-contacts")),
        )
        .expect("enqueue")
        .id
        .0;
    let _ = queue.take(seam::queue(), COMPONENT, None).expect("take");
    queue.fail_by(wa_queue::JobId(stale), COMPONENT, "permanent:bad_op").expect("record the refusal");
    // The same call, now answered by the build that knows the op: a NEW job, never that refusal.
    let answer = ask_in(&queue, seam::Op::Contacts, &args, 1, BUILD);
    assert_eq!(answer["error"], "whatsapp_contacts_slow", "{answer}");
    let fresh = answer["id"].as_u64().expect("the new job's id");
    assert_ne!(fresh, stale, "the dead job of another build is not read again");
    let job = queue.job(wa_queue::JobId(fresh)).unwrap().unwrap();
    assert_eq!(job.state.as_str(), "ready", "a job the current build can answer");
    assert_eq!(wa_whatsapp_index::Request::decode(&job.payload).unwrap().op, "contacts");

    // Within ONE build the promise still holds: a repeated call reads the same job.
    let again = ask_in(&queue, seam::Op::Contacts, &args, 1, BUILD);
    assert_eq!(again["id"].as_u64(), Some(fresh));
}

/// The op carried as data answers the SAME bytes as the typed-op path it replaces, and asks the
/// component the SAME question.
///
/// `reactions` is the first op moved onto the data seam (`answer_text`): the host stops naming a variant
/// per op, which is the coupling that made every WhatsApp change a host rebuild. A move like that is only
/// safe if it is invisible - the request on the wire, and the answer the tool gives, stay byte for byte
/// what they were. This test cannot pass on the tree before the change (`ask_text_in` does not exist
/// there), and on the tree after it fails if either drifts.
#[test]
fn the_op_named_as_data_answers_the_same_bytes_as_the_typed_op() {
    let args = serde_json::json!({"chat": "15550000001@lid", "id": "3EB0C0FFEE11"});
    let (_h1, typed_q) = queue("opdata-typed");
    let (_h2, data_q) = queue("opdata-data");

    // 1. Nothing has answered yet: "still running", byte for byte (it carries the job id, so this also
    //    pins that both paths queued the same request).
    let typed = ask_in(&typed_q, seam::Op::Reactions, &args, 1, BUILD);
    let as_data = ask_text_in(&data_q, "reactions", &args, 1, BUILD);
    assert_eq!(typed["error"], "whatsapp_reactions_slow");
    assert_eq!(json_text(&typed), json_text(&as_data));

    // 2. The same question on the wire: the payload the component validates.
    let typed_job = typed_q.job(wa_queue::JobId(typed["id"].as_u64().expect("typed job id"))).unwrap().unwrap();
    let data_job = data_q.job(wa_queue::JobId(as_data["id"].as_u64().expect("data job id"))).unwrap().unwrap();
    assert_eq!(typed_job.payload, data_job.payload, "the component is asked the same bytes");
    assert_eq!(wa_whatsapp_index::Request::decode(&data_job.payload).unwrap().op, "reactions");

    // 3. A refusal before anything is queued: the same word, the same sentence.
    let bad = serde_json::json!({"chat": "not a chat", "id": "3EB0C0FFEE11"});
    let typed_bad = ask_in(&typed_q, seam::Op::Reactions, &bad, 1, BUILD);
    let data_bad = ask_text_in(&data_q, "reactions", &bad, 1, BUILD);
    assert_eq!(data_bad["error"], "whatsapp_reactions_bad_chat");
    assert_eq!(json_text(&typed_bad), json_text(&data_bad));

    // 4. An op nobody knows is refused by name and writes no job: the typed path cannot even spell it,
    //    and the data path must not let the word through to the component.
    let ready_before = data_q.stats(seam::queue()).unwrap().ready;
    let unknown = ask_text_in(&data_q, "nope", &args, 1, BUILD);
    assert_eq!(unknown["error"], "whatsapp_nope_bad_op");
    assert_eq!(unknown["ok"], false);
    assert_eq!(data_q.stats(seam::queue()).unwrap().ready, ready_before, "no job for an op nothing can answer");

    // 5. A settled answer is the tool answer, through the same shaper: the data path's job, answered by
    //    the component, comes back as the component wrote it (never as a slow query).
    let wa_queue::TakeOutcome::Job(taken) = data_q.take(seam::queue(), COMPONENT, None).unwrap() else {
        panic!("the data path's job must be takeable");
    };
    let component_answer = serde_json::json!({"chat": "15550000001@lid", "id": "3EB0C0FFEE11", "count": 0, "reactions": []});
    let settled = seam::answer(seam::Op::Reactions, component_answer.clone());
    data_q.done_by(taken.id, COMPONENT, &serde_json::to_vec(&settled).unwrap()).unwrap();
    let answered = settle(&data_q, seam::Op::Reactions, taken.id.0, 1);
    // The tool answer is the component's answer plus the one thing the component cannot know: WHICH job
    // gave it (`job`, the queue id). Everything the component wrote crosses untouched, and the extra field
    // is what makes a fresh answer distinguishable from a replayed one from outside the process.
    let mut expected = settled.clone();
    expected["job"] = Value::from(taken.id.0);
    assert_eq!(json_text(&answered), json_text(&expected), "the tool answer is the component's answer, named by the job that gave it");
    assert_eq!(answered["ok"], true);
}

/// One answer as the bytes it leaves the host as: key order is the encoder's, and the comparison is of
/// the document.
fn json_text(value: &Value) -> String {
    serde_json::to_string(value).expect("a JSON value")
}

/// The generic row (`whatsapp_index`, the op in the request) answers byte for byte what the named row
/// of the same op answers, and queues the same job - for every read op it carries.
///
/// This is what lets the hub stop naming read ops: once a tool row points at the generic door, a new
/// read-only op is the component's business, and no row, description or digest in `wa-capabilities`
/// moves for it. The equality is asserted per op before any tool row is repointed, so the repoint has
/// something to keep.
#[test]
fn the_generic_row_answers_the_same_bytes_as_the_named_row_for_every_read_op() {
    let cases: [(&str, seam::Op, Value); 6] = [
        ("search", seam::Op::Search, serde_json::json!({"q": "boleto", "chat": "15550000001@lid", "limit": 5})),
        ("read", seam::Op::Read, serde_json::json!({"chat": "15550000001@lid", "limit": 3})),
        ("contacts", seam::Op::Contacts, serde_json::json!({"q": "1555"})),
        ("message", seam::Op::Message, serde_json::json!({"chat": "15550000001@lid", "id": "3EB0C0FFEE11"})),
        ("reactions", seam::Op::Reactions, serde_json::json!({"chat": "15550000001@lid", "id": "3EB0C0FFEE11"})),
        ("media", seam::Op::Media, serde_json::json!({"chat": "15550000001@lid", "id": "3EB0C0FFEE11"})),
    ];
    for (op_text, op, args) in cases {
        let (_h1, named_q) = queue(&format!("generic-named-{op_text}"));
        let (_h2, generic_q) = queue(&format!("generic-data-{op_text}"));
        let named = ask_in(&named_q, op, &args, 1, BUILD);
        // The generic door is handed the op in the request, as `M.invoke` hands it.
        let mut with_op = args.clone();
        with_op["op"] = serde_json::json!(op_text);
        let generic = ask_index_in(&generic_q, &with_op, 1, BUILD);
        assert_eq!(named["error"], format!("whatsapp_{op_text}_slow"), "{op_text}: nothing answered yet");
        assert_eq!(json_text(&named), json_text(&generic), "{op_text}: the same answer bytes");
        let named_job = named_q.job(wa_queue::JobId(named["id"].as_u64().expect("named job id"))).unwrap().unwrap();
        let generic_job = generic_q.job(wa_queue::JobId(generic["id"].as_u64().expect("generic job id"))).unwrap().unwrap();
        assert_eq!(named_job.payload, generic_job.payload, "{op_text}: the component is asked the same bytes");
    }
}

/// The generic door refuses to guess: no `op` is a named refusal, not a queue write.
#[test]
fn the_generic_row_refuses_a_request_that_names_no_op() {
    let (_host, q) = queue("generic-noop");
    let ready_before = q.stats(seam::queue()).unwrap().ready;
    let answer = ask_index_in(&q, &serde_json::json!({"q": "boleto"}), 1, BUILD);
    assert_eq!(answer["error"], "whatsapp_index_op_required");
    assert_eq!(answer["ok"], false);
    assert_eq!(q.stats(seam::queue()).unwrap().ready, ready_before, "nothing is queued without an op");
}

/// The generic door carries the READS and nothing else: an op that asks the phone or writes a file is
/// refused by name and queues nothing, because this row declares `read-only` and a sandbox joins it as
/// one. Measured 25/11 before the fix: `whatsapp_index({op:"backfill"})` queued the phone request and
/// `{op:"download"}` queued a file write, both through a capability the inventory calls ReadOnly.
#[test]
fn the_generic_door_carries_only_the_reads_and_refuses_a_network_or_file_op() {
    let (_host, q) = queue("generic-effect");
    for op in seam::Op::ALL {
        let mut args = serde_json::json!({"chat": "15550000001@lid", "id": "3EB0C0FFEE11", "q": "boleto", "count": 5});
        args["op"] = serde_json::json!(op.as_str());
        let ready_before = q.stats(seam::queue()).unwrap().ready;
        let answer = ask_index_in(&q, &args, 1, BUILD);
        let own_door = format!("whatsapp_{}_use_its_own_door", op.as_str());
        match op.effect() {
            seam::Effect::ReadOnly => assert_ne!(answer["error"], own_door, "{} is a read and this door carries it", op.as_str()),
            seam::Effect::Network | seam::Effect::WritesFiles => {
                assert_eq!(answer["error"], own_door, "{} has an effect: this door must send it to its own row", op.as_str());
                assert_eq!(answer["ok"], false);
                assert_eq!(q.stats(seam::queue()).unwrap().ready, ready_before, "{} queued nothing through the read door", op.as_str());
            }
        }
    }
}

/// The network door carries the question that reaches the phone, and only that: `backfill` answers
/// through it byte for byte as through its named row, a read is refused by name, and nothing is queued
/// for the op the door does not declare.
#[test]
fn the_network_door_carries_backfill_and_refuses_a_read() {
    let (_h1, named_q) = queue("network-named");
    let (_h2, door_q) = queue("network-door");
    let args = serde_json::json!({"count": 5});
    let named = ask_in(&named_q, seam::Op::Backfill, &args, 1, BUILD);
    let mut with_op = args.clone();
    with_op["op"] = serde_json::json!("backfill");
    let through_door = ask_class_in(&door_q, &with_op, "request", seam::Effect::Network, 1, BUILD);
    assert_eq!(named["error"], "whatsapp_backfill_slow");
    assert_eq!(json_text(&named), json_text(&through_door), "the same answer bytes");
    let named_job = named_q.job(wa_queue::JobId(named["id"].as_u64().expect("named id"))).unwrap().unwrap();
    let door_job = door_q.job(wa_queue::JobId(through_door["id"].as_u64().expect("door id"))).unwrap().unwrap();
    assert_eq!(named_job.payload, door_job.payload, "the component is asked the same bytes");

    // A read through this door is refused by name, and queues nothing.
    let ready_before = door_q.stats(seam::queue()).unwrap().ready;
    let mut read_args = serde_json::json!({"q": "boleto"});
    read_args["op"] = serde_json::json!("search");
    let refused = ask_class_in(&door_q, &read_args, "request", seam::Effect::Network, 1, BUILD);
    assert_eq!(refused["error"], "whatsapp_search_use_its_own_door");
    assert_eq!(door_q.stats(seam::queue()).unwrap().ready, ready_before, "a read queued nothing through the network door");
}

/// The file door carries the op whose answer is a file this node writes, and only that class: `download`
/// answers through it byte for byte as through its named row, in the class the row declares, at the
/// download's own wait; a read and a phone request are refused by name and queue nothing.
#[test]
fn the_file_door_carries_download_and_refuses_the_other_classes() {
    let (_h1, named_q) = queue("file-named");
    let (_h2, door_q) = queue("file-door");
    let args = serde_json::json!({"chat": "15550000001@lid", "id": "3EB0C0FFEE11"});
    let named = ask_in(&named_q, seam::Op::Download, &args, 1, BUILD);
    let mut with_op = args.clone();
    with_op["op"] = serde_json::json!("download");
    // The same call the door makes, through the same wait, so the two answers are comparable.
    let through_door = ask_class_in(&door_q, &with_op, "file", seam::Effect::WritesFiles, 1, BUILD);
    assert_eq!(named["error"], "whatsapp_download_slow");
    assert_eq!(json_text(&named), json_text(&through_door), "the same answer bytes");
    let named_job = named_q.job(wa_queue::JobId(named["id"].as_u64().expect("named id"))).unwrap().unwrap();
    let door_job = door_q.job(wa_queue::JobId(through_door["id"].as_u64().expect("door id"))).unwrap().unwrap();
    assert_eq!(named_job.payload, door_job.payload, "the component is asked the same bytes");

    for (op, effect) in [("search", seam::Effect::ReadOnly), ("backfill", seam::Effect::Network)] {
        let mut asked = serde_json::json!({"q": "boleto", "count": 5});
        asked["op"] = serde_json::json!(op);
        let ready_before = door_q.stats(seam::queue()).unwrap().ready;
        let refused = ask_class_in(&door_q, &asked, "file", seam::Effect::WritesFiles, 1, BUILD);
        assert_eq!(refused["error"], format!("whatsapp_{op}_use_its_own_door"), "{op} is not a file op");
        assert_eq!(q_stats_ready(&door_q), ready_before, "{op} queued nothing through the file door");
        let _ = effect;
    }
}

/// The ready count of the query queue, as the tests above read it.
fn q_stats_ready(q: &wa_queue::Queue) -> usize {
    q.stats(seam::queue()).unwrap().ready
}

/// The registry is served by the READ door and only by it: the word travels on the same queue as every
/// question, the component answers its own document, and the other two doors refuse it by name. It is
/// the world's `ops.registry` (`wa:whatsapp@0.2.0`) arriving over the transport that exists today.
#[test]
fn the_read_door_serves_the_registry_and_the_other_doors_refuse_it() {
    let (_host, q) = queue("registry");
    let args = serde_json::json!({"op": "ops"});
    // Nothing has answered yet: the registry's own slow answer, with the word it was asked with.
    let slow = ask_registry_in(&q, &args, BUILD);
    assert_eq!(slow["error"], "whatsapp_ops_slow");
    assert_eq!(slow["op"], seam::registry_op());
    let id = slow["id"].as_u64().expect("the registry job id");
    // The payload is the caller's own document, forwarded as it arrived: it is NOT an index request,
    // so `Request::validate` - what every other question must survive - refuses it. That is the point.
    let wa_queue::TakeOutcome::Job(taken) = q.take(seam::queue(), COMPONENT, None).unwrap() else {
        panic!("the registry job must be takeable");
    };
    assert_eq!(taken.id.0, id);
    assert_eq!(taken.payload, serde_json::to_vec(&args).unwrap(), "the word is forwarded untouched");
    // `decode` is a parse; `validate` is the check every index question must survive, and the
    // registry does not - which is why it is forwarded as it arrives instead.
    let parsed = wa_whatsapp_index::Request::decode(&taken.payload).expect("it is a request document");
    assert!(parsed.validate().is_err(), "the registry is not an index question");
    // The component's answer is its registry document, and it is what a settled job carries.
    let document = seam::registry();
    q.done_by(taken.id, COMPONENT, &serde_json::to_vec(&document).unwrap()).unwrap();
    let settled = q.job(wa_queue::JobId(id)).unwrap().unwrap();
    assert_eq!(settled.result.as_deref(), Some(serde_json::to_vec(&document).unwrap().as_slice()),
        "the tool answer is the component's own document, byte for byte");
    assert_eq!(document["ops"].as_array().map(|ops| ops.len()), Some(seam::Op::ALL.len()));

    // The other two doors declare another class, and say so rather than forwarding the word.
    for (door, want) in [("request", seam::Effect::Network), ("file", seam::Effect::WritesFiles)] {
        let refused = ask_class_in(&q, &args, door, want, 1, BUILD);
        assert_eq!(refused["error"], "whatsapp_ops_use_its_own_door", "{door} refuses the registry");
        assert_eq!(refused["effect"], "none");
    }
    }

/// A date a model wrote reaches the wire as milliseconds, and a time nobody can read is refused by name with
/// the forms. EVERY ASSERTION OF THAT LIVES IN THE CONTRACT NOW: `Request::validate` and `parse_time` are
/// answered by the `whatsapp-index` component, and `rust/wa-whatsapp-index/src/lib.rs`
/// (`a_date_is_midnight_and_a_word_is_refused`) states the same cases on the rule itself - `2026-11-01` is
/// 1793491200000, `1760000000` is seconds, and `last tuesday` and `01/11/2026` are refused with the forms.
/// What is left here is one thing the host still owns: that an unreadable time stops the call BEFORE a job
/// exists, which the queue count below measures.
#[test]
fn an_unreadable_time_is_refused_before_a_job_exists() {
    let (_host, queue) = queue("times");
    if skip_without_component("an_unreadable_time_is_refused_before_a_job_exists") { return; }
    let refused = ask_in(&queue, seam::Op::Search, &serde_json::json!({"q": "boleto", "since": "last tuesday"}), 50, BUILD);
    assert_eq!(refused["error"], "whatsapp_search_bad_since", "{refused}");
    assert_eq!(refused["effect"], "none");
    // Nothing was queued: a refusal is answered before a job exists, so the queue never minted an id -
    // `job(1)` is the first one it would hand out.
    assert!(queue.job(wa_queue::JobId(1)).unwrap().is_none(), "a refused call queues nothing");
}

/// The cursor the contacts tool advertises (ready-heals.md §25) has to survive the host: `before` must land
/// on the wire as the component's `Request.before`. Without this row the tool would advertise a page it
/// cannot pass, and every test would agree with it.
#[test]
fn the_host_carries_the_contacts_cursor_onto_the_wire() {
    let (_host, queue) = queue("contacts-before");
    if skip_without_component("the_host_carries_the_contacts_cursor_onto_the_wire") { return; }
    let cursor = "15550000001@lid";
    let args = serde_json::json!({"q": "Contato", "limit": 20, "before": cursor});
    let slow = ask_in(&queue, seam::Op::Contacts, &args, 1, BUILD);
    let id = slow["id"].as_u64().expect("the job id");
    let job = queue.job(wa_queue::JobId(id)).unwrap().unwrap();
    let request = wa_whatsapp_index::Request::decode(&job.payload).expect("a query request");
    assert_eq!(request.before.as_deref(), Some(cursor), "the cursor reaches the component");
    assert_eq!(request.validate().expect("a valid request").before.as_deref(), Some(cursor));
    // And the read op keeps its own cursor, unchanged: one mapping, every op that carries one.
    let read = ask_in(&queue, seam::Op::Read, &serde_json::json!({"chat": "15550000001@lid", "before": "3EB0"}), 1, BUILD);
    let read_job = queue.job(wa_queue::JobId(read["id"].as_u64().expect("read job"))).unwrap().unwrap();
    assert_eq!(wa_whatsapp_index::Request::decode(&read_job.payload).expect("a request").before.as_deref(), Some("3EB0"));
}

/// The answer says WHICH job answered it, and two identical calls are two jobs.
///
/// Why this is a test and not a comment: before `job` the answer carried no way to tell a fresh read from
/// one the queue replayed, so the 23/11 bug (three reads in a row answering 15:40, 16:15 and 15:44) was
/// invisible from outside the process, and the cross-process row that bug needs had nothing to assert on.
/// The id is the promise: two identical calls answered by one id are ONE answer; answered by two ids they
/// are two reads of the index.
#[test]
fn the_answer_names_the_job_that_answered_it() {
    let (_host, queue) = queue("names-its-job");
    if skip_without_component("the_answer_names_the_job_that_answered_it") { return; }
    let args = serde_json::json!({"chat": "5511999999999@lid", "limit": 3});
    let slow = ask_in(&queue, seam::Op::Read, &args, 1, BUILD);
    let first = slow["id"].as_u64().expect("the pending handle names the job");
    // The component answers that job, and the continuation names it: one call, one id, end to end.
    let wa_queue::TakeOutcome::Job(taken) = queue.take(seam::queue(), "wa-whatsapp", None).unwrap() else {
        panic!("the job must be takeable");
    };
    let answer = seam::answer(
        seam::Op::Read,
        serde_json::json!({"chat": "5511999999999@lid", "messages": [{"id": "3EB01", "text": "oi"}], "count": 1}),
    );
    queue.done_by(taken.id, "wa-whatsapp", &serde_json::to_vec(&answer).unwrap()).unwrap();
    let settled = ask_in(&queue, seam::Op::Read, &serde_json::json!({"__job": first}), 1, BUILD);
    assert_eq!(settled["job"].as_u64(), Some(first), "the settled answer names the job that produced it: {settled}");
    assert_eq!(settled["count"], 1, "and it is still the component's own document: {settled}");
    // The claim was released when the job settled, so the SAME question is a NEW job with its own id -
    // the exact fact the 23/11 bug got wrong (one id answering an hour of calls).
    let second = ask_in(&queue, seam::Op::Read, &args, 1, BUILD);
    let next = second["id"].as_u64().expect("a fresh job, not the settled one");
    assert_ne!(next, first, "two identical calls are two jobs: {second}");
    // A refusal names its job too: the same field, whatever the job settled as.
    let wa_queue::TakeOutcome::Job(taken2) = queue.take(seam::queue(), "wa-whatsapp", None).unwrap() else {
        panic!("the second job must be takeable");
    };
    let refusal = seam::refusal(seam::Op::Read, "chat_not_found", "the chat is not indexed");
    queue.done_by(taken2.id, "wa-whatsapp", &serde_json::to_vec(&refusal).unwrap()).unwrap();
    let refused = ask_in(&queue, seam::Op::Read, &serde_json::json!({"__job": next}), 1, BUILD);
    assert_eq!(refused["job"].as_u64(), Some(next), "a refusal names its job too: {refused}");
    assert_eq!(refused["error"], "whatsapp_read_chat_not_found", "{refused}");
}
/// A file the COMPONENT wrote is checked by the host: inside this node's directory, the size it
/// claims, and the digest the message carries. Nothing is taken on the component's word.
#[test]
fn a_file_the_component_wrote_is_verified_before_it_is_answered() {
    let dir = wa_host_support::paths::component_dir().join(DOWNLOAD_DIR);
    std::fs::create_dir_all(&dir).unwrap();
    let payload = b"a video, not a chunk stream".repeat(64);
    let digest = super::sha256_hex(&payload);
    let leaf = format!("verify-{}.bin", std::process::id());
    std::fs::write(dir.join(&leaf), &payload).unwrap();
    let manifest = seam::Download {
        chat: "5511999999999@lid".into(),
        id: "3EB0ABCDEF".into(),
        kind: "video".into(),
        mime: "video/mp4".into(),
        filename: "clip.mp4".into(),
        sha256: digest.clone(),
        bytes: payload.len() as u64,
        chunks: 0,
        path: Some(format!("/downloads/{leaf}")),
    };
    let answer = verify_stored(&manifest).expect("a real file in the node's own directory");
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["bytes"], payload.len() as u64, "{answer}");
    assert_eq!(answer["sha256"], digest, "the digest the host computed, not the one the component claimed: {answer}");
    let path = answer["path"].as_str().unwrap();
    assert!(path.contains(DOWNLOAD_DIR), "the answer names the host's path: {path}");
    assert!(path.ends_with(&leaf), "{path}");

    // A size the manifest gets wrong is refused, with the words the chunk path uses.
    let mut lying = manifest.clone();
    lying.bytes = 3;
    let (code, detail) = verify_stored(&lying).expect_err("a wrong size cannot pass");
    assert_eq!(code, "hash_mismatch", "{detail}");
    // A digest that does not match is refused the same way.
    let mut forged = manifest.clone();
    forged.sha256 = "00".repeat(32);
    assert_eq!(verify_stored(&forged).unwrap_err().0, "hash_mismatch");
    // A path that climbs out of the directory is refused by name, before anything is read.
    let mut escaping = manifest.clone();
    escaping.path = Some("/downloads/../../../../etc/passwd".into());
    assert_eq!(verify_stored(&escaping).unwrap_err().0, "path_refused");
    // And a file that is not there at all.
    let mut absent = manifest.clone();
    absent.path = Some("/downloads/nothing-here.bin".into());
    assert_eq!(verify_stored(&absent).unwrap_err().0, "path_refused");
    let _ = std::fs::remove_file(dir.join(&leaf));
}

/// The sizes Victor hit live: a 4.3 MB video (refused before) and a 40 MB one (never possible through a
/// queue that caps a job at 1 MiB of progress). Both are files the component wrote; the host reads them,
/// counts them and hashes them, and neither is anywhere near a transport bound.
#[test]
fn a_media_file_of_any_size_the_node_will_keep_is_answered_with_its_path() {
    let dir = wa_host_support::paths::component_dir().join(DOWNLOAD_DIR);
    std::fs::create_dir_all(&dir).unwrap();
    for (label, size) in [("4mb", 4 * 1024 * 1024usize), ("40mb", 40 * 1024 * 1024usize)] {
        let payload: Vec<u8> = (0..size).map(|i| (i % 251) as u8).collect();
        let leaf = format!("size-{label}-{}.mp4", std::process::id());
        std::fs::write(dir.join(&leaf), &payload).unwrap();
        let manifest = seam::Download {
            chat: "5511999999999@lid".into(),
            id: "3EB0ABCDEF".into(),
            kind: "video".into(),
            mime: "video/mp4".into(),
            filename: "clip.mp4".into(),
            sha256: super::sha256_hex(&payload),
            bytes: payload.len() as u64,
            chunks: 0,
            path: Some(format!("/downloads/{leaf}")),
        };
        let answer = verify_stored(&manifest).unwrap_or_else(|(code, detail)| panic!("{label}: {code}: {detail}"));
        assert_eq!(answer["bytes"], payload.len() as u64, "{label}: {answer}");
        assert_eq!(answer["path"].as_str().unwrap().ends_with(&leaf), true, "{label}");
        assert!(size as u64 > wa_whatsapp_index::MAX_DOWNLOAD_BYTES, "{label} is past the old transport bound, which is the point");
        assert!(size as u64 <= wa_whatsapp_index::MAX_STORED_BYTES, "{label} is inside what the node keeps");
        let _ = std::fs::remove_file(dir.join(&leaf));
    }
    // And the bound that DOES remain is the disk: a request may not ask for more than the node keeps. That
    // clamp is `Request::validate`'s, asserted on the rule in `rust/wa-whatsapp-index/src/lib.rs`
    // (`max_bytes` stops at `MAX_STORED_BYTES`), so the host does not state it a second time here.
}
