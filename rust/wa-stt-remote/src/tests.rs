//! The tests: the payload, the wire, the policy, and the two-node simulation the job asks for.
//!
//! Every test runs on `FixedClock`s moved by hand, so "the remote wins", "the remote dies mid-job" and
//! "a stale job is never decoded" are exact assertions about state and counters, not impressions.

use std::sync::Arc;

use wa_queue::{Clock, FixedClock, JobId, JobState, Queue};

use crate::metrics::{Metrics, Who};
use crate::policy::{Decision, Latency, LocalReason, Preference, RemoteHealth, RemoteReason};
use crate::producer::{Arrival, EnqueueFailure, LocalWorker, Producer, SttPolicy, QUEUE};
use crate::protocol::{Admission, Envelope, Op, Refusal, Reply, TakeBody, TakeReply, TransportSignature};
use crate::request::{AudioSource, Mime, RequestError, SttRequest, INLINE_MAX_BYTES};
use crate::sim::{FakeRecognizer, Relay, SimNode, SimWorker};
use crate::worker::{Decoder, LocalSink, Outcome, Recognizer, RecognizerError, Segment};

const T0: i64 = 1_700_000_000_000;

fn arrival(bytes: usize, sent_at_ms: i64) -> Arrival {
    Arrival {
        audio: vec![7u8; bytes],
        mime: Mime::Ogg,
        language: "pt".into(),
        account: "wa-1".into(),
        generation: 3,
        chat: "5511999999999@s.whatsapp.net".into(),
        msg: "3EB0AAAA1111".into(),
        sent_at_ms,
        declared_seconds: Some(12),
    }
}

fn with_msg(mut arrival: Arrival, msg: &str) -> Arrival {
    arrival.msg = msg.to_string();
    arrival
}

fn enqueue(node: &mut SimNode, arrival: &Arrival, handle: &str) -> Result<wa_queue::EnqueueOutcome, EnqueueFailure> {
    let producer = Producer::new(&node.queue, &node.audio, node.policy.clone(), node.clock.as_ref());
    producer.enqueue(arrival, handle, &mut node.metrics)
}

/// One poll of `node`'s own worker. A free function rather than a method so the queue/audio borrow is
/// on two fields and the counters on a third � `SimNode::local_worker` would borrow the whole node.
fn poll_local(
    node: &mut SimNode,
    preference: &Preference,
    remote: Option<&RemoteHealth>,
    latency: &mut Latency,
    recognizer: &mut dyn Recognizer,
) -> Outcome {
    let worker = LocalWorker { queue: &node.queue, audio: &node.audio, node: node.id.clone(), lease_ms: 60_000, heartbeat_every_ms: 15_000 };
    let clock = node.clock.clone();
    worker.poll_once(preference, remote, latency, recognizer, clock.as_ref(), &mut node.metrics)
}

fn remote_online() -> RemoteHealth {
    RemoteHealth::online(Latency::new())
}

// ---- the payload ---------------------------------------------------------------------------------

#[test]
fn a_request_round_trips_and_never_prints_its_audio() {
    let canary = b"CANARY-AUDIO-BYTES".to_vec();
    let request = SttRequest {
        audio: AudioSource::Inline(canary.clone(), Mime::Ogg),
        language: "pt".into(),
        fresh_until_ms: T0 + 300_000,
        chat: "chat@s.whatsapp.net".into(),
        msg: "3EB0".into(),
        account: "wa-1".into(),
        generation: 7,
        declared_seconds: Some(42),
    };
    let payload = request.encode();
    let decoded = SttRequest::decode(&payload).expect("round trip");
    assert_eq!(decoded, request);
    assert_eq!(decoded.dedupe_key(), "wa-1/7/chat@s.whatsapp.net/3EB0");

    let printed = format!("{decoded:?}");
    assert!(!printed.contains("CANARY"), "the audio never reaches a Debug line: {printed}");
    assert!(printed.contains("inline(18 bytes"), "the size is what a reader gets: {printed}");

    // A fetch handle carries the same rule: ids, size, expiry — never the token's bytes.
    let fetched = SttRequest { audio: AudioSource::Fetch(crate::request::FetchHandle::new("h-9", T0 + 1000, 4096, Mime::Mp3)), ..request.clone() };
    assert_eq!(SttRequest::decode(&fetched.encode()).expect("round trip"), fetched);
    let printed_handle = format!("{:?}", fetched.audio);
    assert!(printed_handle.contains("4096 bytes"), "{printed_handle}");
    assert!(!printed_handle.contains("h-9"), "the token itself is not printed: {printed_handle}");
}

