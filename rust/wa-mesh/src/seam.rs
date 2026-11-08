//! The route: the native rule, or the `wa:mesh` component (`docs/CORE-SPLIT.md`, "mesh/fleet").
//!
//! Every decision the mesh makes goes through this module, so there is exactly **one** place that knows
//! where a decision came from. `WA_MESH_COMPONENT=1` routes it to the installed `wa:mesh` guest
//! (`wa_kernel_runtime::mesh_host`); **without it, or when the component cannot answer, the native path
//! runs and every call site below is the code `wa-mesh` always ran**.
//!
//! What is routed, and why each one is a *decision* rather than transport:
//!
//! | routed | native | the seam answers |
//! | --- | --- | --- |
//! | [`decide`] | `wa_mesh_core::hierarchy::authorize` | `decide(grants, caller, target, verb) -> verdict` |
//! | [`verify_roster`] | `Roster::verify` | `verify-roster(document, key, now) -> levels` |
//! | [`verb_of`] | `Verb::from_capability` | `verb(capability) -> string` |
//! | [`render_audit`] | `Event::render` | `render-audit(event) -> string` |
//! | [`addresses`] | `PeerCache::addresses` | `addresses(target, learned) -> list<string>` |
//! | [`attest_message`] | `attest::message` | `attest-message(…) -> string` |
//! | [`verify_attestation`] | `attest::verify` | `verify-ticket(ticket, …) -> ticket-facts` |
//!
//! What is deliberately **not** routed, because it is transport or a process's own business: the
//! listener, the relay, the rendezvous client, the HTTP dialect, the peer cache file, the policy file,
//! the replay window, the one-shot loopback tickets, and the node's identity (which *signs* the message
//! this seam composes; no key crosses into a component).
//!
//! Three rules this module is the place for:
//!
//! * **A refusal is not a failure.** A roster that does not verify, or an attestation that is not this
//!   call's, comes back as the answer it is, in the native vocabulary. Only "the component could not
//!   answer" falls back, and it says so: one log line per (operation, reason), because a silent fallback
//!   makes a broken component look like a working fleet.
//! * **The words do not change.** A refusal's sentence and an audit line cross the boundary as the
//!   strings the native path produces (`RosterProblem::sentence`, `Event::render`), so the two paths are
//!   comparable field for field — which is exactly what `scripts/test-mesh-component.sh` does.
//! * **The gate is asked per call.** `WA_MESH_COMPONENT` is read on every call (one small environment
//!   lookup), so a parity test runs both paths in one process; the *availability* of the artifact is
//!   resolved once, because that is a `stat`, not a rule.
use std::sync::{Mutex, OnceLock};

use serde_json::{json, Value};

use crate::audit::Event;
use crate::cache::PeerCache;
use crate::hierarchy::{self, Verb, Verdict};
use crate::policy::MeshPolicy;
use crate::roster::{Roster, RosterError, RosterNode};
use wa_mesh_core::attest::{self, AttestError, Bound};

/// The switch: the process variable, and nothing else. An empty value is not a statement.
pub fn enabled() -> bool {
    matches!(std::env::var("WA_MESH_COMPONENT").as_deref().map(str::trim), Ok("1"))
}

/// Which operations this node actually routes, from `WA_MESH_COMPONENT_OPS`: a comma-separated list of
/// `decide,verify_roster,verb,render_audit,addresses,attest_message,verify_ticket`. Unset or empty means
/// all of them.
///
/// It exists because the measurement says the operations are not equally worth a guest call
/// (`scripts/bench-mesh.sh`, "Cost"): a *decision* is a policy question whose rule an operator may want
/// to swap, while an audit line and a dial order are formatting, and the seam costs the same either way.
/// An operation left out runs natively and silently — it is a configuration choice, not a fallback, and
/// `docs/MESH.md` records which default the measurement supports.
pub fn routes(op: &str) -> bool {
    match std::env::var("WA_MESH_COMPONENT_OPS") {
        Ok(text) => {
            let text = text.trim();
            text.is_empty() || text.split(',').any(|name| name.trim() == op)
        }
        Err(_) => true,
    }
}

