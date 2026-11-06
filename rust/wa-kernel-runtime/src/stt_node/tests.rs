//! The producing side, executable: one in-memory queue and the calls a worker would make on the
//! wire. No recognizer and no threads — the library's simulation already proves the decode loop and
//! `scripts/test-stt-two-nodes.sh` proves two real processes; what is testable here is the host's
//! own half: admission, dispatch, the audio's lease rule, the component slot, the operator view.

use super::*;
use wa_kv::{MemoryStore, Namespaced};
use wa_stt_remote::protocol::DEFAULT_SKEW_MS;

fn runtime() -> Arc<Runtime> {
    let queue = Arc::new(Namespaced::new(Arc::new(MemoryStore::new()), "q/"));
    let audio = Arc::new(Namespaced::new(Arc::new(MemoryStore::new()), "a/"));
    let runtime = Runtime::new(queue, audio);
    set_config_for_test(
        &runtime,
        Config {
            me: "producer".into(),
            owner_nodes: vec!["producer".into(), "worker".into()],
            produce: true,
            work: false,
            ..Config::default()
        },
    );
    runtime
}

fn submission(audio: Vec<u8>) -> Submission {
    Submission {
        audio,
        mime: Mime::Ogg,
        language: "pt".into(),
        account: "acct".into(),
        generation: 7,
        chat: "chat".into(),
        msg: "note-1".into(),
        sent_at_ms: None,
        declared_seconds: Some(3),
    }
}

fn envelope(op: Op, from: &str, rid: &str, ts_ms: i64, body: Value) -> String {
    let envelope = Envelope::new(op, from, "producer", ts_ms, rid, body);
    String::from_utf8_lossy(&envelope.encode()).to_string()
}

fn take(worker: &str) -> Value {
    json!({"queue": QUEUE, "worker": worker, "lease_ms": 60_000, "wait_ms": 0})
}

fn reply(value: &str) -> Value {
    serde_json::from_str(value).expect("a reply is JSON")
}

fn slot() -> service_stt::JobSlot {
    service_stt::new_slot()
}

fn slot_state(slot: &service_stt::JobSlot) -> service_stt::JobState {
    slot.lock().unwrap().state.clone()
}

#[test]
fn a_worker_takes_streams_segments_and_settles_the_job() {
    let runtime = runtime();
    let waiter = slot();
    let job = enqueue_on(&runtime, submission(b"ogg-bytes".to_vec()), Some(waiter.clone())).expect("enqueued");
    let now = SystemClock.now_ms();

    let taken = reply(&call_on(&runtime, &envelope(Op::Take, "worker", "r1", now, take("stt:worker")), "worker"));
    assert_eq!(taken["ok"]["taken"]["job"], json!(job), "the worker is handed the job: {taken}");
    assert_eq!(taken["ok"]["taken"]["chat"], json!("chat"), "the request travels inline in the take reply: {taken}");
    assert!(taken["ok"]["taken"].get("text").is_none(), "a request has no text field");

    let segment = json!({"job": job, "worker": "stt:worker", "segment": {"start_ms": 0, "end_ms": 900, "text": "olá"}});
    let progressed = reply(&call_on(&runtime, &envelope(Op::Progress, "worker", "r2", now, segment), "worker"));
    assert_eq!(progressed["ok"]["seq"], json!(0), "progress is accepted while the lease is held");
    assert_eq!(waiter.lock().unwrap().segments, vec!["olá"], "the component slot saw the segment");

    let transcript = json!({"text": "olá mundo", "language": "pt", "segments": 2, "elapsed_ms": 1234});
    let done = reply(&call_on(
        &runtime,
        &envelope(Op::Done, "worker", "r3", now, json!({"job": job, "worker": "stt:worker", "transcript": transcript})),
        "worker",
    ));
    assert_eq!(done["ok"]["settled"], json!(true), "{done}");
    assert_eq!(
        slot_state(&waiter),
        service_stt::JobState::Done { text: "olá mundo".into(), elapsed_ms: 1234 },
        "the component's slot is the job's result"
    );

    let again = reply(&call_on(
        &runtime,
        &envelope(Op::Done, "worker", "r4", now, json!({"job": job, "worker": "stt:worker", "transcript": transcript})),
        "worker",
    ));
    assert_eq!(again["refused"], json!("lease_lost"), "a second settle is refused, not counted twice");
}

