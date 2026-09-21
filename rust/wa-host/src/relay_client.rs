//! Relay client: attach this node to the relay so peers can reach it even when
//! it cannot accept inbound connections.
//!
//! Outbound only: the node long-polls the relay for requests, hands each one to
//! the main thread for processing (Lua is single-threaded), then posts the
//! response back. The relay never holds a connection *to* us, which is exactly
//! what makes it work behind NAT.
use crate::node::Identity;
use serde_json::{json, Value};
use std::sync::mpsc;
use std::sync::Mutex;
use std::time::Duration;

pub struct RelayJob {
    pub id: String,
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub reply: mpsc::Sender<(u16, String)>,
}

static INBOX: Mutex<Vec<RelayJob>> = Mutex::new(Vec::new());

/// Drain the requests the relay handed us (called from the main serve loop).
pub fn take_jobs() -> Vec<RelayJob> {
    match INBOX.lock() {
        Ok(mut inbox) => std::mem::take(&mut *inbox),
        Err(_) => Vec::new(),
    }
}

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

pub fn spawn(relay_url: String) {
    std::thread::spawn(move || {
        let identity = match Identity::load() {
            Ok(identity) => identity,
            Err(error) => {
                eprintln!("[relay] identity unavailable: {error}");
                return;
            }
        };
        let short = &identity.node_id[..identity.node_id.len().min(8)];
        eprintln!("[relay] attached to {relay_url} as {short}");
        loop {
            if !crate::node::network_active() {
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
                    eprintln!("[relay] poll -> {}", response.status().as_u16());
                    std::thread::sleep(Duration::from_secs(3));
                    continue;
                }
                Err(error) => {
                    eprintln!("[relay] poll failed: {error}");
                    std::thread::sleep(Duration::from_secs(3));
                    continue;
                }
            };
            let parsed: Value = match serde_json::from_str(&body) {
                Ok(value) => value,
                Err(_) => continue,
            };
            let Some(request) = parsed.get("request") else {
                continue; // a long-poll timeout tick
            };
            let id = request["id"].as_str().unwrap_or_default().to_string();
            if id.is_empty() {
                continue;
            }
            let (tx, rx) = mpsc::channel();
            let mut headers = Vec::new();
            if let Some(map) = request["headers"].as_object() {
                for (key, value) in map {
                    headers.push((key.to_lowercase(), value.as_str().unwrap_or_default().to_string()));
                }
            }
            let job = RelayJob {
                id: id.clone(),
                method: request["method"].as_str().unwrap_or("POST").to_string(),
                path: request["path"].as_str().unwrap_or("/").to_string(),
                headers,
                body: request["body"].as_str().unwrap_or_default().to_string(),
                reply: tx,
            };
            if let Ok(mut inbox) = INBOX.lock() {
                inbox.push(job);
            }
            // The main thread processes it and answers here.
            let (status, response_body) = rx
                .recv_timeout(Duration::from_secs(90))
                .unwrap_or((504, "{\"error\":\"local_timeout\"}".to_string()));

            let (ts, signature, node_id) = signed(&identity, "relay-respond");
            let payload = json!({
                "node_id": node_id, "id": id, "status": status, "body": response_body
            })
            .to_string();
            let _ = agent(Duration::from_secs(30))
                .post(&format!("{}/relay/respond", relay_url.trim_end_matches('/')))
                .header("Content-Type", "application/json")
                .header("x-wa-node", &node_id)
                .header("x-wa-pub", &identity.public_key)
                .header("x-wa-ts", &ts)
                .header("x-wa-sig", &signature)
                .send(payload.as_bytes());
        }
    });
}
