//! The fleet view: one read-only answer about every node (docs/FLEET-OPS.md).
//!
//! A node in this fleet is one `wa serve` process with its own identity, state home and transcript.
//! Answering "is the fleet healthy, and what is it running?" used to be five calls (`nodes`, `services`,
//! `operation`, `jobs`, a log search) plus a guess about which of the five was stale. This crate is the
//! one answer: per node, liveness and `last_seen`, version and source commit, health, disk, components
//! and the features they carry, the operations and jobs in flight, and recent incidents from telemetry
//! and the lessons store.
//!
//! # The one rule: unknown is named, never faked
//!
//! The failure this crate exists to prevent is the reassuring zero. A peer the rendezvous has no
//! `last_seen` for is not "seen 0 seconds ago"; a node whose runtime would not answer is not "healthy";
//! a disk nobody sampled is not "0% used". Every field a node could not answer is left absent and
//! listed in that node's [`NodeView::missing`], and [`View::missing_total`] counts them, so a reader
//! can tell "nothing is wrong" from "nothing was read". The habits this encodes are `lua/core/habits.lua`
//! ("distrust a misleading result") and `docs/FLEET-OPS.md` ("unknown is named").
//!
//! # Read-only by construction
//!
//! [`CAPABILITY`] names the capability; there is no mutating function in this crate, no I/O, no
//! network and no clock of its own ([`assemble`] takes `now_ms`). [`FIELDS`] is the contract the Lua
//! tool and the host capability both answer, and the tests assert the serialized record carries every
//! one of them for a fully-known node.
//!
//! # Not here yet
//!
//! Reading a *peer's* health, components and running work needs a peer read (`docs/FLEET-OPS.md`,
//! "Diagnosing a node that is offline"). Until the host capability can make one, a peer observation
//! carries the registry's facts and names the rest in `missing` with its own reason - the honest answer
//! while the read does not exist, and the same shape once it does.

use serde_json::{json, Map, Value};

/// The capability name the host registers and the Lua tool calls.
pub const CAPABILITY: &str = "fleetview";

/// The record's schema version. A field's meaning may be added to; it is never silently redefined.
pub const SCHEMA: &str = "fleetview.v1";

/// The fields every node record answers or names as missing, in the order the documentation lists them.
/// The Lua tool keeps the same list (`M.FIELDS`), and `docs/FLEET-OPS.md` prints it.
pub const FIELDS: [&str; 12] = [
    "online",
    "last_seen_ms",
    "role",
    "version",
    "commit",
    "health",
    "disk",
    "components",
    "features",
    "operations",
    "jobs",
    "incidents",
];

/// Bounds. One call must stay readable: a fabric of 64 nodes with 40 components each is the ceiling, and
/// a trimmed list says how much was there (`*_truncated`), never trims in silence.
pub const MAX_NODES: usize = 64;
pub const MAX_COMPONENTS: usize = 40;
pub const MAX_OPERATIONS: usize = 25;
pub const MAX_INCIDENTS: usize = 5;

/// A disk above this fraction used is reported as a health reason. A judgement with its reason attached,
/// so a reader can disagree with the threshold rather than with a verdict.
pub const DISK_DEGRADED_PERCENT: f64 = 90.0;

/// Is the capability read-only? A constant instead of a method, so a caller cannot ask an instance that
/// might have been built with a write path. There is no write path in this crate at all.
pub const fn read_only() -> bool {
    true
}

/// Health as a node reports it: a state, where it came from, and the reasons.
#[derive(Clone, Debug, PartialEq)]
pub struct Health {
    /// `ok`, `degraded`, `unhealthy` or `unknown`.
    pub state: String,
    /// Which source produced it (`runtime_info`, `rendezvous`, `probe`).
    pub source: String,
    pub reasons: Vec<String>,
}

impl Health {
    pub fn ok(source: &str) -> Health {
        Health { state: "ok".to_string(), source: source.to_string(), reasons: Vec::new() }
    }

