//! wa-bus — the in-node event bus.
//!
//! The queue is *work*: one consumer, durable, a claim on an event. The bus is *facts*: many
//! consumers, best-effort within a declared overflow policy, no claim. `whatsapp.transcript.ready`
//! goes to the agent, the search index and the logger without the WhatsApp component knowing any of
//! them exists.
//!
//! ```
//! use std::sync::Arc;
//! use wa_bus::{Bus, Event, NamespaceAcl, SubscribeOptions, Topic};
//!
//! let mut acl = NamespaceAcl::new();
//! acl.grant("index", wa_bus::Action::Subscribe, "whatsapp.*").unwrap();
//! let bus = Bus::with_access(Arc::new(acl));
//!
//! // The indexer subscribes first. The handle is the subscription: dropping it unsubscribes.
//! let sub = bus
//!     .subscribe("index", "whatsapp.*", SubscribeOptions::new().with_capacity(256))
//!     .unwrap();
//!
//! let event = Event::new(Topic::parse("whatsapp.transcript.ready").unwrap(), "whatsapp", "wa.transcript", b"{}".to_vec());
//! let outcome = bus.publish(event).unwrap();
//! assert_eq!(outcome.delivered, 1);
//! assert_eq!(sub.recv().map(|e| e.topic.to_string()).as_deref(), Some("whatsapp.transcript.ready"));
//! ```
//!
//! Design notes and the host integration plan: `docs/BUS.md`. The WIT draft for a component-facing
//! version on WASI 0.3 (native async, `stream<event>`): `wit/bus/bus.wit`.

pub mod access;
pub mod bus;
pub mod event;
pub mod kv;
pub mod topic;

#[cfg(test)]
mod tests;

pub use access::{Access, Action, AllowAll, DenyAll, NamespaceAcl};
pub use bus::{
    Bus, BusError, OverflowPolicy, PublishOutcome, SubscribeOptions, Subscription, SubscriptionId,
    SubscriptionInfo, DEFAULT_CAPACITY, DEFAULT_RETAIN,
};
pub use event::{now_ms, DecodeError, Event, EventId, Schema};
pub use kv::{retention_key, retention_prefix, Kv, KvEntries, KvError, MemoryKv};
pub use topic::{Pattern, Topic, TopicError, MAX_SEGMENT, MAX_SEGMENTS, MAX_TOPIC};
