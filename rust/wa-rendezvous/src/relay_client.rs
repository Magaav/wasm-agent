//! Relay client: attach this node to the relay so peers can reach it even when
//! it cannot accept inbound connections.
//!
//! Outbound only: the node long-polls the relay for requests, hands each one to
//! the main thread for processing (Lua is single-threaded), then posts the
//! response back. The relay never holds a connection *to* us, which is exactly
//! what makes it work behind NAT.
//!
//! **Polling never waits for execution.** The poll below hands a request over and
//! returns to polling at once; a responder thread waits for the answer and posts
//! it. The earlier shape waited for the answer on the poll thread itself, so any
//! call longer than the relay's attach window (40 s) left this node unreachable
//! for everyone else until it answered - the same defect the bound transport had,
//! measured 2026-11-10. The number running at once is bounded, and a request over
//! the bound gets an explicit `relay_busy` answer that the relay does not settle
//! under its rid, so the caller can send it again.
use crate::node::Identity;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

pub struct RelayJob {
    pub id: String,
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub reply: mpsc::Sender<(u16, String)>,
    /// The bound the relay stamped from the wait the caller was given: epoch milliseconds, and how
    /// long that wait was. `None` from an older relay, which stamps neither.
    pub deadline_ms: Option<u64>,
    pub budget_ms: Option<u64>,
    /// Flipped by the responder once the bound passes, so work that can be stopped stops: the
    /// runtime kills its `bash` and cuts a silent provider read.
    pub cancel: Arc<AtomicBool>,
}

static INBOX: Mutex<Vec<RelayJob>> = Mutex::new(Vec::new());
/// Relayed calls running right now, across this process.
static RUNNING: AtomicUsize = AtomicUsize::new(0);

/// How many relayed calls may run at once. Bounded on purpose: the poll lane pays for every one of
/// them, and a peer must not be able to turn this node into its own worker pool. Past it the node
/// refuses at once with a named answer instead of queueing silently.
fn concurrency() -> usize {
    std::env::var("WA_RELAY_CONCURRENCY")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .map(|count| count.clamp(1, 8))
        .unwrap_or(3)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as u64)
        .unwrap_or(0)
}

fn at() -> String { crate::node::iso8601(now_ms()) }

/// Drain the requests the relay handed us (called from the main serve loop).
pub fn take_jobs() -> Vec<RelayJob> {
    match INBOX.lock() {
        Ok(mut inbox) => std::mem::take(&mut *inbox),
        Err(_) => Vec::new(),
    }
}

/// Posts one answer to `POST /relay/respond`. The seam a test replaces: the scheduling, the bound and
/// the discard belong to this module, and a fake poster measures them without a relay or a key.
pub type Poster = Arc<dyn Fn(&str, u16, &str) -> Result<(), String> + Send + Sync>;

fn agent(timeout: Duration) -> ureq::Agent {
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_global(Some(timeout))
        .build()
        .into()
}

fn signed(identity: &Identity, action: &str) -> (String, String, String) {
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
        .to_string();
    let signature = identity.sign(&format!("{action}|{}|{ts}", identity.node_id));
    (ts, signature, identity.node_id.clone())
}

/// Post one relayed answer, signed by this node.
///
/// Shared with the bound transport's worker lane (`binding_runtime`): one signing rule and one URL,
/// so two transports cannot drift about what a node's answer looks like.
pub(crate) fn respond(identity: &Identity, relay_url: &str, id: &str, status: u16, body: &str) -> Result<(), String> {
    let (ts, signature, node_id) = signed(identity, "relay-respond");
    let payload = json!({ "node_id": node_id, "id": id, "status": status, "body": body }).to_string();
    agent(Duration::from_secs(30))
        .post(&format!("{}/relay/respond", relay_url.trim_end_matches('/')))
        .header("Content-Type", "application/json")
        .header("x-wa-node", &node_id)
        .header("x-wa-pub", &identity.public_key)
        .header("x-wa-ts", &ts)
        .header("x-wa-sig", &signature)
        .send(payload.as_bytes())
        .map(|_| ())
        .map_err(|error| error.to_string())
}

