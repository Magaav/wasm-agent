//! The query capabilities, measured against a queue of their own: what a tool call enqueues, what it
//! answers, and what it refuses before anything is written.
//!
//! Nothing here touches WhatsApp or the component: the "component" is a `done` written by hand, which
//! is exactly the seam the real one settles through (`rust/components/wa-whatsapp`, `query_tick`).
use super::*;
use std::path::PathBuf;
use wa_queue::{EnqueueRequest, Policy};

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
    let args = serde_json::json!({"q": "boleto", "chat": "5511999999999@lid", "limit": 5});
    // Nothing has answered yet: the answer says "still running" with the id, and says it is retryable.
    let slow = ask_in(&queue, seam::Op::Search, &args, 1);
    assert_eq!(slow["ok"], false);
    assert_eq!(slow["error"], "whatsapp_search_slow");
    assert_eq!(slow["retry"], true);
    let id = slow["id"].as_u64().expect("the job id");
    // The payload is the request the component validates, and it names what was asked for.
    let job = queue.job(wa_queue::JobId(id)).unwrap().unwrap();
    assert_eq!(job.queue, seam::QUEUE);
    let request = seam::Request::decode(&job.payload).unwrap();
    let verified = request.validate().unwrap();
    assert_eq!((verified.op, verified.q.as_deref(), verified.limit), (seam::Op::Search, Some("boleto"), 5));
    // The same question is the same job: asking again does not queue a second scan.
    let again = ask_in(&queue, seam::Op::Search, &args, 1);
    assert_eq!(again["id"].as_u64(), Some(id));
}

#[test]
fn the_answer_the_component_settled_is_the_tool_answer() {
    let (_host, queue) = queue("settled");
    let args = serde_json::json!({"chat": "5511999999999@lid", "limit": 3});
    let slow = ask_in(&queue, seam::Op::Read, &args, 1);
    assert_eq!(slow["error"], "whatsapp_read_slow");
    // The component's side: take the job, answer it, settle.
    let wa_queue::TakeOutcome::Job(taken) = queue.take(seam::QUEUE, "wa-whatsapp", None).unwrap() else {
        panic!("the job must be takeable");
    };
    let answer = seam::answer(
        seam::Op::Read,
        serde_json::json!({"chat": "5511999999999@lid", "messages": [{"id": "3EB01", "text": "oi"}], "count": 1}),
    );
    queue.done_by(taken.id, "wa-whatsapp", &serde_json::to_vec(&answer).unwrap()).unwrap();
    // Now the same call reads the answer instead of the queue.
    let answer = ask_in(&queue, seam::Op::Read, &args, 2_000);
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["op"], "read");
    assert_eq!(answer["messages"][0]["id"], "3EB01");
}

#[test]
fn a_dead_job_answers_with_its_reason_and_not_with_a_success() {
    let (_host, queue) = queue("dead");
    let request = seam::Request { op: "media".into(), chat: Some("5511999999999@lid".into()), id: Some("3EB01".into()), ..Default::default() };
    let verified = request.validate().unwrap();
    // One attempt only, so a failure is final and the tool's answer is the refusal.
    queue
        .enqueue(EnqueueRequest::new(seam::QUEUE, verified.to_request().encode()).fresh_for(seam::FRESH_MS).max_attempts(1).dedupe(verified.dedupe_key()))
        .unwrap();
    let wa_queue::TakeOutcome::Job(taken) = queue.take(seam::QUEUE, "wa-whatsapp", None).unwrap() else {
        panic!("the job must be takeable");
    };
    queue.fail_by(taken.id, "wa-whatsapp", "permanent:not_indexed").unwrap();
    let answer = ask_in(&queue, seam::Op::Media, &serde_json::json!({"chat": "5511999999999@lid", "id": "3EB01"}), 1);
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["error"], "whatsapp_media_failed");
    assert_eq!(answer["state"], "dead");
    assert!(answer["detail"].as_str().unwrap().contains("not_indexed"), "{answer}");
}

#[test]
fn a_bad_argument_is_refused_before_the_queue() {
    let (_host, queue) = queue("refusal");
    for (op, args, code) in [
        (seam::Op::Search, serde_json::json!({}), "whatsapp_search_empty_query"),
        (seam::Op::Read, serde_json::json!({"chat": "5511999999999"}), "whatsapp_read_bad_chat"),
        (seam::Op::Reactions, serde_json::json!({"chat": "5511999999999@lid"}), "whatsapp_reactions_chat_and_id_required"),
        (seam::Op::Download, serde_json::json!({"chat": "5511999999999@lid", "id": "3EB0 X"}), "whatsapp_download_bad_id"),
    ] {
        let answer = ask_in(&queue, op, &args, 50);
        assert_eq!(answer["error"], code, "{op:?} {args}");
        assert_eq!(answer["effect"], "none");
    }
    // Nothing was written for a request that never validated.
    assert_eq!(queue.stats(seam::QUEUE).unwrap().ready, 0);
}

#[test]
fn a_download_reads_the_last_attempts_chunks_and_checks_the_hash() {
    let (_host, queue) = queue("download");
    let request = seam::Request { op: "download".into(), chat: Some("5511999999999@lid".into()), id: Some("I1".into()), ..Default::default() };
    let verified = request.validate().unwrap();
    queue
        .enqueue(EnqueueRequest::new(seam::QUEUE, verified.to_request().encode()).fresh_for(seam::FRESH_MS).max_attempts(seam::MAX_ATTEMPTS))
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
    };
    // A failed first attempt, then the real one: progress is append-only, so both are stored.
    queue.progress(wa_queue::JobId(1), &seam::download_header(1)).unwrap();
    queue.progress(wa_queue::JobId(1), b"half a fi").unwrap();
    queue.progress(wa_queue::JobId(1), &seam::download_header(1)).unwrap();
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
