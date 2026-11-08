//! `wa:kernel/vision`: the kernel's OCR reader, served to a `wa:kernel@0.2` service that opts into it
//! by importing `wa:kernel/vision@0.2.0` (`wit/kernel-v2/kernel.wit`, `world service-vision`).
//!
//! The interface is not part of `world service-component`: a world's imports are obligations, and the
//! components that never read an image should not be built against a worker they never start. A guest
//! that imports vision is served it here; `imports.rs` (`KERNEL_V2_OPTIONAL`) is what tells the
//! supervisor that importing it is not a wait for a provider.
//!
//! Two gates before any work: the manifest capability `ocr: true` (the grant) and the node policy
//! (`ocr.read`, no target - the call itself is the capability, as `stt.start` is). Then the read runs
//! on its own thread and the guest task is parked on a `Slot`, exactly as `http.send` and
//! `websocket.connect` park it: the store's other tasks keep running while the worker decodes.
//!
//! Never a log line: this module reports the reason word and the elapsed time, never the text. The
//! text goes back to the guest, which owns the index it lands in (`docs/WHATSAPP-OCR.md`).
use crate::service_components_v2::{who, State};
use crate::service_io::{Slot, SlotFuture};
use crate::service_ocr;
use wa_governance::node_telemetry::HostCallGuard;
use wa_grant_policy::Decision;
use wasmtime::component::Accessor;

wasmtime::component::bindgen!({
    path: "../../wit/kernel-v2",
    world: "service-vision",
});

use wa::kernel::types::Error as KError;

/// Ask the node policy before the reader does anything: the capability is `ocr.read` and it names no
/// target (the call itself is what an operator grants or refuses, as `stt.start` is).
fn gate(name: &str, capability: &str) -> Result<(), KError> {
    match wa_governance::node_policy::check(name, capability, None) {
        Decision::Allow => Ok(()),
        Decision::RateLimited { retry_after_ms, .. } if retry_after_ms < 1_000 => Err(KError::Again),
        other => Err(KError::Refused(other.reason_str().to_string())),
    }
}

/// The interface has no resource of its own, so its plain `Host` trait is empty - the generated
/// linker still asks for it beside `HostWithStore`, as the websocket and speech bindings do.
///
/// The policy gate is spelled here for the same reason `wasi_ext_host.rs` spells its own: this
/// module's bindings generate their own `types.error`, so the 0.2 runner's `gate` cannot be reused
/// across the two `KError` types. The decision table is `service_components::gate_verdict`'s, word
/// for word - a short rate limit is `again`, anything else a `refused` carrying the reason.
impl wa::kernel::vision::Host for State {}

/// The reader's refusal as the guest's error: a full queue is `again` (the guest retries later),
/// everything else is `failed(<the worker's own word>)` so a component can tell `no_text_detected`
/// from `worker_stalled` without reading the kernel's source.
fn refusal_error(refusal: service_ocr::Refusal) -> KError {
    match refusal {
        service_ocr::Refusal::Busy => KError::Again,
        other => KError::Failed(other.reason()),
    }
}

impl wa::kernel::vision::HostWithStore<State> for State {
    /// Read one image with the node's warm text reader.
    async fn read(accessor: &Accessor<State, Self>, image: Vec<u8>, mime: String) -> Result<wa::kernel::vision::Reading, KError> {
        let name = who(accessor);
        let mut call = HostCallGuard::start(&name, "vision.read");
        let out: Result<wa::kernel::vision::Reading, KError> = async {
            // Grant first, policy second: a rule can only ever narrow what the manifest allows.
            if !accessor.with(|mut access| access.get().ocr) {
                return Err(KError::Refused("ocr not declared".into()));
            }
            gate(&name, "ocr.read")?;
            let slot = Slot::new();
            let done = slot.clone();
            let worker_mime = mime.clone();
            let spawned = std::thread::Builder::new()
                .name("wa-service-ocr".into())
                .spawn(move || done.put(service_ocr::read(image, &worker_mime)));
            let outcome = match spawned {
                Ok(_) => SlotFuture(slot).await,
                Err(error) => Err(service_ocr::Refusal::Failed(format!("ocr_spawn_failed:{error}"))),
            };
            outcome
                .map(|reading| wa::kernel::vision::Reading { text: reading.text, mime: reading.mime, elapsed_ms: reading.elapsed_ms })
                .map_err(refusal_error)
        }
        .await;
        call.outcome(&out);
        out
    }
}

/// Link the vision interface into a service linker. Called only by the 0.2 runner: the 0.1 contract
/// has no `vision` interface, so linking it there would be a promise nobody can make a call to.
pub fn link(linker: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    wa::kernel::vision::add_to_linker::<State, State>(linker, |state| state)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::service_ocr::Refusal;

    /// The mapping the guest relies on, pinned here rather than discovered on a node: a full queue is
    /// the one retryable condition, and it is `again` (never a refusal that would look permanent).
    #[test]
    fn a_busy_reader_is_again_and_every_other_answer_is_its_own_word() {
        assert!(matches!(refusal_error(Refusal::Busy), KError::Again));
        match refusal_error(Refusal::TooLarge) {
            KError::Failed(reason) => assert_eq!(reason, "image_too_large"),
            other => panic!("expected the reader's word, got {other:?}"),
        }
        match refusal_error(Refusal::UnsupportedMedia("application/pdf".into())) {
            KError::Failed(reason) => assert_eq!(reason, "unsupported_media:application/pdf"),
            other => panic!("expected the reader's word, got {other:?}"),
        }
        match refusal_error(Refusal::Failed("no_text_detected".into())) {
            KError::Failed(reason) => assert_eq!(reason, "no_text_detected"),
            other => panic!("expected the reader's word, got {other:?}"),
        }
    }
}
