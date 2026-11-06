//! The query round trip against the real queue: enqueue -> component answers -> done(answer).
//!
//! Measured on the queue the node actually serves to components (`wa:queue` over `rust/wa-queue`,
//! `docs/QUEUE.md`), with the index replaced by a fake: the point here is the seam - the request that
//! goes in, the answer that comes out, the dedupe that makes a retried tool call one job, the
//! freshness that never answers a question that has gone stale, and the size bound that keeps an
//! answer inside the queue's own result cap instead of failing the settle.
//!
//! No test here touches WhatsApp or the component: the "component" is a closure that turns a taken
//! request into an answer, exactly as `wa-whatsapp`'s query tick does.
use std::sync::Arc;
use wa_queue::{Clock, EnqueueRequest, FixedClock, Kv, MemoryKv, Policy, Queue, TakeOutcome};
use wa_whatsapp_index::{answer, bound, refusal, Op, Request, FRESH_MS, MAX_ATTEMPTS, MAX_RESULT_BYTES, QUEUE};

/// The producer's side, as the node's capability runs it: one enqueue per request, with the queue's
/// freshness/attempts and the request itself as the dedupe key.
fn produce(queue: &Queue, request: &Request) -> u64 {
    queue
        .enqueue(
            EnqueueRequest::new(QUEUE, request.encode())
                .fresh_for(FRESH_MS)
                .max_attempts(MAX_ATTEMPTS)
                .dedupe(request.dedupe_key()),
        )
        .expect("enqueue")
        .id
        .0
}

/// The component's side: take one job, validate the payload it took, answer, settle.
fn work_one<F>(queue: &Queue, now_ms: i64, answer_it: F) -> Option<u64>
where
    F: FnOnce(&wa_whatsapp_index::Verified) -> serde_json::Value,
{
    let worker = "wa-whatsapp";
    let Ok(TakeOutcome::Job(job)) = queue.take(QUEUE, worker, None) else { return None };
    let id = job.id.0;
    // A job can go stale between `take` and dispatch; a stale question is never answered late.
    if job.fresh_until.is_some_and(|fresh| fresh <= now_ms) {
        let _ = queue.fail_by(job.id, worker, "stale");
        return Some(id);
    }
    match Request::decode(&job.payload).and_then(|request| request.validate()) {
        Ok(verified) => {
            let answer = answer_it(&verified);
            let _ = queue.done_by(job.id, worker, &serde_json::to_vec(&answer).unwrap_or_default());
        }
        Err(refusal) => {
            let _ = queue.fail_by(job.id, worker, refusal.code);
        }
    }
    Some(id)
}

fn queue_pair() -> (Arc<MemoryKv>, Arc<FixedClock>, Queue) {
    let kv = Arc::new(MemoryKv::new());
    let clock = Arc::new(FixedClock::new(1_000_000));
    let queue = Queue::new(
        Arc::clone(&kv) as Arc<dyn Kv>,
        Arc::clone(&clock) as Arc<dyn Clock>,
        Policy { default_fresh_ms: None, ..Policy::default() },
    );
    (kv, clock, queue)
}

fn search(q: &str) -> Request {
    Request { op: "search".into(), q: Some(q.into()), ..Request::default() }
}

#[test]
fn a_search_goes_in_as_a_request_and_comes_out_as_the_answer() {
    let (_kv, _clock, queue) = queue_pair();
    let id = produce(&queue, &search("boleto"));
    let handled = work_one(&queue, 1_000_000, |verified| {
        assert_eq!((verified.op, verified.q.as_deref()), (Op::Search, Some("boleto")));
        answer(Op::Search, serde_json::json!({"hits": [{"chat": "5511999999999@lid", "id": "3EB01", "text": "o boleto vence amanhã"}], "count": 1}))
    });
    assert_eq!(handled, Some(id));
    let job = queue.job(wa_queue::JobId(id)).unwrap().unwrap();
    assert_eq!(job.state.as_str(), "done");
    let settled: serde_json::Value = serde_json::from_slice(job.result.as_deref().unwrap()).unwrap();
    assert_eq!(settled["ok"], true);
    assert_eq!(settled["op"], "search");
    assert_eq!(settled["hits"][0]["id"], "3EB01");
}

#[test]
fn a_backfill_goes_in_as_a_request_and_comes_out_as_what_was_asked_for() {
    // The sixth op travels the same queue as the other five: the answer is the request list (chat,
    // anchor, count), never a message - the messages arrive later through the protocol.
    let (_kv, _clock, queue) = queue_pair();
    let request = Request {
        op: "backfill".into(),
        chat: Some("120363000000000001@g.us".into()),
        limit: Some(120),
        ..Request::default()
    };
    let id = produce(&queue, &request);
    let handled = work_one(&queue, 1_000_000, |verified| {
        assert_eq!((verified.op, verified.limit), (Op::Backfill, 120));
        answer(
            Op::Backfill,
            wa_whatsapp_index::backfill_answer(
                vec![wa_whatsapp_index::BackfillChat {
                    chat: verified.chat.as_ref().map(|chat| chat.jid()).unwrap_or_default(),
                    count: verified.limit,
                    oldest_id: "3EB0OLDEST".into(),
                    oldest_ts: 1_700_000_000_000,
                }],
                "asked the primary phone for 120 older messages",
            ),
        )
    });
    assert_eq!(handled, Some(id));
    let job = queue.job(wa_queue::JobId(id)).unwrap().unwrap();
    assert_eq!(job.state.as_str(), "done");
    let settled: serde_json::Value = serde_json::from_slice(job.result.as_deref().unwrap()).unwrap();
    assert_eq!(settled["op"], "backfill");
    assert_eq!(settled["count"], 1);
    assert_eq!(settled["chats"][0]["count"], 120);
    assert_eq!(settled["chats"][0]["oldest_id"], "3EB0OLDEST");
    // A different count is a different question, so it is a different job.
    assert_ne!(id, produce(&queue, &Request { limit: Some(50), ..request }));
}