/// Wait for one job's answer at most until its bound, then post it.
///
/// If the bound passes first the work is cancelled and the caller is answered with a named timeout,
/// which is a settled outcome under the rid: the action may have started, so a retry must not re-run
/// it blindly. An answer that arrives afterwards is dropped with the receiver - `serve.rs` logs it as
/// `late` - and is never posted as if it were fresh.
fn spawn_responder(
    node_id: String,
    id: String,
    deadline_ms: Option<u64>,
    budget_ms: Option<u64>,
    cancel: Arc<AtomicBool>,
    receiver: mpsc::Receiver<(u16, String)>,
    poster: Poster,
) {
    let _ = std::thread::Builder::new()
        .name(format!("wa-relay-answer-{id}"))
        .spawn(move || {
            let bounded = deadline_ms.is_some();
            let wait = match deadline_ms {
                Some(at) => Duration::from_millis(at.saturating_sub(now_ms())),
                // No bound from an older relay: the old cap, so a stuck job cannot hold a slot forever.
                None => Duration::from_secs(90),
            };
            match receiver.recv_timeout(wait) {
                Ok((status, body)) => {
                    if let Err(error) = poster(&id, status, &body) {
                        eprintln!("[relay] answer not delivered node={node_id} at={} rid={id}: {error}", at());
                    }
                }
                Err(_) => {
                    cancel.store(true, Ordering::SeqCst);
                    let budget = budget_ms.unwrap_or_else(|| wait.as_millis() as u64);
                    eprintln!(
                        "[relay] timeout node={node_id} at={} rid={id} budget_ms={budget} bound={}",
                        at(),
                        if bounded { "relay" } else { "local 90s cap" }
                    );
                    let body = json!({
                        "error": "relay_request_timeout",
                        "id": id,
                        "budget_ms": budget,
                        "hint": "the call passed the deadline its caller was given; the work was stopped and no late result will be delivered"
                    })
                    .to_string();
                    if let Err(error) = poster(&id, 504, &body) {
                        eprintln!("[relay] timeout answer not delivered node={node_id} at={} rid={id}: {error}", at());
                    }
                }
            }
            RUNNING.fetch_sub(1, Ordering::SeqCst);
        });
}

/// Hand one request over without waiting for it (the poll lane calls this and keeps polling).
fn handle_request(node_id: &str, request: &Value, poster: Poster) {
    let id = request["id"].as_str().unwrap_or_default().to_string();
    if id.is_empty() {
        return;
    }
    let running = RUNNING.fetch_add(1, Ordering::SeqCst);
    let limit = concurrency();
    if running >= limit {
        RUNNING.fetch_sub(1, Ordering::SeqCst);
        // Explicit and *not started*: the relay erases the rid, so the same request may be sent again
        // and nothing has run twice.
        eprintln!("[relay] busy node={node_id} at={} rid={id} reason=running {running}/{limit}", at());
        let body = json!({
            "error": "relay_busy",
            "id": id,
            "not_started": true,
            "running": running,
            "limit": limit,
            "retryable": true,
            "retry_after_ms": 750,
            "hint": "the node is running its limit of relayed calls; nothing ran, so the same request may be retried"
        })
        .to_string();
        if let Err(error) = poster(&id, 503, &body) {
            eprintln!("[relay] busy answer not delivered node={node_id} at={} rid={id}: {error}", at());
        }
        return;
    }
    let mut headers = Vec::new();
    if let Some(map) = request["headers"].as_object() {
        for (key, value) in map {
            headers.push((key.to_lowercase(), value.as_str().unwrap_or_default().to_string()));
        }
    }
    let deadline_ms = request["deadline_ms"].as_u64();
    let budget_ms = request["budget_ms"].as_u64();
    let (tx, rx) = mpsc::channel();
    let cancel = Arc::new(AtomicBool::new(false));
    let job = RelayJob {
        id: id.clone(),
        method: request["method"].as_str().unwrap_or("POST").to_string(),
        path: request["path"].as_str().unwrap_or("/").to_string(),
        headers,
        body: request["body"].as_str().unwrap_or_default().to_string(),
        reply: tx,
        deadline_ms,
        budget_ms,
        cancel: cancel.clone(),
    };
    eprintln!(
        "[relay] dispatch node={node_id} at={} rid={id} {} {} budget_ms={} running={}/{}",
        at(),
        job.method,
        job.path,
        budget_ms.map(|value| value.to_string()).unwrap_or_else(|| "-".into()),
        running + 1,
        limit
    );
    if let Ok(mut inbox) = INBOX.lock() {
        inbox.push(job);
    }
    spawn_responder(node_id.to_string(), id, deadline_ms, budget_ms, cancel, rx, poster);
}

