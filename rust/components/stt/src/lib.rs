//! The speech queue's wire layer as a component (`wa:stt`, `docs/QUEUE.md` phase 2).
//!
//! It exports five operations and imports **nothing**: no kv (the queue is the node's), no audio store,
//! no socket (the listener and the relay are the kernel's), no clock (`now` is an argument), no key
//! (`host.sign` is the interpreter's). What it holds is one thing: the `rid` ledger of the calls it
//! has already answered, which is the admission rule's memory — the host serialises its calls to this
//! instance, so one instance is one ledger, exactly as the node had one.
//!
//! The rules are `wa-stt-remote`'s, the same crate the node links: this file translates records to that
//! crate's values and back, and adds nothing of its own. The crate is pure (it has no wasmtime, no
//! threads and no I/O), so it builds for wasip2 as it is — measured, not assumed.
use std::cell::RefCell;

use serde_json::Value;
use wa_stt_remote::protocol::{sanitize as wire_sanitize, Admission, Envelope as Wire, Op, Reply, TransportSignature, MAX_REPLAY_ENTRIES};

wit_bindgen::generate!({ path: "../../../wit/stt", world: "stt-component", generate_all });

use crate::exports::wa::stt::stt::Guest;
use crate::wa::stt::types::{Admitted, Envelope};

/// The component: no state of its own beyond the ledger below.
struct SttComponent;

thread_local! {
    /// This node's admission ledger, and what it was built for. Rebuilt when the node id, the owner's
    /// node list or the skew window changes — a roster edit must not leave yesterday's caller list in
    /// force — and kept otherwise, because the ids it remembers are why a replayed call is refused.
    static LEDGER: RefCell<Option<(String, Admission)>> = const { RefCell::new(None) };
}

fn envelope_of(wire: &Wire) -> Envelope {
    Envelope {
        op: wire.op.as_str().to_string(),
        from_node: wire.from.clone(),
        to: wire.to.clone(),
        ts_ms: wire.ts_ms,
        rid: wire.rid.clone(),
        body_json: wire.body.to_string(),
    }
}

impl Guest for SttComponent {
    async fn admit(me: String, owner_nodes: Vec<String>, skew_ms: i64, bytes: Vec<u8>, caller: String, now_ms: i64) -> Admitted {
        // The decode first: an envelope that is not the protocol's cannot name a caller or a target.
        let envelope = match Wire::decode(&bytes) {
            Ok(envelope) => envelope,
            Err(refusal) => return refused(&refusal),
        };
        // The transport verified the caller's key over the body that carries this envelope
        // (`server.lua` `verify_peer`), so the inner check is not a second verification of the same
        // bytes: target, caller, timestamp and replay are what must still be checked here, on the
        // envelope's own fields — the same order and the same closure the node module used.
        // The transport's caller the node verified must be the envelope's own `from`: a peer cannot
        // speak for another node by rewriting one field. Checked BEFORE the ledger, so a call refused
        // for this reason never records its rid — the order the node module used.
        if envelope.from != caller {
            return refused(&wa_stt_remote::protocol::Refusal::UnknownCaller);
        }
        let key = format!("{me}\u{1}{skew_ms}\u{1}{}", owner_nodes.join("\u{1}"));
        let refusal = LEDGER.with(|held| {
            let mut held = held.borrow_mut();
            let stale = held.as_ref().map(|(for_key, _)| for_key != &key).unwrap_or(true);
            if stale {
                *held = Some((key.clone(), Admission::new(me.clone(), owner_nodes.clone()).with_skew_ms(skew_ms)));
            }
            let admission = &mut held.as_mut().expect("ledger installed").1;
            admission.admits(
                &envelope,
                TransportSignature { ts_ms: envelope.ts_ms, body_sha256_hex: "", signature: "" },
                now_ms,
                MAX_REPLAY_ENTRIES,
                &|_, _, _| true,
            )
        });
        match refusal {
            Ok(()) => Admitted::Call(envelope_of(&envelope)),
            Err(refusal) => refused(&refusal),
        }
    }

    async fn reply_ok(body_json: String) -> Vec<u8> {
        let body: Value = serde_json::from_str(&body_json).unwrap_or(Value::Null);
        Reply::ok(body).encode()
    }

    fn sanitize(text: String) -> String {
        wire_sanitize(&text)
    }

}

/// The wire reply for a refusal: the bytes the peer reads, produced from the same `Refusal` the native
/// path produces, so the two paths answer one vocabulary.
fn refused(refusal: &wa_stt_remote::protocol::Refusal) -> Admitted {
    Admitted::Refused(crate::wa::stt::types::RefusalWord {
        word: refusal.as_str(),
        bytes: Reply::Refused(refusal.clone()).encode(),
    })
}

export!(SttComponent);