#[test]
fn a_payload_carrying_text_is_refused() {
    // The strict key set is the privacy rule made mechanical: there is no field a transcript could
    // travel in, and an unknown one is a refusal rather than something silently dropped.
    let mut value: serde_json::Value = serde_json::from_slice(&arrival_request().encode()).unwrap();
    value["text"] = serde_json::json!("olá, isto é uma transcrição");
    let refused = SttRequest::decode(value.to_string().as_bytes()).unwrap_err();
    assert_eq!(refused, RequestError::Malformed("unknown_field"));

    let other = serde_json::json!({"v": 2, "audio": {"inline": {"mime": "audio/ogg", "b64": "AA=="}}});
    assert_eq!(SttRequest::decode(other.to_string().as_bytes()).unwrap_err(), RequestError::UnsupportedVersion(2));

    let oversized = serde_json::json!({
        "v": 1,
        "audio": {"inline": {"mime": "audio/ogg", "b64": "A".repeat(4 * (INLINE_MAX_BYTES / 3 + 2))}},
        "language": "pt", "fresh_until_ms": T0, "chat": "c", "msg": "m", "account": "a", "generation": 0,
    });
    assert!(matches!(SttRequest::decode(oversized.to_string().as_bytes()).unwrap_err(), RequestError::TooLarge("audio.inline")));
}

fn arrival_request() -> SttRequest {
    SttRequest {
        audio: AudioSource::Inline(vec![1, 2, 3], Mime::Ogg),
        language: "pt".into(),
        fresh_until_ms: T0 + 1000,
        chat: "c".into(),
        msg: "m".into(),
        account: "a".into(),
        generation: 0,
        declared_seconds: None,
    }
}

#[test]
fn base64_round_trips_and_refuses_junk() {
    for len in [0usize, 1, 2, 3, 4, 5, 255, 1000] {
        let bytes: Vec<u8> = (0..len).map(|index| (index % 251) as u8).collect();
        let encoded = crate::request::base64_encode(&bytes);
        assert_eq!(crate::request::base64_decode(&encoded).expect("decode"), bytes, "len {len}");
    }
    assert_eq!(crate::request::base64_encode(b"Man"), "TWFu");
    assert_eq!(crate::request::base64_decode("TWE").unwrap(), b"Ma");
    assert_eq!(crate::request::base64_decode("TWE=").unwrap(), b"Ma");
    assert!(crate::request::base64_decode("TW$=").is_none());
    assert!(crate::request::base64_decode("T").is_none());
    assert!(crate::request::base64_decode("TQ==TQ==").is_none(), "data after padding is not base64 of a byte string");
}

// ---- the producer's own rules ---------------------------------------------------------------------

#[test]
fn a_note_is_enqueued_once_and_never_after_its_window() {
    let mut node = SimNode::producer("openclaw", T0, &["strong"]);
    let first = enqueue(&mut node, &arrival(1000, T0), "h-1").expect("enqueued");
    assert!(!first.dedupe_hit);
    let again = enqueue(&mut node, &arrival(1000, T0), "h-2").expect("dedupe answers, does not fail");
    assert!(again.dedupe_hit, "the same (account, generation, chat, msg) is one job");
    assert_eq!(again.id, first.id);
    assert_eq!(node.queue.stats(QUEUE).unwrap().ready, 1, "one job, not two");
    assert_eq!(node.metrics.enqueued, 1);

    // A deduplicated note does not leave its blob behind: the second call wrote one, and the job it
    // lost to already has its own handle.
    let first_big = enqueue(&mut node, &with_msg(arrival(INLINE_MAX_BYTES + 100, T0), "big"), "h-big-1").expect("enqueued");
    assert!(!first_big.dedupe_hit);
    assert_eq!(node.audio.len(), 1);
    let again_big = enqueue(&mut node, &with_msg(arrival(INLINE_MAX_BYTES + 100, T0), "big"), "h-big-2").expect("dedupe answers");
    assert!(again_big.dedupe_hit);
    assert_eq!(node.audio.len(), 1, "the second blob was deleted, the first job's audio stays");
    assert!(node.audio.contains("h-big-1") && !node.audio.contains("h-big-2"));

    // Past the window on arrival: stored, it could only be dropped, so it is refused here instead.
    let late = arrival(1000, T0 - 300_001);
    assert_eq!(enqueue(&mut node, &late, "h-3"), Err(EnqueueFailure::Stale { fresh_until_ms: T0 - 1 }));
    assert_eq!(node.metrics.stale_dropped, 1);
}