/// Whether the installed component can answer at all: `Ok(sha256)` or the reason it cannot.
///
/// The answer is a file read and a hash of the artifact, so it is cached — but **keyed by where the
/// artifact was asked for** (the two environment variables the loader resolves). A test that points the
/// loader at a checkout build, or at a directory with nothing in it, gets its own answer instead of the
/// process's first one, and can never leave the rest of a run quietly on the native path.
type Availability = Mutex<Option<(String, Result<String, String>)>>;

fn availability() -> &'static Availability {
    static AVAILABILITY: OnceLock<Availability> = OnceLock::new();
    AVAILABILITY.get_or_init(|| Mutex::new(None))
}

/// The two variables that say where the artifact is, as the cache key.
fn artifact_key() -> String {
    let read = |name: &str| std::env::var(name).unwrap_or_default();
    format!("{}|{}", read("WA_MESH_COMPONENT_WASM"), read("WA_COMPONENTS_DIR"))
}

fn fallback_log() -> &'static Mutex<std::collections::HashSet<String>> {
    static LOGGED: OnceLock<Mutex<std::collections::HashSet<String>>> = OnceLock::new();
    LOGGED.get_or_init(|| Mutex::new(std::collections::HashSet::new()))
}

/// Forget what was learned about the artifact and the fallbacks already reported (a test that installs
/// the component, swaps it for another build, or asserts on the log).
pub fn reset() {
    if let Ok(mut held) = availability().lock() {
        *held = None;
    }
    if let Ok(mut logged) = fallback_log().lock() {
        logged.clear();
    }
}

/// The fallbacks reported so far, for a test that asserts a broken component is *visible*.
pub fn fallbacks() -> Vec<String> {
    fallback_log()
        .lock()
        .map(|logged| logged.iter().cloned().collect())
        .unwrap_or_default()
}

/// One line per (operation, reason). A wedged component must be visible, and a log flooded with the same
/// line on every call is not visible.
fn note_fallback(op: &str, reason: &str) {
    let key = format!("{op}|{reason}");
    let fresh = match fallback_log().lock() {
        Ok(mut logged) => logged.insert(key),
        Err(_) => true,
    };
    if fresh {
        eprintln!("mesh: {op} decided natively: {reason}");
    }
}

/// What the component said. The three cases are the seam's, not this module's invention: an answer, a
/// *refusal* (a decision the component made, which the native rule would make too), and a failure to
/// answer. Only the third falls back.
enum Answer {
    Result(Value),
    Refused(Value),
}

/// The component's answer to one request, or the reason there is none. The reason is the *classification*
/// (`component_unavailable`, `component_wedged`, …), never a body: a log line never carries a document.
fn ask(request: Value) -> Result<Answer, String> {
    {
        let key = artifact_key();
        let mut held = availability().lock().map_err(|_| "seam_gate_poisoned".to_string())?;
        if held.as_ref().map(|(cached, _)| cached != &key).unwrap_or(true) {
            *held = Some((key.clone(), wa_kernel_runtime::mesh_host::available()));
        }
        match held.as_ref().map(|(_, answer)| answer) {
            Some(Ok(_)) => {}
            Some(Err(reason)) => return Err(reason.clone()),
            None => return Err("component_unavailable:unasked".to_string()),
        }
    }
    let answer = wa_kernel_runtime::mesh_host::call(&request);
    if !answer.get("ok").and_then(Value::as_bool).unwrap_or(false) {
        let error = answer.get("error").and_then(Value::as_str).unwrap_or("component_failed");
        // The first two colon-separated words are the classification; the rest is diagnostics.
        let class = error.split(':').take(2).collect::<Vec<_>>().join(":");
        return Err(if class.is_empty() { error.to_string() } else { class });
    }
    if let Some(refused) = answer.get("refused") {
        return Ok(Answer::Refused(refused.clone()));
    }
    Ok(Answer::Result(answer.get("result").cloned().unwrap_or(Value::Null)))
}

/// Run one routed operation: the component's answer, or the native rule with one log line. A refusal is
/// not a fallback — it is an answer the native rule would repeat — so it is handed to `refusal`, which
/// returns the caller's own answer or `None` (and then the native path runs, visibly).
fn routed<T>(
    op: &str,
    request: Value,
    native: impl FnOnce() -> T,
    read: impl FnOnce(&Value) -> T,
    refusal: impl FnOnce(&Value) -> Option<T>,
) -> T {
    if !enabled() || !routes(op) {
        return native();
    }
    match ask(request) {
        Ok(Answer::Result(answer)) => read(&answer),
        Ok(Answer::Refused(refused)) => match refusal(&refused) {
            Some(answer) => answer,
            None => {
                note_fallback(op, "seam_refusal_unusable");
                native()
            }
        },
        Err(reason) => {
            note_fallback(op, &reason);
            native()
        }
    }
}