#[test]
fn the_same_question_is_one_job() {
    let (_kv, _clock, queue) = queue_pair();
    let first = produce(&queue, &search("boleto"));
    let second = produce(&queue, &search("boleto"));
    let other = produce(&queue, &search("boleta"));
    assert_eq!(first, second, "a retried tool call reads the first job");
    assert_ne!(first, other);
    // And the answer the first call produced is still there for the second to read.
    work_one(&queue, 1_000_000, |_| answer(Op::Search, serde_json::json!({"hits": [], "count": 0})));
    let job = queue.job(wa_queue::JobId(first)).unwrap().unwrap();
    assert_eq!(job.state.as_str(), "done");
}

#[test]
fn a_question_that_waited_too_long_is_never_answered() {
    let (_kv, clock, queue) = queue_pair();
    produce(&queue, &search("boleto"));
    // The queue itself drops a job past `fresh_until` instead of handing it out.
    clock.advance(FRESH_MS + 1);
    let late = queue.take(QUEUE, "wa-whatsapp", None).map(|outcome| matches!(outcome, TakeOutcome::Empty));
    assert!(matches!(late, Ok(true)), "a stale job is not takeable");
    // And the component's own check refuses it a second time, independently of the queue.
    let (_kv2, _clock2, queue2) = queue_pair();
    produce(&queue2, &search("boleto"));
    // This clock is left alone: the job is taken while the queue still thinks it is fresh, so the
    // component's own freshness check is what refuses it (`now_ms` below is past the window).
    let handler = |_verified: &wa_whatsapp_index::Verified| {
        panic!("a stale question must not be answered")
    };
    assert_eq!(work_one(&queue2, 1_000_000 + FRESH_MS + 1, handler), Some(1));
    let job = queue2.job(wa_queue::JobId(1)).unwrap().unwrap();
    assert_ne!(job.state.as_str(), "done");
    assert_eq!(job.last_error.as_deref(), Some("stale"));
    // The retry the queue allows lands on the same refusal: the handler above runs only when the
    // payload validates *and* is fresh, so no attempt ever answers a stale question.
    assert_eq!(job.state.as_str(), "ready", "the queue's retry budget is spent on the same refusal");
}

#[test]
fn a_request_the_worker_cannot_read_fails_with_its_code_and_is_not_retried_into_an_answer() {
    let (_kv, _clock, queue) = queue_pair();
    queue
        .enqueue(EnqueueRequest::new(QUEUE, b"{\"op\":\"rm -rf\"}".to_vec()).fresh_for(FRESH_MS).max_attempts(1))
        .unwrap();
    work_one(&queue, 1_000_000, |_| panic!("a bad payload is never answered"));
    let job = queue.job(wa_queue::JobId(1)).unwrap().unwrap();
    assert_eq!(job.state.as_str(), "dead");
    assert_eq!(job.last_error.as_deref(), Some("bad_op"));
}

#[test]
fn an_answer_too_big_for_one_result_is_bounded_before_it_is_settled() {
    // `wa:queue` refuses a result over its `max_result_bytes` and leaves the job leased; a query that
    // found too much must therefore be a smaller answer, not a failed settle.
    let (_kv, _clock, queue) = queue_pair();
    produce(&queue, &Request { op: "read".into(), chat: Some("5511999999999@lid".into()), limit: Some(100), ..Request::default() });
    let hits: Vec<serde_json::Value> = (0..4000)
        .map(|i| serde_json::json!({"chat": "5511999999999@lid", "id": format!("3EB0{i:05}"), "text": "x".repeat(240)}))
        .collect();
    work_one(&queue, 1_000_000, |verified| answer(Op::Read, serde_json::json!({"messages": hits, "count": 4000, "chat": verified.chat.as_ref().map(|c| c.jid())})));
    let job = queue.job(wa_queue::JobId(1)).unwrap().unwrap();
    assert_eq!(job.state.as_str(), "done", "an oversized answer still settles: {:?}", job.last_error);
    let result = job.result.as_deref().unwrap();
    assert!(result.len() <= MAX_RESULT_BYTES, "{} bytes", result.len());
    let settled: serde_json::Value = serde_json::from_slice(result).unwrap();
    assert_eq!(settled["truncated"], true);
    assert_eq!(settled["ok"], true);
    assert_eq!(settled["count"], settled["messages"].as_array().unwrap().len());
}

#[test]
fn a_refusal_is_a_word_with_no_text_and_no_effect() {
    let bad = Request { op: "reactions".into(), chat: Some("5511999999999@lid".into()), ..Request::default() };
    let refusal = bad.validate().expect_err("no id");
    assert_eq!(refusal.error(Op::Reactions), "whatsapp_reactions_chat_and_id_required");
    let answer = refusal_answer(refusal.code);
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["effect"], "none");
    assert!(!answer.to_string().contains("boleto"));
}

fn refusal_answer(code: &str) -> serde_json::Value {
    refusal(Op::Reactions, code, "one message: pass chat and id")
}

#[test]
fn bounding_an_already_small_answer_changes_nothing() {
    let small = answer(Op::Media, serde_json::json!({"media": {"mime": "image/jpeg"}, "count": 1}));
    assert_eq!(bound(small.clone()), small);
}