#[test]
fn a_big_note_goes_to_the_store_behind_a_handle_and_a_small_one_stays_inline() {
    let mut node = SimNode::producer("openclaw", T0, &["strong"]);
    let big = enqueue(&mut node, &arrival(INLINE_MAX_BYTES + 1, T0), "h-big").expect("enqueued");
    let small = enqueue(&mut node, &with_msg(arrival(1000, T0), "small"), "h-small").expect("enqueued");

    let big_payload = node.queue.job(big.id).unwrap().unwrap().payload;
    let small_payload = node.queue.job(small.id).unwrap().unwrap().payload;
    assert!(big_payload.len() < 1024, "a 256 KiB note must not sit in the queue payload ({} bytes)", big_payload.len());
    assert!(matches!(SttRequest::decode(&big_payload).unwrap().audio, AudioSource::Fetch(_)));
    assert!(matches!(SttRequest::decode(&small_payload).unwrap().audio, AudioSource::Inline(..)));
    assert_eq!(node.audio.len(), 1, "only the big blob is in the store");
}

#[test]
fn audio_is_only_served_to_the_worker_holding_the_lease() {
    let mut node = SimNode::producer("openclaw", T0, &["strong"]);
    let enqueued = enqueue(&mut node, &arrival(INLINE_MAX_BYTES + 10, T0), "h-audio").expect("enqueued");
    let job = enqueued.id;
    let producer = Producer::new(&node.queue, &node.audio, node.policy.clone(), node.clock.as_ref());

    // Nobody holds it yet: no lease, no audio.
    assert_eq!(producer.serve_audio(job.0, "stt:strong", "h-audio", T0 + 10), Err(Refusal::LeaseLost));

    // A worker takes the lease; a different worker still gets nothing.
    node.queue.take(QUEUE, "stt:strong", Some(60_000)).expect("taken");
    assert_eq!(producer.serve_audio(job.0, "stt:other", "h-audio", T0 + 10), Err(Refusal::LeaseLost));
    assert_eq!(producer.serve_audio(job.0, "stt:strong", "h-other", T0 + 10), Err(Refusal::NotFound), "a handle names one job");

    let bytes = producer.serve_audio(job.0, "stt:strong", "h-audio", T0 + 10).expect("the holder is served");
    assert_eq!(bytes.len(), INLINE_MAX_BYTES + 10);

    // Expired handle: worthless, whatever the lease says.
    assert_eq!(producer.serve_audio(job.0, "stt:strong", "h-audio", T0 + 130_000), Err(Refusal::StaleJob));
    // And after the settle the blob goes, with nothing left to serve.
    assert!(producer.discard_audio(job.0, "h-audio"));
    assert!(node.audio.is_empty(), "the audio is deleted after the job");
}

// ---- the wire --------------------------------------------------------------------------------------

#[test]
fn admission_refuses_a_stranger_a_replay_a_rewritten_timestamp_and_a_bad_signature() {
    let mut admission = Admission::new("openclaw", ["strong".to_string()]);
    let verify = |message: &str, from: &str, signature: &str| from == "strong" && signature == format!("sig:{message}");
    let call = |from: &str, ts: i64, rid: &str| {
        Envelope::new(Op::Take, from, "openclaw", ts, rid, TakeBody::new(QUEUE, "stt:strong", Some(60_000), 1000).to_json())
    };
    let signed = |envelope: &Envelope, digest: &str| format!("sig:{}", envelope.signature_message(digest));
    let ts = T0;
    let digest = "deadbeef";

    let stranger = call("guest-7", ts, "rid-1");
    assert_eq!(
        admission.admits(&stranger, TransportSignature { ts_ms: ts, body_sha256_hex: digest, signature: &signed(&stranger, digest) }, T0, 64, &verify),
        Err(Refusal::UnknownCaller),
        "audio only crosses between the owner's own nodes"
    );

    let mine = call("strong", ts, "rid-2");
    assert_eq!(
        admission.admits(&mine, TransportSignature { ts_ms: ts, body_sha256_hex: digest, signature: &signed(&mine, digest) }, T0, 64, &verify),
        Ok(())
    );
    assert_eq!(
        admission.admits(&mine, TransportSignature { ts_ms: ts, body_sha256_hex: digest, signature: &signed(&mine, digest) }, T0, 64, &verify),
        Err(Refusal::Replayed),
        "the same rig cannot settle a second job"
    );

    let rewritten = call("strong", ts + 5, "rid-3");
    assert_eq!(
        admission.admits(&rewritten, TransportSignature { ts_ms: ts, body_sha256_hex: digest, signature: &signed(&rewritten, digest) }, T0, 64, &verify),
        Err(Refusal::BadSignature),
        "the signed instant and the envelope's must agree"
    );

    let old = call("strong", T0 - 60_001, "rid-4");
    assert_eq!(
        admission.admits(&old, TransportSignature { ts_ms: old.ts_ms, body_sha256_hex: digest, signature: &signed(&old, digest) }, T0, 64, &verify),
        Err(Refusal::Stale)
    );

    let forged = call("strong", ts, "rid-5");
    assert_eq!(
        admission.admits(&forged, TransportSignature { ts_ms: ts, body_sha256_hex: digest, signature: "sig:not-this-call" }, T0, 64, &verify),
        Err(Refusal::BadSignature)
    );

    let elsewhere = Envelope::new(Op::Take, "strong", "other-node", ts, "rid-6", serde_json::json!({}));
    assert_eq!(
        admission.admits(&elsewhere, TransportSignature { ts_ms: ts, body_sha256_hex: digest, signature: &signed(&elsewhere, digest) }, T0, 64, &verify),
        Err(Refusal::WrongTarget)
    );
}