    pub fn unknown(source: &str, reason: &str) -> Health {
        Health {
            state: "unknown".to_string(),
            source: source.to_string(),
            reasons: vec![reason.to_string()],
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Disk {
    pub available_bytes: Option<u64>,
    pub total_bytes: Option<u64>,
    pub used_percent: Option<f64>,
}

/// A component the node runs, and the features (tools, verbs) it carries.
#[derive(Clone, Debug, PartialEq)]
pub struct Component {
    pub name: String,
    pub enabled: bool,
    /// `running`, `not_running`, `failed`, `unknown` - the runtime's own word.
    pub state: String,
    pub features: Vec<String>,
}

/// Running work: an operation or a job. `state` is the executor's word, unmodified.
#[derive(Clone, Debug, PartialEq)]
pub struct Work {
    pub id: String,
    pub state: String,
    pub kind: Option<String>,
    pub started_at: Option<u64>,
    pub owner: Option<String>,
}

/// One incident: a lesson's rule, or a telemetry class. Never a message body, a prompt or a secret -
/// there is no field for text here, which is how that stays true.
#[derive(Clone, Debug, PartialEq)]
pub struct Incident {
    pub id: String,
    /// `telemetry` or `lesson`.
    pub source: String,
    pub at: Option<u64>,
    pub kind: Option<String>,
    pub summary: String,
}

/// What a collector saw about one node. Every field is optional except identity, because "I could not
/// read it" is a fact the view has to carry.
#[derive(Clone, Debug, Default)]
pub struct Observation {
    pub name: String,
    pub node_id: String,
    pub role: Option<String>,
    pub local_node: bool,
    pub online: Option<bool>,
    /// When the registry last heard from it, in milliseconds.
    pub last_seen_ms: Option<u64>,
    pub version: Option<String>,
    pub commit: Option<String>,
    pub health: Option<Health>,
    pub disk: Option<Disk>,
    /// `None` means components were not read; `Some(vec![])` means read and there are none.
    pub components: Option<Vec<Component>>,
    pub operations: Option<Vec<Work>>,
    pub jobs: Option<Vec<Work>>,
    pub incidents: Vec<Incident>,
    /// Extra capabilities the node advertises (features it carries without a component row).
    pub capabilities: Vec<String>,
}

/// A lesson, as the lessons store holds it (`lua/core/lessons.lua`): fleet knowledge, not a per-node row.
#[derive(Clone, Debug, Default)]
pub struct Lesson {
    pub id: String,
    pub at: Option<u64>,
    pub rule: String,
    pub tags: Vec<String>,
}

/// One node's answer.
#[derive(Clone, Debug, PartialEq)]
pub struct NodeView {
    pub name: String,
    pub node_id: String,
    pub role: Option<String>,
    pub local_node: bool,
    pub online: Option<bool>,
    pub last_seen_ms: Option<u64>,
    pub last_seen_age_s: Option<u64>,
    pub version: Option<String>,
    pub commit: Option<String>,
    pub health: Option<Health>,
    pub disk: Option<Disk>,
    pub components: Option<Vec<Component>>,
    pub components_truncated: Option<usize>,
    pub features: Vec<String>,
    pub operations: Option<Vec<Work>>,
    pub operations_truncated: Option<usize>,
    pub jobs: Option<Vec<Work>>,
    pub incidents: Vec<Incident>,
    pub incidents_truncated: Option<usize>,
    /// Every field this node could not answer, by name. Empty means the record is complete.
    pub missing: Vec<String>,
}

impl NodeView {
    pub fn complete(&self) -> bool {
        self.missing.is_empty()
    }

    /// The JSON record. `missing` is emitted only when it is not empty, so a complete node has no empty
    /// list to misread; a node with an unknown field always names it.
    pub fn to_json(&self) -> Value {
        let mut object = Map::new();
        object.insert("name".to_string(), json!(self.name));
        object.insert("node_id".to_string(), json!(self.node_id));
        object.insert("local_node".to_string(), json!(self.local_node));
        object.insert("role".to_string(), self.role.as_ref().map_or(Value::Null, |role| json!(role)));
        object.insert("online".to_string(), self.online.map_or(Value::Null, |online| json!(online)));
        object.insert("last_seen_ms".to_string(), self.last_seen_ms.map_or(Value::Null, |value| json!(value)));
        object.insert(
            "last_seen_age_s".to_string(),
            self.last_seen_age_s.map_or(Value::Null, |value| json!(value)),
        );
        object.insert("version".to_string(), self.version.as_ref().map_or(Value::Null, |value| json!(value)));
        object.insert("commit".to_string(), self.commit.as_ref().map_or(Value::Null, |value| json!(value)));
        object.insert(
            "health".to_string(),
            self.health.as_ref().map_or(Value::Null, |health| {
                json!({"state": health.state, "source": health.source, "reasons": health.reasons})
            }),
        );
        object.insert(
            "disk".to_string(),
            self.disk.as_ref().map_or(Value::Null, |disk| {
                json!({
                    "available_bytes": disk.available_bytes,
                    "total_bytes": disk.total_bytes,
                    "used_percent": disk.used_percent,
                })
            }),
        );
        object.insert(
            "components".to_string(),
            self.components.as_ref().map_or(Value::Null, |components| {
                Value::Array(
                    components
                        .iter()
                        .map(|component| {
                            json!({
                                "name": component.name,
                                "enabled": component.enabled,
                                "state": component.state,
                                "features": component.features,
                            })
                        })
                        .collect(),
                )
            }),
        );
        if let Some(total) = self.components_truncated {
            object.insert("components_truncated".to_string(), json!(total));
        }
        object.insert("features".to_string(), json!(self.features));
        object.insert(
            "operations".to_string(),
            self.operations.as_ref().map_or(Value::Null, |list| work_list(list)),
        );
        if let Some(total) = self.operations_truncated {
            object.insert("operations_truncated".to_string(), json!(total));
        }
        object.insert("jobs".to_string(), self.jobs.as_ref().map_or(Value::Null, |list| work_list(list)));
        object.insert("incidents".to_string(), json!(self.incidents.iter().map(incident_json).collect::<Vec<_>>()));
        if let Some(total) = self.incidents_truncated {
            object.insert("incidents_truncated".to_string(), json!(total));
        }
        if !self.missing.is_empty() {
            object.insert("missing".to_string(), json!(self.missing));
        }
        Value::Object(object)
    }
}

fn work_list(list: &[Work]) -> Value {
    Value::Array(
        list.iter()
            .map(|work| {
                json!({
                    "id": work.id,
                    "state": work.state,
                    "kind": work.kind,
                    "started_at": work.started_at,
                    "owner": work.owner,
                })
            })
            .collect(),
    )
}

fn incident_json(incident: &Incident) -> Value {
    json!({
        "id": incident.id,
        "source": incident.source,
        "at": incident.at,
        "kind": incident.kind,
        "summary": incident.summary,
    })
}

/// The whole view.
#[derive(Clone, Debug, PartialEq)]
pub struct View {
    pub generated_at: u64,
    pub nodes: Vec<NodeView>,
    pub missing_total: usize,
    /// How many observations did not fit inside [`MAX_NODES`].
    pub nodes_truncated: Option<usize>,
}

impl View {
    pub fn to_json(&self) -> Value {
        let mut object = Map::new();
        object.insert("schema".to_string(), json!(SCHEMA));
        object.insert("generated_at".to_string(), json!(self.generated_at));
        object.insert("read_only".to_string(), json!(true));
        object.insert("count".to_string(), json!(self.nodes.len()));
        object.insert(
            "nodes".to_string(),
            Value::Array(self.nodes.iter().map(NodeView::to_json).collect()),
        );
        object.insert("missing_total".to_string(), json!(self.missing_total));
        if let Some(total) = self.nodes_truncated {
            object.insert("nodes_truncated".to_string(), json!(total));
        }
        object.insert(
            "note".to_string(),
            json!(
                "Unknown fields are listed in each node's `missing` and left absent: an empty value here is \
                 never a zero. Read-only: this call changes nothing."
            ),
        );
        Value::Object(object)
    }
}

/// Record a field's presence: absent fields are named, so `missing` is the record of what was not read.
fn note(missing: &mut Vec<String>, field: &str, known: bool) -> bool {
    if !known {
        missing.push(field.to_string());
    }
    known
}

/// Build the view of one node. Every absent field becomes a name in `missing`.
pub fn node_view(observation: &Observation, now_ms: u64) -> NodeView {
    let mut missing = Vec::new();

    let role = observation.role.clone();
    note(&mut missing, "role", role.is_some());
    let online = observation.online;
    note(&mut missing, "online", online.is_some());
    let last_seen_ms = observation.last_seen_ms;
    note(&mut missing, "last_seen_ms", last_seen_ms.is_some());
    let last_seen_age_s = last_seen_ms.map(|last| now_ms.saturating_sub(last) / 1000);
    let version = observation.version.clone();
    note(&mut missing, "version", version.is_some());
    let commit = observation.commit.clone();
    note(&mut missing, "commit", commit.is_some());

    // Health is a judgement with its reasons: the collector's own reasons, plus a disk that is nearly
    // full. When nothing was read the field is absent and named - never silently "ok".
    let health = observation.health.as_ref().map(|health| {
        let mut reasons = health.reasons.clone();
        if let Some(used) = observation.disk.as_ref().and_then(|disk| disk.used_percent) {
            if used >= DISK_DEGRADED_PERCENT {
                reasons.push(format!("disk used {used:.1}%"));
            }
        }
        let state = if reasons.is_empty() || health.state != "ok" {
            health.state.clone()
        } else {
            "degraded".to_string()
        };
        Health { state, source: health.source.clone(), reasons }
    });
    note(&mut missing, "health", health.is_some());
    let disk = observation.disk.clone();
    note(&mut missing, "disk", disk.is_some());

    let mut features: Vec<String> = Vec::new();
    let mut push_feature = |name: &str| {
        if !name.is_empty() && !features.iter().any(|known| known == name) {
            features.push(name.to_string());
        }
    };
    for capability in &observation.capabilities {
        push_feature(capability);
    }
    let components_truncated = observation
        .components
        .as_ref()
        .filter(|components| components.len() > MAX_COMPONENTS)
        .map(|components| components.len());
    let components = observation.components.as_ref().map(|components| {
        let kept: Vec<Component> = components.iter().take(MAX_COMPONENTS).cloned().collect();
        for component in &kept {
            for feature in &component.features {
                push_feature(feature);
            }
        }
        kept
    });
    // `features` is derived, so it is never "unknown": an empty list with unknown components would
    // claim the node carries nothing.
    note(&mut missing, "components", components.is_some());
    if components.is_none() && features.is_empty() {
        missing.push("features".to_string());
    }

    let operations_truncated = observation
        .operations
        .as_ref()
        .filter(|list| list.len() > MAX_OPERATIONS)
        .map(|list| list.len());
    let operations = observation
        .operations
        .as_ref()
        .map(|list| list.iter().take(MAX_OPERATIONS).cloned().collect::<Vec<_>>());
    note(&mut missing, "operations", operations.is_some());
    let jobs = observation.jobs.clone();
    note(&mut missing, "jobs", jobs.is_some());

    features.sort();
    let mut incidents = observation.incidents.clone();
    incidents.retain(|incident| !incident.summary.is_empty());
    incidents.sort_by_key(|incident| std::cmp::Reverse(incident.at.unwrap_or(0)));
    let incidents_truncated = (incidents.len() > MAX_INCIDENTS).then_some(incidents.len());
    incidents.truncate(MAX_INCIDENTS);
    // `incidents` empty is a real answer (nothing recent), not an unknown one: every node answers it.

    NodeView {
        name: observation.name.clone(),
        node_id: observation.node_id.clone(),
        role,
        local_node: observation.local_node,
        online,
        last_seen_ms,
        last_seen_age_s,
        version,
        commit,
        health,
        disk,
        components,
        components_truncated,
        features,
        operations,
        operations_truncated,
        jobs,
        incidents,
        incidents_truncated,
        missing,
    }
}

/// Does a lesson name this node? Its tags are the node's name or id, or its rule mentions the name. A
/// lesson that names no node belongs to the whole fleet.
fn names_node(lesson: &Lesson, node: &NodeView) -> bool {
    let names = [
        node.name.to_lowercase(),
        node.node_id.to_lowercase(),
    ];
    for tag in &lesson.tags {
        let tag = tag.to_lowercase();
        if names.iter().any(|name| !name.is_empty() && name == &tag) {
            return true;
        }
    }
    let rule = lesson.rule.to_lowercase();
    names.iter().any(|name| name.len() > 3 && rule.contains(name.as_str()))
}

/// Build the whole view: the local node first (it is the one looking), then peers by name, so two runs
/// over the same fabric answer in the same order.
pub fn assemble(observations: &[Observation], lessons: &[Lesson], now_ms: u64) -> View {
    let mut nodes: Vec<NodeView> = observations
        .iter()
        .map(|observation| node_view(observation, now_ms))
        .collect();

    for lesson in lessons {
        let named: Vec<usize> = nodes
            .iter()
            .enumerate()
            .filter(|(_, node)| names_node(lesson, node))
            .map(|(index, _)| index)
            .collect();
        let targets: Vec<usize> = if named.is_empty() { (0..nodes.len()).collect() } else { named };
        for index in targets {
            let node = &mut nodes[index];
            if node.incidents.iter().any(|incident| incident.id == lesson.id) {
                continue;
            }
            node.incidents.push(Incident {
                id: lesson.id.clone(),
                source: "lesson".to_string(),
                at: lesson.at,
                kind: Some("lesson".to_string()),
                summary: lesson.rule.clone(),
            });
            node.incidents.sort_by_key(|incident| std::cmp::Reverse(incident.at.unwrap_or(0)));
            if node.incidents.len() > MAX_INCIDENTS {
                node.incidents_truncated = Some(node.incidents.len());
                node.incidents.truncate(MAX_INCIDENTS);
            }
        }
    }

    nodes.sort_by(|a, b| {
        b.local_node
            .cmp(&a.local_node)
            .then_with(|| a.name.cmp(&b.name))
            .then_with(|| a.node_id.cmp(&b.node_id))
    });
    let nodes_truncated = (nodes.len() > MAX_NODES).then_some(nodes.len());
    nodes.truncate(MAX_NODES);
    let missing_total = nodes.iter().map(|node| node.missing.len()).sum();
    View { generated_at: now_ms, nodes, missing_total, nodes_truncated }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn full_observation(name: &str, node_id: &str, local: bool, last_seen_ms: u64) -> Observation {
        Observation {
            name: name.to_string(),
            node_id: node_id.to_string(),
            role: Some(if local { "master".to_string() } else { "peer".to_string() }),
            local_node: local,
            online: Some(true),
            last_seen_ms: Some(last_seen_ms),
            version: Some("0.1.0".to_string()),
            commit: Some("45d8a8c5".to_string()),
            health: Some(Health::ok("runtime_info")),
            disk: Some(Disk {
                available_bytes: Some(40_000_000_000),
                total_bytes: Some(100_000_000_000),
                used_percent: Some(60.0),
            }),
            components: Some(vec![
                Component {
                    name: "wa-whatsapp".to_string(),
                    enabled: true,
                    state: "running".to_string(),
                    features: vec!["whatsapp_send".to_string(), "whatsapp_search".to_string()],
                },
                Component {
                    name: "wa-email".to_string(),
                    enabled: true,
                    state: "running".to_string(),
                    features: vec!["email_send".to_string()],
                },
            ]),
            operations: Some(vec![Work {
                id: "op-1".to_string(),
                state: "running".to_string(),
                kind: Some("bash".to_string()),
                started_at: Some(last_seen_ms - 5_000),
                owner: Some("session-1".to_string()),
            }]),
            jobs: Some(vec![Work {
                id: "job-1".to_string(),
                state: "queued".to_string(),
                kind: Some("trigger".to_string()),
                started_at: None,
                owner: None,
            }]),
            incidents: Vec::new(),
            capabilities: vec!["bash".to_string(), "whatsapp_send".to_string()],
        }
    }

    /// A three-node local fabric: this node, and two peers as the registry knows them.
    fn fabric() -> Vec<Observation> {
        let now = 1_794_000_000_000u64;
        let mut peer_a = full_observation("nextcloud", "id-nextcloud", false, now - 12_000);
        // A peer the registry knows nothing about beyond reachability: the honest half-answer.
        peer_a.version = None;
        peer_a.commit = None;
        peer_a.health = None;
        peer_a.disk = None;
        peer_a.components = None;
        peer_a.operations = None;
        peer_a.jobs = None;
        let mut peer_b = full_observation("mail", "id-mail", false, now - 600_000);
        peer_b.online = Some(false);
        peer_b.health = Some(Health::unknown("rendezvous", "peer_offline_no_sample"));
        vec![full_observation("laptop", "id-laptop", true, now), peer_a, peer_b]
    }

    #[test]
    fn a_three_node_fabric_answers_every_field() {
        let now = 1_794_000_006_000u64;
        let view = assemble(&fabric(), &[], now);
        assert_eq!(view.nodes.len(), 3);
        // The local node first, then peers by name - the same fabric answers in the same order.
        let names: Vec<&str> = view.nodes.iter().map(|node| node.name.as_str()).collect();
        assert_eq!(names, vec!["laptop", "mail", "nextcloud"]);

        let laptop = &view.nodes[0];
        assert!(laptop.complete(), "missing: {:?}", laptop.missing);
        for field in FIELDS {
            assert!(
                !laptop.missing.iter().any(|missing| missing == field),
                "{field} must be answered for a fully-known node"
            );
        }
        let json = laptop.to_json();
        for field in FIELDS {
            assert!(json.get(field).is_some(), "the record must carry {field}: {json}");
            assert!(!json[field].is_null(), "{field} is known here, so it cannot be null: {json}");
        }
        assert_eq!(laptop.last_seen_age_s, Some(6));
        assert_eq!(laptop.health.as_ref().unwrap().state, "ok");
        // Features are the union of what the node advertises and what its components carry.
        assert_eq!(
            laptop.features,
            vec![
                "bash".to_string(),
                "email_send".to_string(),
                "whatsapp_search".to_string(),
                "whatsapp_send".to_string()
            ]
        );
        assert_eq!(laptop.operations.as_ref().unwrap().len(), 1);
        assert_eq!(laptop.jobs.as_ref().unwrap()[0].state, "queued");
        assert_eq!(laptop.incidents.len(), 0, "empty incidents is an answer, not an unknown");
    }

    #[test]
    fn a_field_nobody_read_is_named_instead_of_invented() {
        let now = 1_794_000_006_000u64;
        let view = assemble(&fabric(), &[], now);
        let peer = view.nodes.iter().find(|node| node.name == "nextcloud").expect("peer");
        assert!(!peer.complete());
        for field in ["version", "commit", "health", "disk", "components", "operations", "jobs"] {
            assert!(peer.missing.iter().any(|missing| missing == field), "{field} must be missing");
        }
        // Online and last_seen *were* read, so they are answered - and the age is real, not a zero.
        assert_eq!(peer.online, Some(true));
        assert_eq!(peer.last_seen_age_s, Some(18));
        let json = peer.to_json();
        assert_eq!(json["disk"], Value::Null, "an unread disk is null, never 0%");
        assert_eq!(json["health"], Value::Null);
        assert_eq!(json["version"], Value::Null);
        assert!(json["missing"].as_array().unwrap().iter().any(|field| field == "disk"));

        // A node that answers "unknown" is present, with its reason: absent and unknown are different.
        let mail = view.nodes.iter().find(|node| node.name == "mail").expect("mail");
        assert!(!mail.missing.iter().any(|field| field == "health"));
        let health = mail.health.as_ref().expect("health");
        assert_eq!(health.state, "unknown");
        assert_eq!(health.reasons, vec!["peer_offline_no_sample".to_string()]);
        assert_eq!(mail.online, Some(false));
        assert_eq!(view.missing_total, peer.missing.len());
    }

    #[test]
    fn a_nearly_full_disk_degrades_health_with_its_reason() {
        let mut observation = full_observation("laptop", "id-laptop", true, 1_000_000);
        observation.disk = Some(Disk {
            available_bytes: Some(1_000_000),
            total_bytes: Some(100_000_000),
            used_percent: Some(95.5),
        });
        let node = node_view(&observation, 1_000_000);
        let health = node.health.expect("health");
        assert_eq!(health.state, "degraded");
        assert!(health.reasons.iter().any(|reason| reason == "disk used 95.5%"));
    }

    #[test]
    fn incidents_come_from_telemetry_and_lessons_without_duplicating_or_leaking_text() {
        let now = 1_794_000_006_000u64;
        let mut observations = fabric();
        observations[0].incidents = vec![Incident {
            id: "op-9".to_string(),
            source: "telemetry".to_string(),
            at: Some(now - 60_000),
            kind: Some("operation_failed".to_string()),
            summary: "operation op-9 settled as failed".to_string(),
        }];
        let lessons = vec![
            Lesson {
                id: "les-rendezvous-admin-set-20261106".to_string(),
                at: Some(now - 86_400_000),
                rule: "Never edit the admin set; use mesh push-roster.".to_string(),
                tags: vec![],
            },
            // A lesson that names a node is reported there only.
            Lesson {
                id: "les-nextcloud-20261106".to_string(),
                at: Some(now - 3_600_000),
                rule: "nextcloud drops out when the admin set changes.".to_string(),
                tags: vec!["nextcloud".to_string()],
            },
        ];
        let view = assemble(&observations, &lessons, now);
        let laptop = view.nodes.iter().find(|node| node.name == "laptop").unwrap();
        let nextcloud = view.nodes.iter().find(|node| node.name == "nextcloud").unwrap();
        // The fleet-wide lesson reaches every node; the telemetry incident stays on its own.
        let laptop_ids: Vec<&str> = laptop.incidents.iter().map(|incident| incident.id.as_str()).collect();
        assert_eq!(laptop_ids, vec!["op-9", "les-rendezvous-admin-set-20261106"]);
        let nextcloud_ids: Vec<&str> =
            nextcloud.incidents.iter().map(|incident| incident.id.as_str()).collect();
        assert_eq!(nextcloud_ids, vec!["les-nextcloud-20261106", "les-rendezvous-admin-set-20261106"]);
        assert!(nextcloud.incidents.iter().all(|incident| incident.source == "lesson"));
        // No field can carry a message body: the incident keys are exactly these five.
        let json = laptop.to_json();
        let incident = &json["incidents"][0];
        let mut keys: Vec<&str> = incident.as_object().unwrap().keys().map(|key| key.as_str()).collect();
        keys.sort();
        assert_eq!(keys, vec!["at", "id", "kind", "source", "summary"]);
    }

    #[test]
    fn the_view_is_bounded_and_says_what_it_trimmed() {
        let now = 1_000_000u64;
        let mut observations: Vec<Observation> =
            (0..MAX_NODES + 3).map(|index| full_observation(&format!("node-{index:03}"), &format!("id-{index}"), false, now)).collect();
        observations[0].components = Some(
            (0..MAX_COMPONENTS + 5)
                .map(|index| Component {
                    name: format!("component-{index:03}"),
                    enabled: true,
                    state: "running".to_string(),
                    features: Vec::new(),
                })
                .collect(),
        );
        observations[0].incidents = (0..MAX_INCIDENTS + 2)
            .map(|index| Incident {
                id: format!("incident-{index}"),
                source: "telemetry".to_string(),
                at: Some(now - index as u64),
                kind: Some("operation_failed".to_string()),
                summary: format!("operation incident-{index} settled as failed"),
            })
            .collect();
        let view = assemble(&observations, &[], now);
        assert_eq!(view.nodes.len(), MAX_NODES);
        assert_eq!(view.nodes_truncated, Some(MAX_NODES + 3));
        let node = view.nodes.iter().find(|node| node.name == "node-000").expect("trimmed node");
        assert_eq!(node.components.as_ref().unwrap().len(), MAX_COMPONENTS);
        assert_eq!(node.components_truncated, Some(MAX_COMPONENTS + 5));
        assert_eq!(node.incidents.len(), MAX_INCIDENTS);
        assert_eq!(node.incidents_truncated, Some(MAX_INCIDENTS + 2));
        assert_eq!(view.to_json()["read_only"], json!(true));
        assert_eq!(view.to_json()["schema"], json!(SCHEMA));
        assert!(read_only());
        assert_eq!(CAPABILITY, "fleetview");
    }

    #[test]
    fn the_record_has_no_field_for_message_text() {
        // The view reports facts about nodes, never words a person wrote. If a future field could carry
        // a message, this list is where that decision has to be made deliberately.
        let allowed = [
            "name",
            "node_id",
            "local_node",
            "role",
            "online",
            "last_seen_ms",
            "last_seen_age_s",
            "version",
            "commit",
            "health",
            "disk",
            "components",
            "components_truncated",
            "features",
            "operations",
            "operations_truncated",
            "jobs",
            "incidents",
            "incidents_truncated",
            "missing",
        ];
        let view = assemble(&fabric(), &[], 1_794_000_006_000);
        for node in &view.nodes {
            let json = node.to_json();
            for key in json.as_object().unwrap().keys() {
                assert!(allowed.contains(&key.as_str()), "unexpected field {key} in a fleet view");
            }
        }
        let forbidden = ["text", "prompt", "body", "content", "message", "transcript"];
        let serialized = assemble(&fabric(), &[], 1_794_000_006_000).to_json().to_string();
        for word in forbidden {
            assert!(!serialized.contains(&format!("\"{word}\"")), "{word} has no place in a fleet view");
        }
    }
}
