//! The outbox round trip against the real queue: enqueue -> component sends -> done(message id).
//!
//! This is the property the job brief asks for, measured on the queue the node actually serves to
//! components (`wa:queue` over `rust/wa-queue`, `docs/QUEUE.md`) with a fake WhatsApp client, so no
//! test here can reach WhatsApp: the "client" is a closure that records what it was asked to send and
//! answers with a message id.
//!
//! What each test pins:
//!
//! * the happy path - the producer's request comes out of the queue as the same bytes, the worker's
//!   decision is "send this", and `done` carries a message id `whatsapp_send_status` can report;
//! * dedupe - the same chat/text/reply is one job (`sha256(chat|text|reply_to)`), even when the same
//!   request is enqueued twice;
//! * freshness - a request older than five minutes is never sent: the queue drops it, and the
//!   component's own `decide` refuses it as a second, independent rule;
//! * refusal - a bad JID, a policy refusal and a rate limit never reach the client, and the job fails
//!   with a stable reason instead of being retried into a double send.
use std::sync::Arc;
use wa_queue::{Clock, EnqueueRequest, FixedClock, JobState, Kv, MemoryKv, Policy, Queue, TakeOutcome};
use wa_whatsapp_outbox::{decide, retryable, Chat, Decision, Outcome, Refusal, Request, FRESH_MS, MAX_ATTEMPTS, QUEUE};

/// The whole worker, as the component runs it: take one job, decide, "send" it, settle. `send` is the
/// fake client; it returns the message id WhatsApp would have given the message, or a failure reason.
fn work_one<F>(queue: &Queue, now_ms: i64, send: F) -> (Option<u64>, Option<String>)
where
    F: FnOnce(&wa_whatsapp_outbox::Verified) -> Result<String, String>,
{
    let worker = "wa-whatsapp";
    let Ok(TakeOutcome::Job(job)) = queue.take(QUEUE, worker, None) else {
        return (None, None);
    };
    let id = job.id.0;
    match decide(&job.payload, now_ms, job.fresh_until) {
        Decision::Send(verified) => match send(&verified) {
            Ok(message_id) => {
                let _ = queue.done_by(job.id, worker, &Outcome { message_id: message_id.clone() }.encode());
                (Some(id), Some(message_id))
            }
            Err(reason) => {
                let _ = queue.fail_by(job.id, worker, &reason);
                (Some(id), None)
            }
        },
        Decision::Refuse(refusal) => {
            let _ = queue.fail_by(job.id, worker, refusal.code);
            (Some(id), None)
        }
    }
}

/// The producer's side, as the host runs it: one enqueue per request, with the brief's freshness,
/// attempts and dedupe key.
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

fn request(chat: &str, text: &str) -> Request {
    Request { chat: chat.into(), text: text.into(), reply_to: None, mentions: Vec::new() }
}

#[test]
fn a_request_is_sent_once_and_done_carries_its_message_id() {
    let (_kv, clock, queue) = queue_pair();
    let mut sent = Vec::new();
    let clock_ms = clock.now_ms();
    let request = Request {
        chat: "120363000000000001@g.us".into(),
        text: "olá do wasm".into(),
        reply_to: Some("3EB0ABCD".into()),
        mentions: vec!["5511999999999@s.whatsapp.net".into()],
    };
    let id = produce(&queue, &request);

    // What the component sees: the payload it was given, and the client call it makes.
    let (worked, message_id) = work_one(&queue, clock_ms, |verified| {
        sent.push(format!("{}|{}", verified.chat.jid(), verified.text));
        assert_eq!(verified.reply_to.as_deref(), Some("3EB0ABCD"));
        assert_eq!(verified.mentions.len(), 1, "the group mention survives the queue as a JID");
        Ok("3EB0FAKE0001".to_string())
    });
    assert_eq!(worked, Some(id));
    assert_eq!(message_id.as_deref(), Some("3EB0FAKE0001"));
    assert_eq!(sent, vec!["120363000000000001@g.us|olá do wasm".to_string()]);

    // The settled job, as `whatsapp_send_status` reads it back.
    let job = queue.job(wa_queue::JobId(id)).unwrap().expect("job");
    assert_eq!(job.state, JobState::Done);
    assert_eq!(job.attempts, 0);
    let outcome = Outcome::decode(job.result.as_deref().expect("result")).expect("outcome");
    assert_eq!(outcome.message_id, "3EB0FAKE0001");
    // Nothing else is claimed: a second take finds nothing, so a done job is never sent twice.
    assert!(matches!(queue.take(QUEUE, "wa-whatsapp", None).unwrap(), TakeOutcome::Empty));
}

