//! WhatsApp linked-device client as a service component.
//!
//! whatsapp-rust's protocol core, with everything that touches the outside world supplied by the
//! host: the websocket (wa_ws, TLS in the host), HTTP (wa_http), the clock (WASI) and stop
//! (wa_ctl). Single-threaded: one LocalPool polled by a main loop that also drives timers and host
//! I/O, so nothing ever blocks.
//!
//! Milestone 1: pair (by code when `pair_phone` is configured, else QR), connect, receive. The log
//! carries the pairing code, connection state and message metadata (chat, kind, id) - never content.
//! Store: store.rs - in-memory reads with write-through of durable state to the host (wa_kv);
//! a restart reconnects without pairing again.
//!
//! The crate is split so the decisions can be tested on the host: `queue` (freshness, retry, the
//! express lane), `posting` (allowlist gate, holds, chunks, edit pacing), `alerts` (own-chat log,
//! group titles) and `holds` (chats held until a revoke is proven) are pure logic with no host call
//! and no wasm target requirement; everything else (`guest`, `wasm`) needs the wasm32-wasip2
//! bindings and is compiled only for that target, so `cargo test` runs the decisions natively while
//! `cargo build --target wasm32-wasip2` builds the component.
pub mod alerts;
pub mod holds;
pub mod posting;
pub mod queue;

#[cfg(target_arch = "wasm32")]
mod store;

#[cfg(target_arch = "wasm32")]
wit_bindgen::generate!({
    world: "service-component",
    path: "../../../wit/kernel",
});

/// The service itself (host I/O, protocol, pipeline). Declared after `generate!` so the generated
/// `export!` macro is in textual scope inside it.
#[cfg(target_arch = "wasm32")]
mod guest;