#[test]
fn the_wire_bodies_round_trip_and_refuse_what_they_do_not_know() {
    let request = arrival_request();
    let reply = TakeReply::Taken { job: 12, lease_until_ms: T0 + 60_000, attempts: 1, request: request.clone() };
    assert_eq!(TakeReply::from_json(&reply.to_json()).unwrap(), reply);
    assert_eq!(TakeReply::from_json(&TakeReply::Empty.to_json()).unwrap(), TakeReply::Empty);
    assert_eq!(TakeReply::from_json(&TakeReply::Busy(3).to_json()).unwrap(), TakeReply::Busy(3));

    assert_eq!(Reply::decode(&Reply::Refused(Refusal::LeaseLost).encode()).unwrap(), Reply::Refused(Refusal::LeaseLost));
    assert_eq!(Reply::decode(&Reply::ok(serde_json::json!({"settled": true})).encode()).unwrap(), Reply::ok(serde_json::json!({"settled": true})));

    let envelope = Envelope::new(Op::Done, "strong", "openclaw", T0, "rid-9", serde_json::json!({"job": 1}));
    assert_eq!(Envelope::decode(&envelope.encode()).unwrap(), envelope);
    let mut value: serde_json::Value = serde_json::from_slice(&envelope.encode()).unwrap();
    value["extra"] = serde_json::json!(1);
    assert_eq!(Envelope::decode(value.to_string().as_bytes()), Err(Refusal::Malformed("unknown_field")));

    // Refusal words are fixed tokens: a reply never echoes the request back.
    for refusal in [Refusal::UnknownCaller, Refusal::Replayed, Refusal::StaleJob, Refusal::Malformed("body")] {
        assert!(refusal.as_str().len() < 32);
    }
    assert_eq!(crate::protocol::sanitize("a\nb\tc   d"), "a b c d");
}

// ---- the policy -------------------------------------------------------------------------------------

#[test]
fn the_preference_follows_measured_latency_and_never_waits_on_a_missing_node() {
    let preference = Preference::default();
    let mut remote_latency = Latency::new();
    remote_latency.record(1_000, 900);
    remote_latency.record(2_000, 800);
    let remote = RemoteHealth::online(remote_latency.clone());
    let mut local = Latency::new();
    local.record(1_000, 4_000);
    local.record(1_500, 4_000);

    // Remote faster than local: the local worker holds back, and only until the grace ends.
    assert_eq!(
        preference.decide(2_100, 2_000, Some(&remote), &local),
        Decision::Remote { grace_until_ms: 5_000, because: RemoteReason::FasterThanLocal }
    );
    assert_eq!(preference.decide(5_000, 2_000, Some(&remote), &local), Decision::Local { because: LocalReason::GraceElapsed });

    // Remote measured slower: no wait at all.
    let mut fast = Latency::new();
    fast.record(3_000, 200);
    fast.record(3_500, 200);
    assert_eq!(preference.decide(3_600, 3_000, Some(&remote), &fast), Decision::Local { because: LocalReason::RemoteSlower });

    // Nobody attached: nothing waits on a missing node.
    assert_eq!(preference.decide(3_600, 3_000, Some(&RemoteHealth::offline()), &local), Decision::Local { because: LocalReason::RemoteOffline });
    assert_eq!(preference.decide(3_600, 3_000, None, &local), Decision::Local { because: LocalReason::RemoteOffline });

    // A stale estimate is not evidence: the remote gets its chance again (bounded by the grace).
    let later = 3_600 + Preference::default().sample_ttl_ms + 1;
    assert_eq!(
        preference.decide(later, later - 100, Some(&remote), &fast),
        Decision::Remote { grace_until_ms: later - 100 + 3_000, because: RemoteReason::RemoteUnmeasured }
    );

    // The grace is configurable, and 0 turns the wait off entirely.
    assert_eq!(Preference::from_settings(Some(0), None).decide(1_000, 1_000, Some(&remote), &local), Decision::Local { because: LocalReason::GraceElapsed });
    assert_eq!(Preference::from_settings(None, None), Preference::default());
}

