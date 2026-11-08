//! Read-only `/` views the *client* answers while a turn is in flight.
//!
//! ## The bug this exists for
//!
//! `wa chat` runs a turn synchronously: from the reader's Enter to the last token, this interpreter
//! is blocked inside `host.http_stream`. The console reader that keeps typing alive lives on another
//! thread (`rust/wa-capabilities/src/host.rs`, "input that arrives while the interpreter is blocked"),
//! so a line typed during a run is *read* - and then waits, because the only side that can act on it
//! is the side that is blocked. `/status` got around this years of commits ago: the interpreter
//! publishes a panel spec with `host.status_snapshot`, and the reader thread draws it from that
//! snapshot the moment `/status` is submitted (`lua/core/chat.lua`, `docs/HOST.md`). `/nodes` never
//! did, so typing it during a run queued it behind the turn: Victor's report, in one sentence.
//!
//! ## What this crate is
//!
//! The same idea, generalised from one panel to a stack of panels, and put somewhere it can be
//! tested without a terminal, a Lua state or a node:
//!
//! - [`Store::publish`] files a snapshot a view produced (`host.local_view`), refusing anything that
//!   could hurt the thread that will draw it;
//! - [`Store::route`] answers the reader's Enter: this line is mine (and here is the panel), or it is
//!   the interpreter's (and it goes to the queue exactly as before);
//! - [`Store::answer`] walks the stack - Enter opens a page, Esc or "Back" returns, Esc at the root
//!   closes - so a node's page is reachable while the run is still going;
//! - the age line ("snapshot 2m ago") says how old the data is instead of pretending it is live.
//!
//! ## The integration (deliberately not done here)
//!
//! `rust/wa-capabilities/src/host.rs` is being rewritten for WASI 0.3 by another stream, so this
//! crate touches nothing and is wired in by three small edits, all documented in `REPORT.md`:
//! a `members` entry, one capability row for `host.local_view`, and two calls in the reader thread's
//! `Submit` / panel-answer paths. Until that lands, `lua/core/local_views.lua` publishes into a
//! capability that is not there and `/nodes` behaves exactly as it does today.
//!
//! The crate is `forbid(unsafe_code)` on purpose: its caller is a CLI's input thread, and the one
//! thing a snapshot must never do is take the reader's typing down with it.
#![forbid(unsafe_code)]

mod age;
mod spec;
mod store;

pub use age::{age_line, human_age};
pub use spec::{
    Refusal, View, ViewOption, ViewSet, MAX_COMMAND_CHARS, MAX_LABEL_CHARS, MAX_LINES,
    MAX_LINE_CHARS, MAX_OPTIONS, MAX_SPEC_BYTES, MAX_TITLE_CHARS, MAX_VIEWS,
};
pub use store::{
    answer, dismiss, global, now_seconds, publish, route, Answer, Published, Report, Route, Store,
};