pub fn spawn(relay_url: String) {
    std::thread::spawn(move || {
        let identity = match Identity::load() {
            Ok(identity) => Arc::new(identity),
            Err(error) => {
                eprintln!("[relay] identity unavailable: {error}");
                return;
            }
        };
        let short = &identity.node_id[..identity.node_id.len().min(8)];
        eprintln!("[relay] starting node={} at={} reason=relay client on {relay_url} as {short}",
            identity.node_id, at());
        let poster: Poster = {
            let identity = identity.clone();
            let relay_url = relay_url.clone();
            Arc::new(move |id, status, body| respond(&identity, &relay_url, id, status, body))
        };
        let polling = Arc::new(AtomicBool::new(false));
        loop {
            if !crate::node::network_active() {
                if polling.swap(false, Ordering::SeqCst) {
                    eprintln!("[relay] detach node={} at={} reason=network inactive", identity.node_id, at());
                }
                std::thread::sleep(Duration::from_secs(2));
                continue;
            }
            let (ts, signature, node_id) = signed(&identity, "relay-poll");
            let url = format!(
                "{}/relay/poll?node_id={node_id}",
                relay_url.trim_end_matches('/')
            );
            let response = agent(Duration::from_secs(40))
                .get(&url)
                .header("x-wa-node", &node_id)
                .header("x-wa-pub", &identity.public_key)
                .header("x-wa-ts", &ts)
                .header("x-wa-sig", &signature)
                .call();
            let body = match response {
                Ok(response) if response.status().as_u16() == 200 => {
                    response.into_body().read_to_string().unwrap_or_default()
                }
                Ok(response) => {
                    if polling.swap(false, Ordering::SeqCst) {
                        eprintln!("[relay] detach node={node_id} at={} reason=poll answer {}", at(), response.status().as_u16());
                    }
                    std::thread::sleep(Duration::from_secs(3));
                    continue;
                }
                Err(error) => {
                    if polling.swap(false, Ordering::SeqCst) {
                        eprintln!("[relay] detach node={node_id} at={} reason=poll failed: {error}", at());
                    }
                    std::thread::sleep(Duration::from_secs(3));
                    continue;
                }
            };
            if !polling.swap(true, Ordering::SeqCst) {
                eprintln!("[relay] attach node={node_id} at={} reason=relay poll answered", at());
            }
            let parsed: Value = match serde_json::from_str(&body) {
                Ok(value) => value,
                Err(_) => continue,
            };
            let Some(request) = parsed.get("request") else {
                continue; // a long-poll timeout tick
            };
            handle_request(&node_id, request, poster.clone());
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    /// The inbox, the running count and the log are process-wide, so these tests take turns: a
    /// capacity test that ran beside a dispatch test would be measuring itself.
    static TEST_LOCK: StdMutex<()> = StdMutex::new(());

    struct Recorded {
        answers: StdMutex<Vec<(String, u16, String)>>,
    }

    fn recorded() -> Arc<Recorded> {
        Arc::new(Recorded { answers: StdMutex::new(Vec::new()) })
    }

    fn poster(record: Arc<Recorded>) -> Poster {
        Arc::new(move |id, status, body| {
            record.answers.lock().unwrap().push((id.to_string(), status, body.to_string()));
            Ok(())
        })
    }

    fn request(id: &str, budget_ms: u64) -> Value {
        json!({"id": id, "method": "POST", "path": "/node/call", "headers": {}, "body": "{}",
            "budget_ms": budget_ms, "deadline_ms": now_ms() + budget_ms})
    }

    fn await_answers(record: &Arc<Recorded>, count: usize) {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while record.answers.lock().unwrap().len() < count {
            assert!(std::time::Instant::now() < deadline, "answers did not arrive: {}", record.answers.lock().unwrap().len());
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    /// The defect, measured: with one request's answer still pending, the poll lane hands the next
    /// request over at once and never waits for the first to settle.
    #[test]
    fn polling_continues_while_an_answer_is_pending() {
        let _lock = TEST_LOCK.lock().unwrap();
        RUNNING.store(0, Ordering::SeqCst);
        let record = recorded();
        let post = poster(record.clone());
        let started = std::time::Instant::now();
        handle_request("node-a", &request("rid-slow", 5_000), post.clone());
        assert!(started.elapsed() < Duration::from_secs(1), "dispatch must not wait for the answer");
        let first = take_jobs();
        assert_eq!(first.len(), 1, "the slow job was handed to the node");
        // The next poll finds a second request and hands it over while the first is still running.
        handle_request("node-a", &request("rid-status", 5_000), post.clone());
        let second = take_jobs();
        assert_eq!(second.len(), 1, "the second request is admitted while the first runs");
        assert!(record.answers.lock().unwrap().is_empty(), "nothing answers before it settles");
        assert_eq!(RUNNING.load(Ordering::SeqCst), 2, "both are running at once");
        // Answers are posted by the responder thread, not by the hand-off.
        let _ = first[0].reply.send((200, "{\"ok\":true,\"rid\":\"rid-slow\"}".into()));
        let _ = second[0].reply.send((200, "{\"ok\":true,\"rid\":\"rid-status\"}".into()));
        await_answers(&record, 2);
        while RUNNING.load(Ordering::SeqCst) > 0 { std::thread::sleep(Duration::from_millis(10)); }
    }

    /// The bound: a request that does not answer in time is cancelled and answered with a named
    /// timeout, exactly once. An answer that arrives later is not posted at all.
    #[test]
    fn a_passed_bound_answers_a_named_timeout_and_never_a_late_answer() {
        let _lock = TEST_LOCK.lock().unwrap();
        RUNNING.store(0, Ordering::SeqCst);
        let record = recorded();
        let post = poster(record.clone());
        let (tx, rx) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        RUNNING.fetch_add(1, Ordering::SeqCst);
        spawn_responder("node-a".into(), "rid-bound".into(), Some(now_ms() + 250), Some(250), cancel.clone(), rx, post);
        await_answers(&record, 1);
        let answers = record.answers.lock().unwrap().clone();
        assert_eq!(answers.len(), 1, "one answer, at the bound");
        assert_eq!(answers[0].1, 504);
        assert!(answers[0].2.contains("relay_request_timeout"), "{}", answers[0].2);
        assert!(cancel.load(Ordering::SeqCst), "the work was cancelled at the bound");
        // The work ignores the cancel and answers later: that answer is not delivered.
        let _ = tx.send((200, "{\"late\":true}".into()));
        std::thread::sleep(Duration::from_millis(150));
        assert_eq!(record.answers.lock().unwrap().len(), 1, "a late answer is never posted as fresh");
        assert_eq!(RUNNING.load(Ordering::SeqCst), 0, "the bound released the slot");
    }

    /// Over the bound the node refuses at once, says it did not start, and frees the slot.
    #[test]
    fn over_the_limit_the_node_answers_busy_and_started_nothing() {
        let _lock = TEST_LOCK.lock().unwrap();
        let limit = concurrency();
        RUNNING.store(limit, Ordering::SeqCst);
        let record = recorded();
        handle_request("node-a", &request("rid-over", 60_000), poster(record.clone()));
        let answers = record.answers.lock().unwrap().clone();
        assert_eq!(answers.len(), 1);
        assert_eq!(answers[0].1, 503);
        assert!(answers[0].2.contains("relay_busy") && answers[0].2.contains("\"not_started\":true"), "{}", answers[0].2);
        assert_eq!(RUNNING.load(Ordering::SeqCst), limit, "a refusal costs no slot");
        RUNNING.store(0, Ordering::SeqCst);
    }
}
