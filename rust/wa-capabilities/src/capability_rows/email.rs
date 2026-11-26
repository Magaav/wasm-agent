//! Email (docs/EMAIL-CONNECTOR.md): the send on email.outbox after the policy check, and the index
//! queries beside it. The handlers are in crate::email_send and crate::email_query.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    // The same two shapes as the WhatsApp tools: an effect (`email_send`) is a job on `email.outbox`
    // after the node's `email.send` policy check, a question (`email_search`/`email_read`) is a job on
    // `email.query`, and `email_send_status` reads the send back. Recipients are audited as a digest,
    // never as an address.
    plain!("email_send", Network, crate::email_send::capability, "Send one email through the durable email.outbox queue, after the email.send policy check; returns the job id, never the delivery"),
    plain!("email_send_status", ReadOnly, crate::email_send::status_capability, "State of one queued email send: queued, sending, done with its message id, or failed with a reason"),
    plain!("email_search", ReadOnly, crate::email_query::search, "Search every indexed email by text (accent-folded), sender, subject, mailbox or time window; returns matching messages with snippets"),
    plain!("email_read", ReadOnly, crate::email_query::read, "Read one mailbox newest first, or one message by uid: envelope, subject, text and attachments"),
    plain!("email_media", ReadOnly, crate::email_query::media, "The attachment metadata of one indexed email, with the media handle a download can name"),
];
