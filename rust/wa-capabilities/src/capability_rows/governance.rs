//! Node governance (docs/GRANT-POLICY.md, docs/TELEMETRY.md): the grant policy's state and this
//! node's telemetry. The handlers are in wa_governance.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("policy_status", ReadOnly, wa_governance::node_policy::capability, "The grant policy's state as JSON: file and load error, decision counters, recent refusals without target text, and the audit trail's health"),
    plain!("telemetry", ReadOnly, wa_governance::node_telemetry::capability, "This node's telemetry as Prometheus text or JSON: component and host-call latency, service health, sampled spans, rollups and the bounded stores' usage"),
];