// -------------------------------------------------------------------------------------- the decisions

/// `authorize(caller, target, verb)`, routed.
pub fn decide(policy: &MeshPolicy, caller: &RosterNode, target: &RosterNode, verb: Verb, now_s: u64) -> Verdict {
    let native = || hierarchy::authorize(policy, caller, target, verb, now_s);
    if !enabled() || !routes("decide") {
        return native();
    }
    let request = json!({
        "op": "decide",
        "grants": policy.grants.iter().map(|grant| json!({
            "caller": grant.caller.as_str(),
            "target": grant.target.as_str(),
            "verb": grant.verb.as_str(),
            "effect": match grant.effect { crate::policy::Effect::Allow => "allow", crate::policy::Effect::Deny => "deny" },
            "note": grant.note,
        })).collect::<Vec<_>>(),
        "caller": node_json(caller),
        "target": node_json(target),
        "verb": verb.as_str(),
        "now": now_s,
    });
    routed(
        "decide",
        request,
        native,
        |answer| Verdict {
            allow: answer.get("allow").and_then(Value::as_bool).unwrap_or(false),
            // The reason is a `&'static str` on the native side; the seam's answer is one of the same
            // words, so it is looked up rather than trusted as text.
            reason: static_reason(answer.get("reason").and_then(Value::as_str).unwrap_or("hierarchy_denied")),
            detail: answer.get("detail").and_then(Value::as_str).unwrap_or_default().to_string(),
        },
        // `decide` answers a verdict and never refuses; a refusal here is a broken seam.
        |_| None,
    )
}

/// The verb a capability needs, routed (a pure classification with no input but the name).
pub fn verb_of(capability: &str) -> Verb {
    let native = || Verb::from_capability(capability);
    if !enabled() || !routes("verb") {
        return native();
    }
    let request = json!({"op": "verb", "capability": capability});
    routed(
        "verb",
        request,
        native,
        |answer| match answer.as_str() {
            Some("read") => Verb::Read,
            Some("control") => Verb::Control,
            _ => Verb::Call,
        },
        |_| None,
    )
}

/// `Roster::verify`, routed. `Ok(())` is the same answer on both paths; an `Err` is the operator's
/// sentence about *why*, and it is the same sentence on both paths: a component's case comes back as the
/// string `RosterProblem::sentence()` writes, so a caller never learns two vocabularies for one mistake.
pub fn verify_roster(roster: &Roster, fleet_public_key: &str, now_s: u64) -> Result<(), RosterError> {
    let native = || roster.verify(crate::identity::crypto(), fleet_public_key, now_s);
    if !enabled() || !routes("verify_roster") {
        return native();
    }
    // The document is passed as text because that is what the signature covers.
    let document = match serde_json::to_string(roster) {
        Ok(document) => document,
        Err(error) => {
            note_fallback("verify_roster", &format!("seam_encode:{error}"));
            return native();
        }
    };
    let request = json!({"op": "verify_roster", "document": document, "key": fleet_public_key, "now": now_s});
    let mut disagreement = None;
    let answer = routed(
        "verify_roster",
        request,
        native,
        |answer| {
            // The levels the component answered are the ones the roster must be used with. The node's own
            // copy came from the same document, so they are compared rather than ignored: a disagreement
            // falls back to the native verdict (and says so), it is never a silently different level.
            let levels = answer.get("levels").and_then(Value::as_array).cloned().unwrap_or_default();
            for (index, node) in roster.nodes.iter().enumerate() {
                let level = levels.get(index).and_then(|entry| entry.get("level")).and_then(Value::as_u64);
                if level != Some(node.level as u64) {
                    disagreement = Some(format!("seam_level_mismatch:{}", node.name));
                }
            }
            Ok(())
        },
        // A refusal is this function's answer: the sentence the component's case came from.
        |refused| {
            refused
                .get("error")
                .and_then(Value::as_str)
                .map(|sentence| Err(RosterError(sentence.to_string())))
        },
    );
    if let Some(reason) = disagreement {
        note_fallback("verify_roster", &reason);
        return native();
    }
    answer
}