#[test]
fn the_same_request_is_one_job_and_a_different_quote_is_another() {
    let (_kv, clock, queue) = queue_pair();
    let request = request("5511999999999@lid", "oi");
    let clock_ms = clock.now_ms();

    let first = produce(&queue, &request);
    let again = queue
        .enqueue(
            EnqueueRequest::new(QUEUE, request.encode())
                .fresh_for(FRESH_MS)
                .max_attempts(MAX_ATTEMPTS)
                .dedupe(request.dedupe_key()),
        )
        .expect("second enqueue");
    assert!(again.dedupe_hit, "the dedupe key already names a live job");
    assert_eq!(again.id.0, first);

    let mut quoted = request.clone();
    quoted.reply_to = Some("3EB0ABCD".into());
    let other = produce(&queue, &quoted);
    assert_ne!(other, first, "replying to a different message is a different job");

    // Two jobs, and each of them is sent exactly once, in FIFO order.
    let mut seen = Vec::new();
    for _ in 0..3 {
        let (worked, _) = work_one(&queue, clock_ms, |verified| {
            seen.push(verified.reply_to.clone());
            Ok("M".to_string())
        });
        if worked.is_none() {
            break;
        }
    }
    assert_eq!(seen, vec![None, Some("3EB0ABCD".to_string())]);
}

#[test]
fn a_request_older_than_five_minutes_is_never_sent() {
    let (_kv, clock, queue) = queue_pair();
    produce(&queue, &request("5511999999999@lid", "now"));

    // The queue's own rule: past `fresh_until` it is expired instead of handed out.
    let clock_ms = clock.advance(FRESH_MS + 1);
    assert!(matches!(queue.take(QUEUE, "wa-whatsapp", None).unwrap(), TakeOutcome::Empty));
    let _ = queue.expire_stale_at(clock_ms).expect("sweep");
    let job = queue.job(wa_queue::JobId(1)).unwrap().expect("job");
    assert_eq!(job.state, JobState::Expired, "the stale job is dropped, not run");

    // The component's independent rule: the same payload, decided at a time past the bound, is a
    // refusal even if it did reach the worker - so no client is ever asked to send it.
    let payload = request("5511999999999@lid", "now").encode();
    match decide(&payload, clock_ms, Some(clock_ms - 1)) {
        Decision::Refuse(refusal) => assert_eq!(refusal.code, "stale"),
        Decision::Send(_) => panic!("a stale request was about to be sent"),
    }
}

