//! Email connector as a service component on `wa:kernel@0.2` (WASI 0.3): IMAP in, SMTP out.
//!
//! The shape is `wa-whatsapp`'s (`docs/SERVICE-COMPONENTS.md`, `docs/EMAIL-CONNECTOR.md`):
//!
//! ```text
//! IMAP (TLS in the kernel)  ->  mime::parse  ->  wa-email-index record in the component's kv
//!                                              + attachment bytes as media
//!                                              + `email.received` on the bus
//! email.outbox (wa:queue)   ->  validate/rate limit (wa-email-outbox) -> compose -> SMTP
//!                           ->  done(message id) | fail(reason)
//! email.query  (wa:queue)   ->  search/read/media over the index -> done(bounded answer)
//! ```
//!
//! The crate is split the way the WhatsApp component is: `imap`, `smtp`, `mime`, `compose`, `config`,
//! `reconnect`, `telemetry` and `connector` are pure - no host call, no async runtime, no wasm target
//! requirement - so `cargo test` measures every decision natively against in-process fake servers, and
//! `cargo build --target wasm32-wasip2` builds the component. `guest` and `store` (the only modules that
//! touch `wa:kernel` and `wa:email/transport`) are compiled only for wasm.
pub mod compose;
/// The non-secret configuration and what it refuses (a password in the config, a plaintext session to a
/// remote host).
pub mod config;
/// The receive/send loop between the protocol machines and whatever transport the guest supplies.
pub mod connector;
/// IMAP4rev1 as a sans-I/O client: `step` says what to write, `on_bytes` says what arrived.
pub mod imap;
/// The bounded RFC 5322 + MIME reader that turns a fetched message into an indexed record.
pub mod mime;
/// Reconnect pacing: the supervisor's backoff, applied to the connector's own sessions.
pub mod reconnect;
/// SMTP submission as a sans-I/O client, with failures classified the way the queue needs them.
pub mod smtp;
/// The log-line shape, which can carry ids and codes but never mail.
pub mod telemetry;

#[cfg(target_arch = "wasm32")]
wit_bindgen::generate!({
    // The component's own world: the kernel service contract, the bus fact it publishes, the queue it
    // works, and `wa:email/transport` (the host-side TLS byte stream, `wit/wa.wit`).
    world: "email-service",
    path: "wit",
    generate_all,
});

#[cfg(target_arch = "wasm32")]
mod guest;

#[cfg(target_arch = "wasm32")]
mod store;

// The component's export glue. `export!` takes a bare identifier and expands to crate-root-relative
// paths, so the type is imported here and the `impl ... for Service` it exports stays in `guest`, next
// to the logic.
#[cfg(target_arch = "wasm32")]
use guest::Service;
#[cfg(target_arch = "wasm32")]
export!(Service);

/// The first occurrence of `needle` in `haystack`: the one scanning primitive the two protocol clients
/// and the MIME reader share.
pub(crate) fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack.windows(needle.len()).position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::find;

    #[test]
    fn the_shared_scanner_is_a_plain_subslice_search() {
        assert_eq!(find(b"abc\r\ndef", b"\r\n"), Some(3));
        assert_eq!(find(b"abc", b"\r\n"), None);
        assert_eq!(find(b"", b"x"), None);
        assert_eq!(find(b"abc", b""), None);
    }
}