/// `Event::render`, routed.
pub fn render_audit(event: &Event) -> String {
    let native = || event.render();
    if !enabled() || !routes("render_audit") {
        return native();
    }
    let request = json!({"op": "render_audit", "event": {
        "kind": event.kind,
        "from": event.from,
        "to": event.to,
        "from_level": event.from_level,
        "to_level": event.to_level,
        "verb": event.verb,
        "decision": event.decision,
        "reason": event.reason,
        "transport": event.transport,
        "addr_class": event.class,
        "ok": event.ok,
        "status": event.status,
        "ms": event.ms,
        "attempt": event.attempt,
    }});
    routed(
        "render_audit",
        request,
        native,
        |answer| match answer.as_str() {
            Some(line) => line.to_string(),
            // A component that answered something that is not a line is not an answer: the native
            // renderer is the only writer of the format.
            None => event.render(),
        },
        |_| None,
    )
}

/// `PeerCache::addresses`, routed.
pub fn addresses(cache: &PeerCache, node: &RosterNode) -> Vec<String> {
    let native = || cache.addresses(node);
    if !enabled() || !routes("addresses") {
        return native();
    }
    let learned: Vec<String> = cache
        .peer(&node.node_id)
        .map(|entry| entry.addresses.clone())
        .unwrap_or_default();
    let request = json!({"op": "addresses", "target": node_json(node), "learned": learned});
    routed(
        "addresses",
        request,
        native,
        |answer| {
            answer
                .as_array()
                .map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_string)).collect())
                .unwrap_or_else(|| cache.addresses(node))
        },
        |_| None,
    )
}

/// The exact bytes an attestation signs, routed. The *signature* stays here: the key is the node's.
pub fn attest_message(node_id: &str, caller: &str, verb: &str, capability: &str, caller_signature: &str, ts: u64) -> String {
    let native = || attest::message(node_id, caller, verb, capability, caller_signature, ts);
    if !enabled() || !routes("attest_message") {
        return native();
    }
    let request = json!({
        "op": "attest_message",
        "node_id": node_id,
        "caller": caller,
        "verb": verb,
        "capability": capability,
        "caller_signature": caller_signature,
        "ts": ts,
    });
    routed(
        "attest_message",
        request,
        native,
        |answer| answer.as_str().map(str::to_string).unwrap_or_else(native),
        |_| None,
    )
}

/// Check one attestation, routed. The component answers `absent`, `mismatch`, `bad-signature` or
/// `stale`, in the native slugs; a component that cannot answer falls back to the same rule.
#[allow(clippy::too_many_arguments)]
pub fn verify_attestation(
    node_public_key: &str,
    node_id: &str,
    caller: &str,
    verb: &str,
    capability: &str,
    caller_signature: &str,
    ts: u64,
    signature: &str,
    now_s: u64,
) -> Result<Bound, AttestError> {
    let native = || {
        attest::verify(
            crate::identity::crypto(),
            node_public_key,
            node_id,
            caller,
            verb,
            capability,
            caller_signature,
            ts,
            signature,
            now_s,
        )
    };
    if !enabled() || !routes("verify_ticket") {
        return native();
    }
    let request = json!({
        "op": "verify_ticket",
        "ticket": {"caller": caller, "verb": verb, "capability": capability, "ts": ts, "signature": signature},
        "node_id": node_id,
        "node_public_key": node_public_key,
        "caller_signature": caller_signature,
        "now": now_s,
    });
    match ask(request) {
        Ok(Answer::Result(answer)) => Ok(Bound {
            node_id: answer.get("node_id").and_then(Value::as_str).unwrap_or_default().to_string(),
            caller: answer.get("caller").and_then(Value::as_str).unwrap_or_default().to_string(),
            verb: answer.get("verb").and_then(Value::as_str).unwrap_or_default().to_string(),
            capability: answer.get("capability").and_then(Value::as_str).unwrap_or_default().to_string(),
            ts: answer.get("ts").and_then(Value::as_u64).unwrap_or(0),
        }),
        // A refused attestation is an answer, with the same slug the native path names.
        Ok(Answer::Refused(refused)) => Err(attest_refusal(&refused)),
        Err(reason) => {
            note_fallback("verify_ticket", &reason);
            native()
        }
    }
}