#[test]
fn a_latency_estimate_needs_samples_and_recent_ones() {
    let mut latency = Latency::new();
    assert_eq!(latency.recent(1_000, 60_000, 2), None, "no sample is not a zero");
    latency.record(1_000, 2_000);
    assert_eq!(latency.recent(1_000, 60_000, 2), None, "one sample is a cold worker");
    latency.record(2_000, 1_000);
    assert_eq!(latency.recent(2_000, 60_000, 2), Some(1_700), "0.3 * 1000 + 0.7 * 2000");
    assert_eq!(latency.last_ms(), 1_000);
    assert_eq!(latency.samples(), 2);
    assert_eq!(latency.recent(62_001, 60_000, 2), None, "an old estimate is not evidence");
}

// ---- the two-node simulation -----------------------------------------------------------------------

#[test]
fn the_remote_wins_and_the_local_worker_never_decodes() {
    let mut producer = SimNode::producer("openclaw", T0, &["strong"]);
    let worker = SimWorker::new("strong", T0);
    let enqueued = enqueue(&mut producer, &arrival(300_000, T0), "h-1").expect("enqueued");
    let job = enqueued.id;
    assert_eq!(producer.audio.len(), 1, "the audio is on the producing node, behind a handle");
    assert!(producer.queue.job(job).unwrap().unwrap().payload.len() < 1024);

    // t+100 ms: the local worker would like the job, but a remote is online and nothing yet says it
    // is slower, so it holds back for the grace (3 s) instead of taking it.
    producer.advance(100);
    let preference = Preference::default();
    let mut local_latency = Latency::new();
    let mut local_recognizer = FakeRecognizer::new(1_000, vec!["local"]);
    let remote_health = remote_online();
    let deferred = poll_local(&mut producer, &preference, Some(&remote_health), &mut local_latency, &mut local_recognizer);
    assert_eq!(deferred, Outcome::Deferred { until_ms: T0 + 3_000 });
    assert_eq!(producer.metrics.waited_for_remote, 1);
    assert_eq!(local_recognizer.ran, 0);

    // The strong node answers the relay: take, fetch the audio, decode three segments, settle.
    let mut relay = Relay::new("strong", producer, worker.clock.clone());
    let mut recognizer = FakeRecognizer::ticking(500, vec!["bom", "dia", "tchau"], worker.clock.clone());
    let mut worker_metrics = Metrics::new();
    let outcome = worker.remote_worker().poll_once(&mut relay, &mut recognizer, worker.clock.as_ref(), &mut worker_metrics);

    let Outcome::Decoded { job: decoded, by, took_ms, segments, bytes } = outcome else {
        panic!("the remote decoded the job: {outcome:?}");
    };
    // The decode itself is 3 x 500 ms; the three progress calls each cost one relay hop (40 ms), and
    // both are inside the measurement - the same accounting the component's `wa-transcript` line uses.
    assert_eq!((decoded, by, took_ms, segments, bytes), (job.0, Who::Remote, 1_500 + 3 * 40, 3, 300_000));
    assert_eq!(recognizer.ran(), 1);
    assert_eq!(local_recognizer.ran, 0, "the local recognizer never ran: the remote had it");

    // The job's truth is on the producing node, once.
    let record = relay.producer.queue.job(job).unwrap().expect("job");
    assert_eq!(record.state, JobState::Done);
    assert_eq!(record.attempts, 0);
    let result: serde_json::Value = serde_json::from_slice(record.result.as_ref().expect("result")).unwrap();
    assert_eq!(result["text"], "bom dia tchau");
    assert_eq!(relay.producer.queue.stats(QUEUE).unwrap().done, 1);

    // Privacy and speed, measured: the audio crossed once and was deleted; the decode's own time was
    // recorded on the producer, which is what the preference policy compares against.
    assert_eq!(relay.bytes, 300_000);
    assert!(relay.producer.audio.is_empty(), "the audio is deleted after the job");
    assert_eq!(worker_metrics.bytes_moved, 300_000);
    assert_eq!(worker_metrics.bytes_deleted, 300_000);
    assert_eq!(relay.producer.metrics.remote_decoded, 1);
    assert_eq!(relay.producer.metrics.average_ms(Who::Remote), Some(1_500));
    assert_eq!(relay.producer.metrics.local_decoded, 0);
    // Three segments were streamed back as progress, readable on the producer.
    let segments_back = crate::producer::read_progress(&relay.producer.queue, job.0, 0, 16);
    assert_eq!(segments_back, vec![Segment::new(0, 500, "bom"), Segment::new(500, 1_000, "dia"), Segment::new(1_000, 1_500, "tchau")]);
}

