//! The model gateway's rules — `wa:model`'s logic, natively testable (`docs/MODEL-GATEWAY.md`).
//!
//! The seam has three jobs and this crate is all three, with no host dependency:
//!
//! * **route**: a task class (`plan`, `code`, `cheap`, `vision`, `default`) or an explicit model becomes an
//!   ordered candidate list, filtered by the request's **data label** and by each provider's circuit
//!   breaker, with a reason for every candidate ([`route`]);
//! * **speak**: one canonical request becomes Anthropic Messages, OpenAI-compatible chat completions or
//!   Gemini's streaming endpoint, and the provider's SSE stream becomes typed events — deltas, reasoning,
//!   assembled tool calls, usage, finish ([`anthropic`], [`openai`], [`gemini`], [`adapter`]);
//! * **account**: fallback on 429/5xx/timeout with jittered backoff, budgets per node-day and per session,
//!   token/cost/cache accounting per session/model/class ([`gateway`], [`budget`], [`backoff`],
//!   [`accounting`]).
//!
//! What it deliberately does *not* do: hold a credential (the provider's key is a reference the kernel's
//! `wa:kernel/http` resolves), open a socket ([`transport::Transport`] is injected), read a clock of its
//! own ([`gateway::Clock`]), or touch a session ([`types::ChatRequest`] is a value).
//!
//! The component `rust/components/model-gateway` is this crate plus the kernel edges; the node's
//! `wa-capabilities` seam is the same decisions behind `WA_MODEL_GATEWAY=1`. Parity between the two is not
//! asserted by hope: both call these functions.

pub mod accounting;
pub mod adapter;
pub mod anthropic;
pub mod backoff;
pub mod breaker;
pub mod budget;
pub mod gateway;
pub mod gemini;
pub mod openai;
pub mod policy;
pub mod route;
pub mod transport;
pub mod types;

pub use accounting::{Accounted, Accounting, Totals};
pub use breaker::{Breakers, Phase, Verdict};
pub use budget::Ledger;
pub use gateway::{CallError, Clock, Explain, FixedClock, Gateway, ImmediateWaiter, Outcome, SleepWaiter, Waiter};
pub use policy::{Budgets, Policy, ProviderKind, ProviderSpec, Rates, Scheme};
pub use route::{plan_chat, plan_embed, Plan, Planned};
pub use transport::{Chunk, EdgeRequest, EdgeResponse, MockTransport, Reply, Transport, TransportError};
pub use types::{
    label_of_source, ChatRequest, EmbedRequest, Event, Fault, Finish, FinishReason, Label, Message, ModelRef,
    Part, Refusal, Role, Route, Source, TaskClass, ToolCall, ToolDef, Usage,
};

#[cfg(test)]
mod integration;