#[test]
fn only_the_owner_s_own_nodes_are_admitted_and_each_call_once() {
    let runtime = runtime();
    let now = SystemClock.now_ms();
    let body = take("stt:worker");

    let stranger = reply(&call_on(&runtime, &envelope(Op::Take, "stranger", "r1", now, body.clone()), "stranger"));
    assert_eq!(stranger["refused"], json!("unknown_caller"));

    let wrong_target = Envelope::new(Op::Take, "worker", "somebody-else", now, "r2", body.clone());
    let answered = reply(&call_on(&runtime, &String::from_utf8_lossy(&wrong_target.encode()), "worker"));
    assert_eq!(answered["refused"], json!("wrong_target"));

    let stale = reply(&call_on(&runtime, &envelope(Op::Take, "worker", "r3", now - DEFAULT_SKEW_MS - 1, body.clone()), "worker"));
    assert_eq!(stale["refused"], json!("stale_request"));

    let first = reply(&call_on(&runtime, &envelope(Op::Take, "worker", "r4", now, body.clone()), "worker"));
    assert!(first.get("ok").is_some(), "an honest call from an owner's node is answered: {first}");
    let replay = reply(&call_on(&runtime, &envelope(Op::Take, "worker", "r4", now, body), "worker"));
    assert_eq!(replay["refused"], json!("replayed_request"), "the same rid is answered once");
}

#[test]
fn a_note_past_its_window_is_refused_and_never_queued() {
    let runtime = runtime();
    let mut late = submission(b"old-bytes".to_vec());
    late.sent_at_ms = Some(SystemClock.now_ms() - 10 * 60 * 1000);
    let refused = enqueue_on(&runtime, late, None);
    assert!(matches!(refused, Err(EnqueueProblem::Stale { .. })), "a stale note is refused at enqueue: {refused:?}");
    let queue = runtime.queue();
    assert_eq!(queue.stats(QUEUE).unwrap().ready, 0, "nothing was stored to be dropped later");
}

#[test]
fn the_audio_behind_a_handle_is_served_only_to_the_lease_holder() {
    let runtime = runtime();
    // Above the inline bound, so the bytes live in the store behind a short-lived handle.
    let big = vec![7u8; wa_stt_remote::request::INLINE_MAX_BYTES + 1];
    let job = enqueue_on(&runtime, submission(big.clone()), None).expect("enqueued");
    let now = SystemClock.now_ms();

    let taken = reply(&call_on(&runtime, &envelope(Op::Take, "worker", "r1", now, take("stt:worker")), "worker"));
    let handle = taken["ok"]["taken"]["audio"]["fetch"]["handle"].as_str().expect("a fetch handle").to_string();
    assert_eq!(taken["ok"]["taken"]["audio"]["fetch"]["bytes"], json!(big.len() as u64));

    let thief = reply(&call_on(
        &runtime,
        &envelope(Op::Audio, "worker", "r2", now, json!({"job": job, "worker": "stt:other", "handle": handle})),
        "worker",
    ));
    assert_eq!(thief["refused"], json!("lease_lost"), "a worker that does not hold the lease is not served");

    let served = reply(&call_on(
        &runtime,
        &envelope(Op::Audio, "worker", "r3", now, json!({"job": job, "worker": "stt:worker", "handle": handle})),
        "worker",
    ));
    let bytes = request::base64_decode(served["ok"]["b64"].as_str().expect("bytes")).expect("base64");
    assert_eq!(bytes.len(), big.len(), "the lease holder gets the bytes it was promised");
}