#[test]
fn a_remote_that_dies_mid_job_leaves_the_job_to_the_local_worker() {
    let mut producer = SimNode::producer("openclaw", T0, &["strong"]);
    let worker = SimWorker::new("strong", T0);
    let enqueued = enqueue(&mut producer, &arrival(1_000, T0), "h-1").expect("enqueued");
    let job = enqueued.id;

    // The link works for the take and then dies: the worker can never publish its result.
    let mut relay = Relay::new("strong", producer, worker.clock.clone()).die_after(1);
    let mut remote_recognizer = FakeRecognizer::new(500, vec!["primeiro", "segundo"]);
    let mut worker_metrics = Metrics::new();
    let outcome = worker.remote_worker().poll_once(&mut relay, &mut remote_recognizer, worker.clock.as_ref(), &mut worker_metrics);
    assert_eq!(outcome, Outcome::Lost { job: job.0 }, "the call failed mid-job");
    assert_eq!(remote_recognizer.ran, 1, "the decode ran; its result is thrown away");
    assert_eq!(worker_metrics.remote_lost_mid_job, 1, "the worker knows it lost the link");

    let leased = relay.producer.queue.job(job).unwrap().expect("job");
    assert_eq!(leased.state, JobState::Leased, "a dead worker leaves the lease behind, not a settle");
    assert_eq!(leased.attempts, 0, "a vanished worker is not a failed attempt");

    // Past the lease, with no settle in sight, the local worker takes the job and finishes it.
    relay.producer.advance(61_000);
    let preference = Preference::default();
    let mut local_latency = Latency::new();
    let mut local_recognizer = FakeRecognizer::new(900, vec!["local", "terminou"]);
    let outcome = poll_local(&mut relay.producer, &preference, Some(&remote_online()), &mut local_latency, &mut local_recognizer);
    let Outcome::Decoded { job: decoded, by, .. } = outcome else {
        panic!("the local worker finished the job: {outcome:?}");
    };
    assert_eq!((decoded, by), (job.0, Who::Local));
    assert_eq!(local_recognizer.ran, 1);

    let record = relay.producer.queue.job(job).unwrap().expect("job");
    assert_eq!(record.state, JobState::Done);
    assert_eq!(record.lease_expiries, 1, "the queue recovered the dead worker's lease");
    assert_eq!(record.attempts, 0, "and charged the job nothing for it");
    let result: serde_json::Value = serde_json::from_slice(record.result.as_ref().expect("result")).unwrap();
    assert_eq!(result["text"], "local terminou", "one result, the one that survived");
    assert_eq!(relay.producer.queue.stats(QUEUE).unwrap().done, 1);
    assert_eq!(relay.producer.metrics.lease_recovered, 1);
    assert_eq!(relay.producer.metrics.local_decoded, 1);
    assert_eq!(relay.producer.metrics.remote_decoded, 0);
}