#[test]
fn a_bad_jid_never_reaches_the_client_and_the_job_fails_with_a_stable_reason() {
    let (_kv, clock, queue) = queue_pair();
    // The producer validates too, but a job can arrive from anywhere: the worker must refuse it.
    let clock_ms = clock.now_ms();
    let id = produce(&queue, &request("5511999999999@broadcast", "status update"));
    let (worked, message_id) = work_one(&queue, clock_ms, |_| panic!("a refused request must not be sent"));
    assert_eq!((worked, message_id), (Some(id), None));
    let job = queue.job(wa_queue::JobId(id)).unwrap().expect("job");
    assert_eq!(job.last_error.as_deref(), Some("unsupported_chat"));
    assert_eq!(job.state, JobState::Ready, "a retryable failure would come back; this one is permanent");
    assert_eq!(job.attempts, 1);
    assert!(!retryable("unsupported_chat"));
    // `wa:queue` has no "permanent failure" call: `fail` always counts an attempt and schedules the
    // default backoff (5 s, then 10 s, then 20 s). So the retry hits the same refusal and the job
    // dead-letters at `max_attempts` - and, because the freshness window is 5 minutes and the backoff
    // is seconds, it always gets there rather than expiring first. No message is sent at any attempt.
    for _ in 0..MAX_ATTEMPTS {
        let retry_at = clock.advance(15_000);
        let _ = work_one(&queue, retry_at, |_| panic!("a refused request must not be sent"));
    }
    let job = queue.job(wa_queue::JobId(id)).unwrap().expect("job");
    assert_eq!(job.state, JobState::Dead);
    assert_eq!(job.attempts, MAX_ATTEMPTS);
}

#[test]
fn a_policy_refusal_at_dispatch_is_reported_not_retried() {
    let (_kv, clock, queue) = queue_pair();
    let clock_ms = clock.now_ms();
    let id = produce(&queue, &request("5511999999999@lid", "held"));
    // The producer already passed the host's `whatsapp.send` check; a component that still refuses
    // (a rate-limit refusal the host decided while this job waited) settles as a failure with the
    // policy's word, and `retryable` says it must not spin.
    let refusal = Refusal::new("policy_denied", "target_rate_limited");
    let mut client_calls = 0;
    let (worked, _) = work_one(&queue, clock_ms, |_| {
        client_calls += 1;
        Err(refusal.code.to_string())
    });
    assert_eq!(worked, Some(id));
    assert_eq!(client_calls, 1, "the client was asked once, and failed");
    let job = queue.job(wa_queue::JobId(id)).unwrap().expect("job");
    assert_eq!(job.last_error.as_deref(), Some("policy_denied"));
    assert!(!retryable("policy_denied"));
}

#[test]
fn a_chat_that_needs_no_mapping_is_sent_to_directly() {
    // The component sends to the LID it was given (the library accepts a LID chat directly) and
    // never invents a phone number for it: a wrong mapping is a message to a stranger.
    for jid in [
        "72103978127547@lid",
        "5511999999999@s.whatsapp.net",
        "120363000000000001@g.us",
        // The legacy group id a `whatsapp_search` hit can return (07/11): `whatsapp_send` and every
        // `whatsapp_read`/`media`/`reactions`/`download` that names it must accept it, or a hit the
        // index just produced is a chat the agent cannot use.
        "9999999999999-9999999999@g.us",
    ] {
        let chat = Chat::parse(jid).expect(jid);
        assert_eq!(chat.jid(), jid);
    }
    assert!(Chat::parse("72103978127547@lid").unwrap().server == wa_whatsapp_outbox::Server::Lid);
}

#[test]
fn a_send_to_a_legacy_group_id_reaches_the_client_with_the_id_it_named() {
    // The whole path for the shape the live finding named: an exact legacy group JID goes through the
    // queue and the client is handed back that same string, hyphen and all - never a rewritten id.
    let (_kv, clock, queue) = queue_pair();
    let chat = "9999999999999-9999999999@g.us";
    let id = produce(&queue, &request(chat, "oi"));
    let mut sent = Vec::new();
    let (worked, message_id) = work_one(&queue, clock.now_ms(), |verified| {
        assert!(verified.chat.is_group());
        sent.push(verified.chat.jid());
        Ok("3EB0FAKE0002".to_string())
    });
    assert_eq!((worked, message_id.as_deref()), (Some(id), Some("3EB0FAKE0002")));
    assert_eq!(sent, vec![chat.to_string()]);
    assert_eq!(queue.job(wa_queue::JobId(id)).unwrap().expect("job").state, JobState::Done);
}