#[test]
fn a_failure_goes_back_with_the_attempt_count_and_stays_visible() {
    let runtime = runtime();
    let job = enqueue_on(&runtime, submission(b"bytes".to_vec()), None).expect("enqueued");
    let now = SystemClock.now_ms();
    reply(&call_on(&runtime, &envelope(Op::Take, "worker", "r1", now, take("stt:worker")), "worker"));
    let failed = reply(&call_on(
        &runtime,
        &envelope(Op::Fail, "worker", "r2", now, json!({"job": job, "worker": "stt:worker", "reason": "decode:worker_stalled"})),
        "worker",
    ));
    assert_eq!(failed["ok"]["attempts"], json!(1));
    assert_eq!(failed["ok"]["dead"], json!(false));

    let view = admin_on(&runtime, &json!({"action": "job", "job": job}));
    assert_eq!(view["ok"]["state"], json!("ready"), "the job is queued again behind its backoff");
    assert_eq!(view["ok"]["attempts"], json!(1));
    assert_eq!(view["ok"]["last_error"], json!("decode:worker_stalled"), "the failure is visible, one bounded word class");
    assert!(view["ok"].get("text").is_none(), "the job view never carries transcript text");
}

#[test]
fn the_view_names_the_attached_worker_and_the_counts_without_text() {
    let runtime = runtime();
    let waiter = slot();
    let job = enqueue_on(&runtime, submission(b"bytes".to_vec()), Some(waiter)).expect("enqueued");
    let now = SystemClock.now_ms();
    reply(&call_on(&runtime, &envelope(Op::Take, "worker", "r1", now, take("stt:worker")), "worker"));
    reply(&call_on(
        &runtime,
        &envelope(Op::Done, "worker", "r2", now, json!({"job": job, "worker": "stt:worker",
            "transcript": {"text": "canary phrase", "language": "pt", "segments": 1, "elapsed_ms": 400}})),
        "worker",
    ));

    let view = admin_on(&runtime, &json!({"action": "status"}));
    let status = &view["ok"];
    assert_eq!(status["producer"], json!(true));
    assert_eq!(status["worker"], json!(false));
    assert_eq!(status["workers"][0]["worker"], json!("stt:worker"));
    assert_eq!(status["workers"][0]["done"], json!(1));
    assert_eq!(status["remote"]["decoded"], json!(1));
    assert_eq!(status["remote"]["avg_ms"], json!(400));
    assert_eq!(status["recent"][0]["by"], json!("remote"));
    assert_eq!(status["queue"]["done"], json!(1));
    let text = view.to_string();
    assert!(!text.contains("canary phrase"), "the operator view carries ids and durations, never transcript text: {text}");
}

#[test]
fn a_refusal_never_echoes_the_request() {
    let runtime = runtime();
    let now = SystemClock.now_ms();
    let weird = json!({"queue": "stt.requests", "note": "canary phrase"});
    let refused = reply(&call_on(&runtime, &envelope(Op::Take, "worker", "r1", now, weird), "worker"));
    assert_eq!(refused["refused"], json!("malformed:worker"), "the refusal names the field, never its value: {refused}");
    assert!(!refused.to_string().contains("canary"), "a refusal is a fixed word: {refused}");
}

#[test]
fn the_local_worker_decodes_through_the_queue_and_fills_the_component_slot() {
    // The local thread's own path: the library's `LocalWorker` (take, `Decoder`, settle) over this
    // node's queue, with the library's fake recognizer standing in for the warm worker.
    let runtime = runtime();
    let waiter = slot();
    let job = enqueue_on(&runtime, submission(b"bytes".to_vec()), Some(waiter.clone())).expect("enqueued");
    let mut recognizer = wa_stt_remote::sim::FakeRecognizer::new(10, vec!["olá", "mundo"]);
    let outcome = local_poll_for_test(&runtime, &mut recognizer);
    assert!(matches!(outcome, Outcome::Decoded { job: decoded, .. } if decoded == job), "the local worker settled the job: {outcome:?}");
    assert_eq!(recognizer.ran, 1, "the note was decoded once");
    assert_eq!(
        slot_state(&waiter),
        service_stt::JobState::Done { text: "olá mundo".into(), elapsed_ms: 20 },
        "the component's slot is the decoded transcript"
    );
    let queue = runtime.queue();
    assert_eq!(queue.job(JobId(job)).unwrap().unwrap().state, JobState::Done);
}