#[test]
fn a_stale_job_is_never_decoded_and_never_posted() {
    let mut producer = SimNode::producer("openclaw", T0, &["strong"]);
    let worker = SimWorker::new("strong", T0);
    let enqueued = enqueue(&mut producer, &arrival(1_000, T0), "h-1").expect("enqueued");
    let job = enqueued.id;

    // Nobody is there for five minutes; the job's window closes.
    producer.advance(301_000);
    worker.clock.set(producer.now_ms());
    let mut relay = Relay::new("strong", producer, worker.clock.clone());
    let mut remote_recognizer = FakeRecognizer::new(100, vec!["nunca"]);
    let mut worker_metrics = Metrics::new();
    let outcome = worker.remote_worker().poll_once(&mut relay, &mut remote_recognizer, worker.clock.as_ref(), &mut worker_metrics);
    assert_eq!(outcome, Outcome::Empty, "the queue does not hand out a stale job");
    assert_eq!(remote_recognizer.ran, 0, "nothing was decoded");

    let record = relay.producer.queue.job(job).unwrap().expect("job");
    assert_eq!(record.state, JobState::Expired, "dropped, and recorded as dropped");
    assert!(record.result.is_none(), "no transcript, so nothing to post late");
    assert_eq!(record.progress_entries, 0);
    let alerts = relay.producer.queue.alerts(None, 8).expect("alerts");
    assert!(alerts.iter().any(|alert| alert.job == job && alert.kind == wa_queue::AlertKind::Expired), "the operator is told: {alerts:?}");

    // The local worker finds nothing either — it does not resurrect the expired job.
    let preference = Preference::default();
    let mut local_latency = Latency::new();
    let mut local_recognizer = FakeRecognizer::new(100, vec!["nunca"]);
    let outcome = poll_local(&mut relay.producer, &preference, None, &mut local_latency, &mut local_recognizer);
    assert_eq!(outcome, Outcome::Empty);
    assert_eq!(local_recognizer.ran, 0);

    // And the belt below the queue: a job leased in time but decoded past the window is dropped, not
    // posted (the second freshness check in `Decoder`).
    let second = with_msg(arrival(500, relay.producer.now_ms()), "second");
    let enqueued = enqueue(&mut relay.producer, &second, "h-2").expect("enqueued");
    let taken = relay.producer.queue.take(QUEUE, "local:openclaw", Some(60_000)).expect("taken").job().expect("job");
    assert_eq!(taken.id, enqueued.id);
    let request = SttRequest::decode(&taken.payload).expect("payload");
    let mut stale_request = request.clone();
    stale_request.fresh_until_ms = relay.producer.now_ms();
    // A worker clock that ran ahead of the producer's: the job went stale under the decode.
    let late_clock = Arc::new(FixedClock::new(relay.producer.now_ms() + 1));
    let mut late_recognizer = FakeRecognizer::new(100, vec!["tarde demais"]);
    let decoder = Decoder { worker: "local:openclaw".into(), lease_ms: 60_000, heartbeat_every_ms: 15_000, by: Who::Local };
    let mut sink = LocalSink { queue: &relay.producer.queue, lease_ms: 60_000 };
    let outcome = decoder.decode(
        &mut sink,
        &mut late_recognizer,
        taken.id.0,
        &stale_request,
        b"audio".to_vec(),
        late_clock.as_ref(),
        &mut relay.producer.metrics,
    );
    assert_eq!(outcome, Outcome::Stale { job: taken.id.0 });
    assert_eq!(late_recognizer.ran, 0, "a stale job is not decoded at all");
    assert!(relay.producer.queue.job(taken.id).unwrap().unwrap().result.is_none());
}

#[test]
fn the_local_worker_takes_over_after_the_grace_when_the_remote_does_not() {
    let mut producer = SimNode::producer("openclaw", T0, &["strong"]);
    let enqueued = enqueue(&mut producer, &arrival(1_000, T0), "h-1").expect("enqueued");
    let job = enqueued.id;
    let preference = Preference::default();
    let remote_health = remote_online();
    let mut local_latency = Latency::new();
    let mut recognizer = FakeRecognizer::ticking(700, vec!["a", "b"], producer.clock.clone());

    // t+0 and t+2 s: the remote is expected, the local worker waits.
    for at in [T0, T0 + 2_000] {
        producer.clock.set(at);
        let outcome = poll_local(&mut producer, &preference, Some(&remote_health), &mut local_latency, &mut recognizer);
        assert_eq!(outcome, Outcome::Deferred { until_ms: T0 + 3_000 }, "at {at}");
    }
    assert_eq!(producer.metrics.waited_for_remote, 2);
    assert_eq!(recognizer.ran(), 0);
    assert_eq!(producer.queue.job(job).unwrap().unwrap().state, JobState::Ready, "untouched while waiting");

    // t+3.001 s: the grace is over, so the local worker does the job itself.
    producer.clock.set(T0 + 3_001);
    let outcome = poll_local(&mut producer, &preference, Some(&remote_health), &mut local_latency, &mut recognizer);
    assert_eq!(outcome, Outcome::Decoded { job: job.0, by: Who::Local, took_ms: 1_400, segments: 2, bytes: 1_000 });
    assert_eq!(producer.metrics.fallback_taken, 1);
    assert_eq!(producer.metrics.local_decoded, 1);
    assert_eq!(local_latency.recent(producer.now_ms(), 60_000, 1), Some(1_400), "the local estimate is measured, not assumed");

    // The next note arrives with the remote node gone: no wait at all.
    producer.advance(1_000);
    let second = with_msg(arrival(1_000, producer.now_ms()), "second");
    enqueue(&mut producer, &second, "h-2").expect("enqueued");
    let outcome = poll_local(&mut producer, &preference, Some(&RemoteHealth::offline()), &mut local_latency, &mut recognizer);
    assert!(matches!(outcome, Outcome::Decoded { by: Who::Local, .. }), "nothing waits on a missing node: {outcome:?}");
    assert_eq!(producer.metrics.local_immediate, 1);
    assert_eq!(producer.metrics.fallback_taken, 1);
}