/// A component's attestation refusal, as the native error. The slugs are `AttestError::slug`'s, so the
/// two paths name the same failure the same way.
fn attest_refusal(refused: &Value) -> AttestError {
    let slug = refused.get("error").and_then(Value::as_str).unwrap_or("attestation_bad_signature");
    match slug {
        "attestation_absent" => AttestError::Absent,
        "attestation_caller" => AttestError::Mismatch("caller"),
        "attestation_verb" => AttestError::Mismatch("verb"),
        "attestation_capability" => AttestError::Mismatch("capability"),
        "attestation_stale" => AttestError::Stale(refused.get("age").and_then(Value::as_u64).unwrap_or(0)),
        _ => AttestError::BadSignature,
    }
}

/// The two node facts a decision needs, as the seam's record.
fn node_json(node: &RosterNode) -> Value {
    json!({
        "id": node.node_id,
        "public_key": node.public_key,
        "name": node.name,
        "level": node.level,
        "addresses": node.addresses,
        "revoked_at": node.revoked_at,
    })
}

/// The six reason words a verdict may carry, as the `&'static str` the native `Verdict` holds. An
/// unknown word becomes `error`: a reason nobody can act on is still a reason, and it prints as itself.
fn static_reason(word: &str) -> &'static str {
    match word {
        "hierarchy_allowed" => "hierarchy_allowed",
        "hierarchy_denied" => "hierarchy_denied",
        "grant_allowed" => "grant_allowed",
        "grant_denied" => "grant_denied",
        "revoked" => "revoked",
        "self_call" => "self_call",
        "grant_invalid" => "grant_invalid",
        _ => "error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{fleet_key, node, roster_of};

    /// With the switch unset, every routed operation is the native one — the property the whole split
    /// rests on. (The component path is `scripts/test-mesh-component.sh`'s: it runs this whole suite with
    /// `WA_MESH_COMPONENT=1`.)
    #[test]
    fn without_the_switch_the_native_rule_answers() {
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let _env = crate::testkit::EnvGuard::set(&[("WA_MESH_COMPONENT", None)]);
        assert!(!enabled());
        let roster = roster_of(&fleet_key(), vec![node("laptop", 0, &[]), node("oracle", 1, &[])]);
        let policy = MeshPolicy::empty();
        let now = 1_762_000_100;
        assert_eq!(
            decide(&policy, &roster.nodes[0], &roster.nodes[1], Verb::Control, now),
            hierarchy::authorize(&policy, &roster.nodes[0], &roster.nodes[1], Verb::Control, now)
        );
        assert_eq!(verb_of("bash"), Verb::Control);
        let fleet = fleet_key();
        assert_eq!(
            verify_roster(&roster, &fleet.public_key, crate::wire::now_seconds()),
            roster.verify(crate::identity::crypto(), &fleet.public_key, crate::wire::now_seconds())
        );
        let event = Event::new("call", "aa", "bb").verb("read").verdict("allow", "hierarchy_allowed");
        assert_eq!(render_audit(&event), event.render());
        assert_eq!(
            attest_message("3f2a", "8c11", "read", "sessions", "ab12", 7),
            attest::message("3f2a", "8c11", "read", "sessions", "ab12", 7)
        );
    }

    /// A component that was asked for and is not installed is a *reported* fallback, not a silent one, and
    /// the answer is still the native one.
    #[test]
    fn a_missing_component_falls_back_with_a_reason_and_still_decides() {
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let _env = crate::testkit::EnvGuard::set(&[
            ("WA_MESH_COMPONENT", Some("1")),
            ("WA_MESH_COMPONENT_WASM", None),
            ("WA_COMPONENTS_DIR", Some("/nonexistent/components-for-the-seam-test")),
        ]);
        reset();
        let roster = roster_of(&fleet_key(), vec![node("laptop", 0, &[]), node("oracle", 1, &[])]);
        let verdict = decide(&MeshPolicy::empty(), &roster.nodes[0], &roster.nodes[1], Verb::Control, 1_762_000_100);
        assert!(verdict.is_allow());
        assert_eq!(verdict.reason, "hierarchy_allowed");
        assert!(
            fallbacks().iter().any(|key| key.starts_with("decide|component_unavailable")),
            "the fallback is visible: {:?}",
            fallbacks()
        );
        reset();
    }
}