#[test]
fn a_failed_decode_is_reported_once_and_the_reason_is_one_bounded_line() {
    let mut producer = SimNode::producer("openclaw", T0, &["strong"]);
    let enqueued = enqueue(&mut producer, &arrival(1_000, T0), "h-1").expect("enqueued");
    let job = enqueued.id;
    let mut recognizer = FakeRecognizer::failing(200, RecognizerError::Permanent("no speech".into()));
    let mut latency = Latency::new();
    let outcome = poll_local(&mut producer, &Preference::default(), None, &mut latency, &mut recognizer);
    assert_eq!(outcome, Outcome::Failed { job: job.0, reason: "unsupported:no speech".into(), retryable: false });

    let record = producer.queue.job(job).unwrap().expect("job");
    assert_eq!(record.attempts, 1);
    assert_eq!(record.last_error.as_deref(), Some("unsupported:no speech"));
    assert!(record.result.is_none(), "a failure never becomes a transcript");
    assert_eq!(record.state, JobState::Ready, "a retry is one attempt, not a dead letter yet");

    // A reason with newlines and a very long tail is folded to one bounded line before it is stored.
    let long = format!("boom\n{}", "x".repeat(400));
    let sanitized = crate::protocol::sanitize(&long);
    assert!(!sanitized.contains('\n'));
    assert!(sanitized.chars().count() <= crate::protocol::MAX_REASON_CHARS);
}

#[test]
fn metrics_and_job_lines_never_carry_text() {
    let mut metrics = Metrics::new();
    metrics.enqueued = 3;
    metrics.record_decode(Who::Remote, 1_500);
    metrics.record_decode(Who::Local, 900);
    metrics.bytes_moved = 4_096;
    metrics.segments = 7;
    metrics.record_refusal(&Refusal::UnknownCaller);
    let line = metrics.line();
    assert!(line.starts_with("stt-remote v=1 "), "{line}");
    assert!(line.contains("remote_avg_ms=1500") && line.contains("local_avg_ms=900"), "{line}");
    assert!(!line.contains("CANARY"));

    let trace = crate::metrics::JobTrace { job: 42, by: Who::Remote, outcome: "done", took_ms: 1_500, segments: 3, bytes: 4_096 };
    assert_eq!(trace.line(), "stt-job v=1 job=42 by=remote outcome=done took_ms=1500 segments=3 bytes=4096");
    assert_eq!(Outcome::Decoded { job: 42, by: Who::Remote, took_ms: 1, segments: 1, bytes: 1 }.word(), "done");
    assert_eq!(Outcome::Stale { job: 1 }.trace(Who::Local).map(|trace| trace.outcome), Some("stale"));
}

#[test]
fn the_queue_is_the_one_the_documents_name() {
    // A name change is a contract change: the component, the docs and a remote worker all say
    // `stt.requests`, and a silent rename would split the queue in two.
    assert_eq!(QUEUE, "stt.requests");
    assert_eq!(TakeBody::new(QUEUE, "stt:strong", None, 0).queue, "stt.requests");
    assert_eq!(SttPolicy::default().fresh_ms, 300_000, "the connector's five minutes");
    assert_eq!(SttPolicy::default().max_attempts, 6, "the connector's maxComputeFailures");
    assert_eq!(Producer::new(&Queue::new(Arc::new(wa_queue::MemoryKv::new()), Arc::new(FixedClock::new(T0)), wa_queue::Policy::default()), &crate::producer::MemoryAudioStore::new(), SttPolicy::default(), &FixedClock::new(T0)).priority(T0, T0 - 1_000, 0), 20);
}

/// The parts of the API the host and the component are expected to reach for; a compile-time usage
/// test, so a signature change breaks here instead of in the host after the upgrade lands.
#[test]
fn the_public_seams_a_host_needs_are_callable() {
    let clock: Arc<FixedClock> = Arc::new(FixedClock::new(T0));
    assert_eq!(clock.now_ms(), T0);
    let queue = Queue::new(Arc::new(wa_queue::MemoryKv::new()), clock.clone(), wa_queue::Policy::default());
    let store = crate::producer::MemoryAudioStore::new();
    let producer = Producer::new(&queue, &store, SttPolicy::default(), clock.as_ref());
    let enqueued = producer
        .enqueue(&arrival(10, T0), "h", &mut Metrics::new())
        .expect("enqueued with a producer the host built by hand");
    assert_eq!(enqueued.id, JobId(1));
    let _round_trip: fn(&[u8]) -> Result<SttRequest, RequestError> = SttRequest::decode;
    let _word: fn(&Outcome) -> &'static str = Outcome::word;
}
